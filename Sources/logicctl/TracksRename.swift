import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Tracks {
  /// Gives one track of the project Logic has open another name, and prints the row of that track.
  ///
  /// The name in the row is the name Logic shows after the change. It is not the text the person
  /// typed, because Logic decides what a track is called: a write it refused leaves the old name,
  /// and a name it changed on the way in is the name the project now holds. An agent renames a
  /// track and knows from the one answer what happened, with no second read.
  struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "rename",
      abstract: "Give one track of the project Logic has open another name.",
      discussion: """
        The answer carries the row of the track as Logic shows it after the change. An index that \
        names no track fails before anything is written. A project logicctl did not make needs \
        --confirm.

        Example: logicctl tracks rename --index 1 --name Bass
        """)

    @OptionGroup var track: TrackIndexOption

    @Option(help: "The name to give the track.")
    var name: String

    @OptionGroup var guarded: ConfirmOption

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    /// Refuses a name with nothing in it, before Logic is asked anything.
    ///
    /// Every track of Logic carries a name, so there is no name to write here, and the read back
    /// would have nothing to look for. The person gets `invalid_argument` and the project is
    /// untouched.
    func validate() throws {
      guard !name.isEmpty else {
        throw ValidationError("Give --name the text to call the track. A name cannot be empty.")
      }
    }

    func run() throws {
      let status = Tracks.Rename.answer(
        driver: Tracks.liveDriver(),
        actions: TrackActions.live(),
        index: track.index,
        name: name,
        confirmed: guarded.confirm,
        limitMs: wait.timeout.milliseconds,
        format: output.format,
        argv: ["--index", String(track.index.value), "--name", name])
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Tracks.Rename {
  /// Renames the track, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver and the action are given rather than reached for, so the pipeline drives the same
  /// command against a Logic of its own.
  static func answer(
    driver: any LogicDriver,
    actions: TrackActions,
    index: OneBasedIndex,
    name: String,
    confirmed: Bool,
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    limitMs: Int = Wait.defaultLimitMs,
    format: OutputFormat = .compact,
    argv: [String] = [],
    now: @escaping () -> Date = { Date() },
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds,
    git: Git = Git(),
    lock: Lock = Lock(),
    capturer: any WindowCapturer = WindowCapture(),
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)
    let run = Run(
      driver: driver,
      root: root,
      version: version,
      now: now,
      git: git,
      lock: lock,
      capturer: capturer)
    let command = TracksRenameCommand(
      argv: argv,
      index: index.value,
      newName: name,
      actions: actions,
      limitMs: limitMs,
      clock: clock,
      sleeper: sleeper)
    return printer.write(run.run(change: command, confirmed: confirmed))
  }
}

/// The renaming of one track, as the run of a command sees it.
///
/// It changes the project, so it goes through the guard: a project logicctl did not make is left
/// alone until a person says `--confirm`. The run takes the lock, records the step and answers the
/// envelope around it.
struct TracksRenameCommand: LogicCommand {
  let name = "tracks rename"

  let argv: [String]

  /// The track the person named, counted from 1.
  let index: Int

  /// The name the person asked for.
  let newName: String

  /// What writes into the header of the track in Logic.
  let actions: TrackActions

  /// How long the read of the new name may take, in milliseconds.
  let limitMs: Int

  /// The clock the wait reads.
  let clock: Wait.Clock

  /// How the wait sleeps between two reads.
  let sleeper: Wait.Sleeper

  /// Writes the name into the header of the track, waits for Logic to show the change, and answers
  /// the row of that track as Logic holds it then.
  ///
  /// The tracks are read before the write, so a number that names no track is refused while the
  /// project is still as the person left it.
  ///
  /// The wait ends when the track carries the name that was asked for, or any name other than the
  /// one it carried. Both are Logic answering. The first covers a rename to the name the track
  /// already has, which changes nothing and is no failure, and it keeps a replay of a session
  /// giving the same result on its second run. The second covers a name Logic made of its own,
  /// which is the name the project now holds and the name that goes in the answer. A write that
  /// changed nothing reaches neither, and the command answers `timeout` rather than a rename that
  /// Logic refused.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let before = try driver.readState().tracks
    guard let target = before.first(where: { $0.index == index }) else {
      throw RegionTarget.NoTrack(index: index)
    }
    let was = target.name
    try actions.rename(trackNumber: index - 1, to: newName)
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      guard let shown = try TracksRenameCommand.track(numbered: index, through: driver) else {
        return false
      }
      return shown.name == newName || shown.name != was
    }
    guard let renamed = try TracksRenameCommand.track(numbered: index, through: driver) else {
      throw TrackActions.Refusal(
        reason: "Logic answered no track at index \(index) once the name was written.")
    }
    return .object(["track": TracksListCommand.row(of: renamed)])
  }

  /// The track at one number as Logic answers it now, or nothing when it answers none there.
  private static func track(
    numbered index: Int, through driver: any LogicDriver
  ) throws -> Track? {
    try driver.readState().tracks.first { $0.index == index }
  }
}
