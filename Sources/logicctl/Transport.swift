import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// What logicctl does to the transport of Logic.
///
/// The transport is what a person drives with the play, stop and record buttons of the Control Bar.
/// logicctl reaches it over Machine Control on the bus rather than by pressing a button, so one
/// message moves it and no event is posted at the screen.
///
/// The name is longer than the word a person types, because `LogicctlCore` already carries a
/// `Transport`, which is what the state says the transport is doing. Two types of that name, one in
/// each module, make the bare name ambiguous wherever both are read, which is every test of a
/// command that holds a state.
struct TransportCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "transport",
    abstract: "Move the transport of Logic.",
    discussion: """
      Example: logicctl transport play
      """,
    subcommands: [
      Play.self, Stop.self, Record.self, Tempo.self,
    ])
}

extension TransportCommand {
  /// Starts playback in Logic, and answers the transport as Logic reads back.
  ///
  /// The answer is what Logic does and not what logicctl pressed. A command that pressed the button
  /// and reported success would say Logic plays on every Mac where the press reached nothing. So
  /// the command reads the transport back after the press, and a transport that does not start is a
  /// failure with the time it was given.
  struct Play: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "play",
      abstract: "Start playback in Logic.",
      discussion: """
        The answer carries the transport as Logic reads it back, so a transport that never started \
        is `timeout` and never a report of playback.

        Example: logicctl transport play
        """)

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    func run() throws {
      let status = TransportCommand.Play.answer(
        driver: NewProject.liveDriver(),
        actions: TrackActions(pressInWindow: TrackActions.pressInTheWindowOfThisMac),
        limitMs: wait.timeout.milliseconds,
        format: output.format)
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension TransportCommand.Play {
  /// Starts playback, prints the envelope, and answers the number the process exits with.
  ///
  /// The press, the driver and the clock are given rather than reached for, so the pipeline runs
  /// the same command with nothing of this Mac in the way and no real wait spent on it.
  static func answer(
    driver: any LogicDriver,
    actions: TrackActions,
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    limitMs: Int = Wait.defaultLimitMs,
    format: OutputFormat = .compact,
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
    let playing = StartPlayback(
      actions: actions, limitMs: limitMs, clock: clock, sleeper: sleeper)
    let run = Run(
      driver: driver, root: root, version: version, now: now, git: git, lock: lock,
      capturer: capturer)
    return printer.write(run.run(command: playing))
  }
}

/// The playback the run records: the press of the Play button, then the transport of Logic.
///
/// Playback moves the playhead and writes nothing into the project, so this command is not guarded
/// and takes no `--confirm`.
private struct StartPlayback: LogicCommand {
  let name = "transport play"
  let argv: [String] = []
  let actions: TrackActions
  let limitMs: Int
  let clock: Wait.Clock
  let sleeper: Wait.Sleeper

  /// Waits until Logic reads as playing, and answers the transport it reads.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      try driver.readState().transport.playing
    }
    let transport = try driver.readState().transport
    return .object([
      "playing": .bool(transport.playing),
      "recording": .bool(transport.recording),
    ])
  }
}
