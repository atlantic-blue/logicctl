import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension TransportCommand {
  /// Stops the transport of Logic, and answers the transport as Logic reads back.
  ///
  /// The answer is what Logic does and not what logicctl asked for. A command that pressed the
  /// button and reported success would say Logic is stopped on every Mac where it is still
  /// moving, and an agent that read that answer would go on to edit a project whose playhead is
  /// running. So the command reads the transport back after the press, and a transport that does
  /// not stop is a failure with the time it was given.
  ///
  /// Measured on this Mac on 2026-09-26 against Logic 12.3.1: one press of the Stop button took
  /// the Play check box from 1 to 0 within a second, and after Record it took Play and Record
  /// both to 0.
  struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "stop",
      abstract: "Stop the transport of Logic.",
      discussion: """
        The command presses the Stop button of the Control Bar, the one a person clicks. The \
        answer carries the transport as Logic reads it back, so a transport that is still moving \
        is `timeout` and never a report of a stop. A transport that is already stopped is \
        left alone, because a press of Stop on a stopped transport moves the playhead.

        Example: logicctl transport stop
        """)

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    func run() throws {
      let status = TransportCommand.Stop.answer(
        driver: NewProject.liveDriver(),
        actions: TrackActions.live(),
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

extension TransportCommand.Stop {
  /// Stops the transport, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver, the press and the clock are given rather than reached for, so the pipeline runs
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
    let stopping = StopPlayback(
      actions: actions, limitMs: limitMs, clock: clock, sleeper: sleeper)
    let run = Run(
      driver: driver, root: root, version: version, now: now, git: git, lock: lock,
      capturer: capturer)
    return printer.write(run.run(command: stopping))
  }
}

/// The stop the run records: the press of the Stop button, then the transport of Logic.
///
/// A stop writes nothing into the project, so this command is not guarded and takes no
/// `--confirm`.
private struct StopPlayback: LogicCommand {
  let name = "transport stop"
  let argv: [String] = []
  let actions: TrackActions
  let limitMs: Int
  let clock: Wait.Clock
  let sleeper: Wait.Sleeper

  /// Presses Stop, waits until Logic reads as stopped, and answers the transport it reads.
  ///
  /// A transport that reads neither playing nor recording is left alone. In Logic a press of
  /// Stop on a stopped transport moves the playhead, and a stop that is not needed moves nothing.
  ///
  /// The wait reads both values, because a transport that stopped playing and keeps recording is
  /// still moving. A transport that keeps either of them ends at the limit with `timeout` and the
  /// milliseconds it was given, rather than a report of a stop that did not happen.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let before = try driver.readState().transport
    if before.playing || before.recording {
      try actions.pressInWindow(Locators.transportStopButton)
      try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
        let moving = try driver.readState().transport
        return !moving.playing && !moving.recording
      }
    }
    let transport = try driver.readState().transport
    return .object([
      "playing": .bool(transport.playing),
      "recording": .bool(transport.recording),
    ])
  }
}
