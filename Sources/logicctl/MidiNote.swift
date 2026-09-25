import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Midi {
  /// Plays one note into Logic.
  ///
  /// A note is two messages. Note on starts it, note off stops it, and the length is the gap
  /// between the two. A command that sent only the first would leave the key held down: Logic goes
  /// on sounding the note, and a take recorded after it holds one note that never ends.
  ///
  /// The note goes to the port named `logicctl`, the one `midi setup` reports. A Mac that carries
  /// no such port takes nothing, so this command stops there and says so, rather than reporting a
  /// note that Logic never heard.
  struct Note: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "note",
      abstract: "Play one note into Logic.",
      discussion: """
        The note is held for the length, and then it is let go. With a software instrument track \
        armed and recording, the note lands in a region.

        Example: logicctl midi note --pitch 60 --velocity 100 --length 500ms
        """)

    @Option(help: "The key, 0 to 127, where 60 is middle C.")
    var pitch: Int

    @Option(help: "How hard the key is struck, 1 to 127.")
    var velocity: Velocity

    @Option(help: "How long the key is held, for example 500ms.")
    var length: DurationValue

    @OptionGroup var output: OutputOption

    func validate() throws {
      guard NotesFile.pitchRange.contains(pitch) else {
        throw ValidationError("--pitch is a key of 0 to 127, and \(pitch) is not one.")
      }
    }

    func run() throws {
      let status = Midi.Note.answer(
        pitch: pitch,
        velocity: velocity,
        length: length,
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

extension Midi.Note {
  /// How the command reaches Logic: it finds the port named `logicctl` and opens a way out to it.
  ///
  /// It answers nothing when this Mac carries no such port, which is the Mac `midi setup` reports
  /// the IAC driver off on.
  typealias OpenTheBus = () throws -> MidiOutput?

  /// The channel the note is sent on. No flag moves it, and Logic counts channels from 1.
  static let channel = 1

  /// Plays the note, prints the envelope, and answers the number the process exits with.
  ///
  /// The bus, the driver and the sleep are given rather than reached for, so the pipeline plays the
  /// same note with nothing of this Mac in the way and no real half second spent waiting.
  static func answer(
    pitch: Int,
    velocity: Velocity,
    length: DurationValue,
    openingTheBus: OpenTheBus,
    driver: any LogicDriver,
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    format: OutputFormat = .compact,
    now: @escaping () -> Date = { Date() },
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

    let opened: MidiOutput?
    do {
      opened = try openingTheBus()
    } catch {
      return printer.write(
        Envelope.failure(
          Midi.Note.failure(of: error),
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

    let played = PlayANote(
      argv: Midi.Note.argv(pitch: pitch, velocity: velocity, length: length),
      output: opened,
      pitch: pitch,
      velocity: velocity,
      lengthMs: length.milliseconds,
      sleeper: sleeper)
    let run = Run(
      driver: driver, root: root, version: version, now: now, git: git, lock: lock,
      capturer: capturer)
    return printer.write(run.run(command: played))
  }

  /// What the step records as the arguments of the command.
  ///
  /// The values are written back in one form, so a replay of the session plays the same note
  /// whichever unit a person wrote the length in.
  static func argv(pitch: Int, velocity: Velocity, length: DurationValue) -> [String] {
    [
      "--pitch", String(pitch),
      "--velocity", String(velocity.value),
      "--length", "\(length.milliseconds)ms",
    ]
  }

  /// What the command stopped with before it played anything.
  static func failure(of error: Error) -> Failure {
    if let refusal = error as? MidiOutput.Refusal {
      return Failure(code: .midiUnavailable, message: refusal.reason)
    }
    return Run.failure(for: error)
  }
}

/// The note the run records: note on, the length, then note off.
///
/// The messages go out in that order and the gap between them is the length, because those two
/// things are the whole of what a person asked for. The sleep is given, so a test reads the gap
/// without waiting it out.
private struct PlayANote: LogicCommand {
  let name = "midi note"
  let argv: [String]
  let output: MidiOutput
  let pitch: Int
  let velocity: Velocity
  let lengthMs: Int
  let sleeper: Wait.Sleeper

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let channel = Midi.Note.channel
    try output.send(MidiMessage.noteOn(pitch: pitch, velocity: velocity.value, channel: channel))
    sleeper(lengthMs)
    try output.send(MidiMessage.noteOff(pitch: pitch, channel: channel))
    return .object(["sent": .number(1)])
  }
}
