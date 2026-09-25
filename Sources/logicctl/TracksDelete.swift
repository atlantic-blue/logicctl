import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Tracks {
  /// Removes one track from the project Logic has open, and prints the tracks it has left.
  ///
  /// The answer is the whole list, and not the row that went. The row that went is gone, and what
  /// a person or an agent needs next is the project as it stands. Logic numbers the tracks from
  /// the top of the window, so a delete moves the number of every track under the one that went,
  /// and a list read before the delete names the wrong track from then on.
  struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "delete",
      abstract: "Remove one track from the project Logic has open.",
      usage: "logicctl tracks delete --index <n> [--confirm] [--pretty]",
      discussion: """
        The answer carries every track the project has left, in the order Logic shows them. An \
        index that names no track fails before anything is pressed. A project logicctl did not \
        make needs --confirm.

        Example: logicctl tracks delete --index 2
        """)

    @OptionGroup var track: TrackIndexOption

    @OptionGroup var guarded: ConfirmOption

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    func run() throws {
      let status = Tracks.Delete.answer(
        driver: Tracks.liveDriver(),
        actions: TrackActions.live(),
        index: track.index,
        confirmed: guarded.confirm,
        limitMs: wait.timeout.milliseconds,
        format: output.format,
        argv: ["--index", String(track.index.value)])
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Tracks.Delete {
  /// Removes the track, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver and the action are given rather than reached for, so the pipeline drives the same
  /// command against a Logic of its own.
  static func answer(
    driver: any LogicDriver,
    actions: TrackActions,
    index: OneBasedIndex,
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
    let command = TracksDeleteCommand(
      argv: argv,
      index: index.value,
      actions: actions,
      limitMs: limitMs,
      clock: clock,
      sleeper: sleeper)
    return printer.write(run.run(change: command, confirmed: confirmed))
  }
}

/// The removal of one track, as the run of a command sees it.
///
/// It changes the project, so it goes through the guard: a project logicctl did not make is left
/// alone until a person says `--confirm`. The run takes the lock, records the step and answers the
/// envelope around it.
struct TracksDeleteCommand: LogicCommand {
  let name = "tracks delete"

  let argv: [String]

  /// The track the person named, counted from 1.
  let index: Int

  /// What selects the track header and presses the item of the Track menu.
  let actions: TrackActions

  /// How long the read of the project after the delete may take, in milliseconds.
  let limitMs: Int

  /// The clock the wait reads.
  let clock: Wait.Clock

  /// How the wait sleeps between two reads.
  let sleeper: Wait.Sleeper

  /// Removes the track, waits for the project to hold one track less, and answers the tracks it
  /// has left.
  ///
  /// The tracks are read first, so a number that names no track is refused while the project is
  /// still as the person left it.
  ///
  /// The wait counts the tracks. It does not look for the number that went, because Logic numbers
  /// the tracks again after a delete: a delete of track 1 of 2 leaves a track at index 1, so a
  /// wait on that number would hold at once and say nothing about the press.
  ///
  /// The list goes out as Logic answers it after the change, and not as it was read before. A row
  /// of the older list names a track that is gone, or names the wrong track, and every later
  /// command would work from a project that Logic does not hold.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let before = try driver.readState().tracks
    guard before.contains(where: { $0.index == index }) else {
      throw RegionTarget.NoTrack(index: index)
    }
    try actions.delete(trackNumber: index - 1)
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      try driver.readState().tracks.count == before.count - 1
    }
    let after = try driver.readState().tracks
    return .object(["tracks": .array(after.map(TracksListCommand.row(of:)))])
  }
}
