import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension TransportCommand {
  /// Starts recording in Logic, and answers the transport as Logic reads back.
  ///
  /// The answer is what Logic does and not what logicctl asked for. A command that acted and
  /// reported success would say Logic is recording on every Mac where the take never started. An
  /// agent that read that answer would play a part into a take that never ran, and the
  /// performance is gone. So the command reads the transport back, and a transport that does not
  /// record is a failure with the time it was given.
  struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "record",
      abstract: "Start recording in Logic.",
      discussion: """
        The answer carries the transport as Logic reads it back, so a transport that never \
        started recording is `timeout` and never a report of a take.

        Logic records on the tracks that are armed, and arming a track is a person's to do.

        Example: logicctl transport record
        """)

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    func run() throws {
      let status = TransportCommand.Record.answer(
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

extension TransportCommand.Record {
  /// Starts recording, prints the envelope, and answers the number the process exits with.
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
    let recording = StartRecording(
      actions: actions, limitMs: limitMs, clock: clock, sleeper: sleeper)
    let run = Run(
      driver: driver, root: root, version: version, now: now, git: git, lock: lock,
      capturer: capturer)
    return printer.write(run.run(command: recording))
  }
}

/// The take the run records, and the transport of Logic after it.
///
/// Logic writes into the project while it records, and the tracks it writes on are the ones a
/// person armed. The command itself sets a transport state and names no track, so it is not
/// guarded and takes no `--confirm`, the way play and stop are not.
private struct StartRecording: LogicCommand {
  let name = "transport record"
  let argv: [String] = []
  let actions: TrackActions
  let limitMs: Int
  let clock: Wait.Clock
  let sleeper: Wait.Sleeper

  /// Waits until Logic reads as recording, and answers the transport it reads.
  ///
  /// A transport that never starts recording ends at the limit with `timeout` and the
  /// milliseconds it was given, rather than a report of a take that is not running.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let takeIsRunning = try driver.readState().transport.recording
    if !takeIsRunning {
      try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
        try driver.readState().transport.recording
      }
    }
    let transport = try driver.readState().transport
    return .object([
      "playing": .bool(transport.playing),
      "recording": .bool(transport.recording),
    ])
  }
}
