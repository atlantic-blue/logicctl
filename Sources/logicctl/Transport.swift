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
      Play.self
    ])
}

extension TransportCommand {
  /// Starts playback in Logic, and answers the transport as Logic reads back.
  ///
  /// The answer is what Logic does and not what logicctl sent. A command that sent the message and
  /// reported success would say Logic plays on every Mac where the message arrives nowhere: the
  /// port is missing, or Logic takes no Machine Control input. So the command reads the transport
  /// back after the message, and a transport that does not start is a failure with the time it was
  /// given.
  struct Play: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "play",
      abstract: "Start playback in Logic.",
      discussion: """
        The message goes to the port named logicctl, the one `midi setup` reports. A Mac that \
        carries no such port takes nothing, so the command stops there. The answer carries the \
        transport as Logic reads it back, so a transport that never started is `timeout` and never \
        a report of playback.

        Example: logicctl transport play
        """)

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    func run() throws {
      let status = TransportCommand.Play.answer(
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

extension TransportCommand.Play {
  /// How the command reaches Logic: it finds the port named `logicctl` and opens a way out to it.
  ///
  /// It answers nothing when this Mac carries no such port, which is the Mac `midi setup` reports
  /// the IAC driver off on.
  typealias OpenTheBus = () throws -> MachineControlOutput?

  /// Starts playback, prints the envelope, and answers the number the process exits with.
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
          TransportCommand.Play.failure(of: error),
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

    let playing = StartPlayback(
      output: opened, limitMs: limitMs, clock: clock, sleeper: sleeper)
    let run = Run(
      driver: driver, root: root, version: version, now: now, git: git, lock: lock,
      capturer: capturer)
    return printer.write(run.run(command: playing))
  }

  /// What the command stopped with before it sent anything.
  static func failure(of error: Error) -> Failure {
    if let refusal = error as? MachineControlOutput.Refusal {
      return Failure(code: .midiUnavailable, message: refusal.reason)
    }
    return Run.failure(for: error)
  }
}

/// The playback the run records: the Machine Control message, then the transport of Logic.
///
/// Playback moves the playhead and writes nothing into the project, so this command is not guarded
/// and takes no `--confirm`.
private struct StartPlayback: LogicCommand {
  let name = "transport play"
  let argv: [String] = []
  let output: MachineControlOutput
  let limitMs: Int
  let clock: Wait.Clock
  let sleeper: Wait.Sleeper

  /// Sends the message, waits until Logic reads as playing, and answers the transport it reads.
  ///
  /// The wait reads the condition before it sleeps, so a transport that already plays costs the
  /// command nothing. A transport that never starts ends at the limit with `timeout` and the
  /// milliseconds it was given, rather than a report of playback that did not happen.
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
