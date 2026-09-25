import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension TransportCommand {
  /// Stops the transport of Logic, and answers the transport as Logic reads back.
  ///
  /// The answer is what Logic does and not what logicctl sent. A command that sent the message and
  /// reported success would say Logic is stopped on every Mac where it is still moving: the port
  /// is missing, or Logic takes no Machine Control input. An agent that read that answer would go
  /// on to edit a project whose playhead is running. So the command reads the transport back after
  /// the message, and a transport that does not stop is a failure with the time it was given.
  struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "stop",
      abstract: "Stop the transport of Logic.",
      discussion: """
        The message goes to the port named logicctl, the one `midi setup` reports. A Mac that \
        carries no such port takes nothing, so the command stops there. The answer carries the \
        transport as Logic reads it back, so a transport that is still moving is `timeout` and \
        never a report of a stop.

        Example: logicctl transport stop
        """)

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    func run() throws {
      let status = TransportCommand.Stop.answer(
        openingTheBus: {
          try MidiBus.live().named().map { try MachineControlOutput.live(to: $0) }
        },
        driver: NewProject.liveDriver(),
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
  /// How the command reaches Logic: it finds the port named `logicctl` and opens a way out to it.
  ///
  /// It answers nothing when this Mac carries no such port, which is the Mac `midi setup` reports
  /// the IAC driver off on.
  typealias OpenTheBus = () throws -> MachineControlOutput?

  /// Stops the transport, prints the envelope, and answers the number the process exits with.
  ///
  /// The bus, the driver and the clock are given rather than reached for, so the pipeline runs the
  /// same command with nothing of this Mac in the way and no real wait spent on it.
  static func answer(
    openingTheBus: OpenTheBus,
    driver: any LogicDriver,
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
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    let opened: MachineControlOutput?
    do {
      opened = try openingTheBus()
    } catch {
      return printer.write(
        Envelope.failure(
          TransportCommand.Stop.failure(of: error),
          meta: AnswerMeta.refusal(version: version, from: started, to: now())))
    }

    // A Mac with no port took nothing and reached no project, so nothing is recorded and the
    // answer carries no session and no step, the way a wrong flag does.
    guard let opened else {
      return printer.write(
        Envelope.failure(
          Failure(code: .midiUnavailable, message: Midi.Setup.driverOff),
          meta: AnswerMeta.refusal(version: version, from: started, to: now())))
    }

    let stopping = StopPlayback(
      output: opened, limitMs: limitMs, clock: clock, sleeper: sleeper)
    let run = Run(
      driver: driver, root: root, version: version, now: now, git: git, lock: lock,
      capturer: capturer)
    return printer.write(run.run(command: stopping))
  }

  /// What the command stopped with before it sent anything.
  static func failure(of error: Error) -> Failure {
    if let refusal = error as? MachineControlOutput.Refusal {
      return Failure(code: .midiUnavailable, message: refusal.reason)
    }
    return Run.failure(for: error)
  }
}

/// The stop the run records: the Machine Control message, then the transport of Logic.
///
/// A stop moves the playhead nowhere and writes nothing into the project, so this command is not
/// guarded and takes no `--confirm`.
private struct StopPlayback: LogicCommand {
  let name = "transport stop"
  let argv: [String] = []
  let output: MachineControlOutput
  let limitMs: Int
  let clock: Wait.Clock
  let sleeper: Wait.Sleeper

  /// Sends the message, waits until Logic reads as stopped, and answers the transport it reads.
  ///
  /// The wait reads the condition before it sleeps, so a stop of a transport that is already
  /// stopped costs the command nothing. A transport that keeps moving ends at the limit with
  /// `timeout` and the milliseconds it was given, rather than a report of a stop that did not
  /// happen.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    try output.send(MachineControlMessage.stop)
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      let moving = try driver.readState().transport.playing
      return !moving
    }
    let transport = try driver.readState().transport
    return .object([
      "playing": .bool(transport.playing),
      "recording": .bool(transport.recording),
    ])
  }
}
