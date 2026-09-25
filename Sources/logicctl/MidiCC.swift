import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Midi {
  /// Moves one controller of the instrument in Logic.
  ///
  /// A control change is how everything that is not a note reaches an instrument: the modulation
  /// wheel, the sustain pedal, the level of a send. It is one message, and nothing has to let it
  /// go afterwards, so this command holds nothing and waits for nothing.
  ///
  /// The wire carries seven bits of each number, so 0 to 127 is the whole scale. A number above it
  /// does not arrive as an error, it wraps: 128 reaches Logic as 0. So both numbers are held to
  /// the scale before the port is opened, and a command outside it sends nothing at all.
  ///
  /// The message goes to the port named `logicctl`, the one `midi setup` reports. A Mac that
  /// carries no such port takes nothing, so this command stops there and says so, rather than
  /// reporting a change that Logic never heard.
  struct ControlChange: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "cc",
      abstract: "Move one controller of the instrument in Logic.",
      discussion: """
        The controller keeps the value until something moves it again. With a software instrument \
        track armed and recording, the change lands in the region beside the notes.

        Example: logicctl midi cc --number 1 --value 64
        """)

    @Option(help: "The controller to move, 0 to 127, where 1 is the modulation wheel.")
    var number: Int

    @Option(help: "Where the controller lands, 0 to 127.")
    var value: Int

    @OptionGroup var output: OutputOption

    func validate() throws {
      guard Midi.ControlChange.range.contains(number) else {
        throw ValidationError("--number is a controller of 0 to 127, and \(number) is not one.")
      }
      guard Midi.ControlChange.range.contains(value) else {
        throw ValidationError("--value is a place of 0 to 127, and \(value) is not one.")
      }
    }

    func run() throws {
      let status = Midi.ControlChange.answer(
        number: number,
        value: value,
        openingTheBus: { try MidiBus.live().named().map { try MidiOutput.live(to: $0) } },
        driver: NewProject.liveDriver(),
        format: output.format)
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Midi.ControlChange {
  /// How the command reaches Logic: it finds the port named `logicctl` and opens a way out to it.
  ///
  /// It answers nothing when this Mac carries no such port, which is the Mac `midi setup` reports
  /// the IAC driver off on.
  typealias OpenTheBus = () throws -> MidiOutput?

  /// The channel the message is sent on. No flag moves it, and Logic counts channels from 1.
  static let channel = 1

  /// What the wire carries. Seven bits hold 0 to 127, and the controllers of 120 and above are the
  /// channel mode messages, which Logic takes like any other controller.
  static let range = 0...127

  /// Sends the message, prints the envelope, and answers the number the process exits with.
  ///
  /// The bus and the driver are given rather than reached for, so the pipeline sends the same
  /// message with nothing of this Mac in the way.
  static func answer(
    number: Int,
    value: Int,
    openingTheBus: OpenTheBus,
    driver: any LogicDriver,
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    format: OutputFormat = .compact,
    now: @escaping () -> Date = { Date() },
    git: Git = Git(),
    lock: Lock = Lock(),
    capturer: any WindowCapturer = WindowCapture(),
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    let opened: MidiOutput?
    do {
      opened = try openingTheBus()
    } catch {
      return printer.write(
        Envelope.failure(
          Midi.ControlChange.failure(of: error),
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

    let moved = MoveAController(
      argv: Midi.ControlChange.argv(number: number, value: value),
      output: opened,
      number: number,
      value: value)
    let run = Run(
      driver: driver, root: root, version: version, now: now, git: git, lock: lock,
      capturer: capturer)
    return printer.write(run.run(command: moved))
  }

  /// What the step records as the arguments of the command.
  ///
  /// The numbers are written back as they went out, so a replay of the session moves the same
  /// controller to the same place.
  static func argv(number: Int, value: Int) -> [String] {
    ["--number", String(number), "--value", String(value)]
  }

  /// What the command stopped with before it sent anything.
  static func failure(of error: Error) -> Failure {
    if let refusal = error as? MidiOutput.Refusal {
      return Failure(code: .midiUnavailable, message: refusal.reason)
    }
    return Run.failure(for: error)
  }
}

/// The control change the run records: one message, and nothing to let go of afterwards.
private struct MoveAController: LogicCommand {
  let name = "midi cc"
  let argv: [String]
  let output: MidiOutput
  let number: Int
  let value: Int

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    try output.send(
      MidiMessage.controlChange(
        number: number, value: value, channel: Midi.ControlChange.channel))
    return .object(["sent": .number(1)])
  }
}
