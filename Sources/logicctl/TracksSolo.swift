import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Tracks {
  /// Isolates one track of the project Logic has open, or lets the rest be heard again, and prints
  /// the row of that track.
  ///
  /// The command sets a state and it does not turn one over. A person says `--on` or `--off`, and
  /// the track ends in that state whatever state it was in before. So the same command run twice
  /// leaves the same project, an agent needs no read of its own before it asks, and a replay of a
  /// session gives the result the session gave.
  struct Solo: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "solo",
      abstract: "Solo or unsolo one track.",
      usage: "logicctl tracks solo --index <n> (--on | --off) [--pretty]",
      discussion: """
        The answer carries the row of the track as Logic shows it after the change. Exactly one of \
        --on and --off is given. An index that names no track fails before anything is pressed. A \
        project logicctl did not make needs --confirm.

        Example: logicctl tracks solo --index 1 --on
        """)

    @OptionGroup var track: TrackIndexOption

    @OptionGroup var soloing: ToggleOption

    @OptionGroup var guarded: ConfirmOption

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    func run() throws {
      let status = Tracks.Solo.answer(
        driver: Tracks.liveDriver(),
        actions: TrackActions.live(),
        index: track.index,
        soloed: try soloing.state(),
        confirmed: guarded.confirm,
        limitMs: wait.timeout.milliseconds,
        format: output.format,
        argv: ["--index", String(track.index.value), soloing.on ? "--on" : "--off"])
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Tracks.Solo {
  /// Sets the solo state of the track, prints the envelope, and answers the number the process
  /// exits with.
  ///
  /// The driver and the action are given rather than reached for, so the pipeline drives the same
  /// command against a Logic of its own.
  static func answer(
    driver: any LogicDriver,
    actions: TrackActions,
    index: OneBasedIndex,
    soloed: Bool,
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
    let command = TracksSoloCommand(
      argv: argv,
      index: index.value,
      soloed: soloed,
      actions: actions,
      limitMs: limitMs,
      clock: clock,
      sleeper: sleeper)
    return printer.write(run.run(change: command, confirmed: confirmed))
  }
}

/// The setting of the solo state of one track, as the run of a command sees it.
///
/// It changes the project, so it goes through the guard: a project logicctl did not make is left
/// alone until a person says `--confirm`. The run takes the lock, records the step and answers the
/// envelope around it.
struct TracksSoloCommand: LogicCommand {
  let name = "tracks solo"

  let argv: [String]

  /// The track the person named, counted from 1.
  let index: Int

  /// The state the person asked for. True isolates the track.
  let soloed: Bool

  /// What presses the solo button of a track header in Logic.
  let actions: TrackActions

  /// How long the read of the new state may take, in milliseconds.
  let limitMs: Int

  /// The clock the wait reads.
  let clock: Wait.Clock

  /// How the wait sleeps between two reads.
  let sleeper: Wait.Sleeper

  /// Brings the track to the state that was asked for, and answers the row of that track as Logic
  /// holds it then.
  ///
  /// The tracks are read first, for two reasons. A number that names no track is refused while the
  /// project is still as the person left it. And the solo button of Logic is a check box, so the
  /// one action it offers turns the state over rather than setting it: a press on a track that is
  /// already in the state that was asked for would take it out of that state. So the press happens
  /// only where Logic shows the other state, and a command that asks for the state a track already
  /// holds presses nothing and prints the row.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let before = try driver.readState().tracks
    guard let target = before.first(where: { $0.index == index }) else {
      throw RegionTarget.NoTrack(index: index)
    }
    if target.solo != soloed {
      try actions.solo(trackNumber: index - 1)
    }
    return .object(["track": TracksListCommand.row(of: target)])
  }
}
