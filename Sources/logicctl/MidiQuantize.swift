import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Midi {
  /// Moves every note of one region onto a grid.
  ///
  /// Logic quantizes the notes that are selected, and it selects them in the Piano Roll. The
  /// command selects every note of the region there, sets the grid and the strength, presses Time
  /// Quantize, and prints the notes as the Event List shows them afterwards. A pitch and a
  /// velocity are not the timing of a note, so neither of them changes.
  struct Quantize: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "quantize",
      abstract: "Move the notes of one region onto a grid.",
      discussion: """
        Logic quantizes what is selected in the Piano Roll, so the Piano Roll of the region is \
        open while this runs. The notes after the change are read from the Event List, so that \
        window is open too. A grid that Logic does not offer is refused before logicctl talks to \
        Logic at all.

        Example: logicctl midi quantize --track 4 --region 1 --value 1/16 --strength 100
        """)

    @OptionGroup var region: RegionOption

    @Option(help: "The grid the notes move onto, for example 1/16, or 1/8t for a triplet.")
    var value: QuantizeValue

    @Option(help: "How far each note moves onto the grid, 0 to 100.")
    var strength: QuantizeStrength

    @OptionGroup var guarded: ConfirmOption

    @OptionGroup var output: OutputOption

    func run() throws {
      let status = answer(
        driver: Midi.Quantize.liveDriver(),
        of: LogicTree.ofRunningLogic,
        confirmed: guarded.confirm,
        format: output.format)
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Midi.Quantize {
  /// Quantizes the region, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver, the tree and the Piano Roll are given rather than reached for, so the pipeline
  /// drives the same command against a Logic of its own: the driver says what the project holds,
  /// the tree is the windows Logic is showing, and the Piano Roll is what Logic is asked to do.
  func answer(
    driver: any LogicDriver,
    of source: @escaping () throws -> LogicTree,
    confirmed: Bool,
    pianoRoll: PianoRoll = PianoRoll.live(),
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    format: OutputFormat = .compact,
    argv: [String] = [],
    now: @escaping () -> Date = { Date() },
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
    return printer.write(
      run.run(
        command: MidiQuantizeCommand(
          target: region,
          value: value,
          strength: strength,
          pianoRoll: pianoRoll,
          source: source,
          argv: argv)))
  }

  /// What this command reads Logic through on this Mac.
  static func liveDriver() -> any LogicDriver {
    Tracks.liveDriver()
  }
}

/// The quantize of one region, as the run of a command sees it.
///
/// It asks the driver which region the two numbers name, quantizes in the Piano Roll, and reads
/// the notes back out of the Event List. The run takes the lock, records the step and answers the
/// envelope around it.
struct MidiQuantizeCommand: LogicCommand {
  let name = "midi quantize"

  /// The two numbers that name the region.
  let target: RegionOption

  /// The grid the notes move onto.
  let value: QuantizeValue

  /// How far each note moves onto the grid.
  let strength: QuantizeStrength

  /// What Logic is asked to do in the Piano Roll.
  let pianoRoll: PianoRoll

  /// The tree of Logic, as the command reads it. It is read again after the quantize, because a
  /// tree read before a change describes the Logic of a moment ago.
  let source: () throws -> LogicTree

  let argv: [String]

  /// Logic is showing no Piano Roll, so there is nothing to select and nothing to quantize.
  ///
  /// logicctl opens no window itself, so the sentence says what to do rather than naming an
  /// element nobody asked about.
  struct NoPianoRoll: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "Logic shows no Piano Roll, so the notes of region \(region) on track \(track) "
          + "cannot be quantized. Select the region and open the Piano Roll.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
        ]))
    }
  }

  /// Logic is showing no Event List, so the notes after the quantize cannot be read.
  ///
  /// The quantize happened by the time this is thrown. The command says so, because a person
  /// reading it needs to know that the notes moved and only the answer is missing.
  struct NoEventListAfter: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "Region \(region) on track \(track) was quantized, and Logic shows no Event List, so "
          + "the notes after the change cannot be read. Open the Event List and read them with "
          + "midi notes.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
        ]))
    }
  }

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let region = try RegionTarget.region(target, in: try driver.readState())
    guard PianoRoll.window(of: try source()) != nil else {
      throw NoPianoRoll(track: target.track.value, region: region.index)
    }
    try pianoRoll.quantize(value, strength: strength) {
      guard let window = PianoRoll.window(of: try source()) else {
        throw NoPianoRoll(track: target.track.value, region: region.index)
      }
      return window
    }
    guard let events = EventList.window(of: try source()) else {
      throw NoEventListAfter(track: target.track.value, region: region.index)
    }
    let notes = try EventList.notes(in: events)
    return .object(["notes": .array(notes.map(\.json))])
  }
}
