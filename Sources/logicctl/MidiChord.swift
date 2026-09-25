import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Midi {
  /// Plays a chord into Logic.
  ///
  /// A chord is several keys held at once. Every key goes down, the keys are held together for the
  /// length, and then every key comes up. A command that struck one key and let it go before it
  /// struck the next would play the same notes one after the other, which is an arpeggio: Logic
  /// records short notes in a row, and a person who asked for a chord reads a broken one back.
  ///
  /// The chord goes to the port named `logicctl`, the one `midi setup` reports. A Mac that carries
  /// no such port takes nothing, so this command stops there and says so, rather than reporting a
  /// chord that Logic never heard.
  struct Chord: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "chord",
      abstract: "Play a chord into Logic.",
      discussion: """
        The keys are held together for the length, and then they are let go. With a software \
        instrument track armed and recording, the chord lands in a region.

        Example: logicctl midi chord --pitches 60,64,67
        """)

    @Option(help: "The keys of the chord, 0 to 127, separated by commas, where 60 is middle C.")
    var pitches: String

    @Option(help: "How hard every key is struck, 1 to 127. It is 100 when no flag says.")
    var velocity: Velocity?

    @Option(help: "How long the keys are held, for example 500ms.")
    var length: DurationValue = Midi.Chord.lengthByDefault

    @OptionGroup var output: OutputOption

    /// How hard every key of this chord is struck.
    var loudness: Int {
      velocity?.value ?? Midi.Chord.velocityByDefault
    }

    func validate() throws {
      _ = try Midi.Chord.keys(of: pitches)
    }

    func run() throws {
      let status = Midi.Chord.answer(
        pitches: try Midi.Chord.keys(of: pitches),
        velocity: loudness,
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

extension Midi.Chord {
  /// How the command reaches Logic: it finds the port named `logicctl` and opens a way out to it.
  ///
  /// It answers nothing when this Mac carries no such port, which is the Mac `midi setup` reports
  /// the IAC driver off on.
  typealias OpenTheBus = () throws -> MidiOutput?

  /// The channel the chord is sent on. No flag moves it, and Logic counts channels from 1.
  static let channel = 1

  /// How hard every key is struck when no flag says so.
  static let velocityByDefault = 100

  /// How long the keys are held when no flag says so.
  static let lengthByDefault = DurationValue(milliseconds: 500)

  /// The keys of the chord, read from what `--pitches` carries.
  ///
  /// A key named twice is refused. Two note ons of one key leave that key down, because the one
  /// note off that follows lets go of one of them and nothing lets go of the other.
  static func keys(of written: String) throws -> [Int] {
    guard !written.isEmpty else {
      throw ValidationError("--pitches takes at least one key, for example --pitches 60,64,67.")
    }
    var keys: [Int] = []
    for part in written.split(separator: ",", omittingEmptySubsequences: false) {
      let text = part.trimmingCharacters(in: .whitespaces)
      guard let key = Int(text), NotesFile.pitchRange.contains(key) else {
        throw ValidationError(
          "--pitches takes keys of 0 to 127 separated by commas, and \(text) is not one.")
      }
      guard !keys.contains(key) else {
        throw ValidationError(
          "--pitches names the key \(key) twice, and one note off cannot let go of two.")
      }
      keys.append(key)
    }
    return keys
  }

  /// Plays the chord, prints the envelope, and answers the number the process exits with.
  ///
  /// The bus, the driver and the sleep are given rather than reached for, so the pipeline plays the
  /// same chord with nothing of this Mac in the way and no real half second spent waiting.
  static func answer(
    pitches: [Int],
    velocity: Int,
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
          Midi.Chord.failure(of: error),
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

    let played = PlayAChord(
      argv: Midi.Chord.argv(pitches: pitches, velocity: velocity, length: length),
      output: opened,
      pitches: pitches,
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
  /// The values are written back in one form, so a replay of the session plays the same chord
  /// whichever unit a person wrote the length in, and whether or not they named a velocity.
  static func argv(pitches: [Int], velocity: Int, length: DurationValue) -> [String] {
    [
      "--pitches", pitches.map(String.init).joined(separator: ","),
      "--velocity", String(velocity),
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

/// The chord the run records: every key down, the length, then every key up.
///
/// Every note on goes out before the first note off, because that is the whole of what holds the
/// keys together. A send that paired each key with its own note off would play the notes one at a
/// time. The sleep is given, so a test reads the gap without waiting it out.
private struct PlayAChord: LogicCommand {
  let name = "midi chord"
  let argv: [String]
  let output: MidiOutput
  let pitches: [Int]
  let velocity: Int
  let lengthMs: Int
  let sleeper: Wait.Sleeper

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let channel = Midi.Chord.channel
    for pitch in pitches {
      try output.send(MidiMessage.noteOn(pitch: pitch, velocity: velocity, channel: channel))
    }
    sleeper(lengthMs)
    for pitch in pitches {
      try output.send(MidiMessage.noteOff(pitch: pitch, channel: channel))
    }
    return .object(["sent": .number(Double(pitches.count))])
  }
}
