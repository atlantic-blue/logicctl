import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Midi {
  /// Imports a MIDI file into the project Logic has open, and prints the track Logic made for it.
  ///
  /// Logic makes a new software instrument track for a MIDI file. It does not use the track that
  /// is selected, so the answer names the track it made, and where the region on it starts and
  /// ends. The hash of the file goes out with them, so a record of this step says which bytes
  /// reached the project.
  ///
  /// Logic asks whether to import the tempo of the file as well. Both answers change the project
  /// and neither is what the person typed, so logicctl presses nothing: the command stops with
  /// `dialog_open`, and the person answers the question in Logic.
  struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "import",
      abstract: "Import a MIDI file into the project Logic has open.",
      discussion: """
        Logic makes a new software instrument track for the file and puts the region on it. The \
        answer names that track and the bars the region covers. A project logicctl did not make \
        needs --confirm.

        The Import panel of Logic lists visible folders alone, so a file under a hidden folder \
        cannot be reached. A file in /tmp is one of those, because /tmp resolves to /private/tmp.

        Example: logicctl midi import --file notes.mid
        """)

    @Option(help: "The MIDI file to import.")
    var file: String

    @OptionGroup var guarded: ConfirmOption

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    func run() throws {
      let status = Midi.Import.answer(
        driver: Midi.Import.liveDriver(),
        dialog: ImportDialog.live(),
        disk: ImportFile.live(),
        file: file,
        confirmed: guarded.confirm,
        limitMs: wait.timeout.milliseconds,
        format: output.format,
        argv: ["--file", file])
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Midi.Import {
  /// What this command reads Logic through.
  static func liveDriver() -> any LogicDriver {
    NewProject.liveDriver()
  }

  /// Imports the file, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver, the route through the panel and the reads of the disk are given rather than
  /// reached for, so the pipeline drives the same command against a Logic of its own.
  ///
  /// The file is read before anything else. A path the panel cannot walk is an argument that is
  /// wrong, so it is refused here: Logic is asked nothing, the project does not change, and the
  /// session gains no step.
  static func answer(
    driver: any LogicDriver,
    dialog: ImportDialog,
    disk: ImportFile,
    file: String,
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
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    let facts: ImportFile.Facts
    do {
      facts = try disk.facts(of: file)
    } catch {
      return printer.write(
        Envelope.failure(
          Midi.Import.failure(for: error),
          meta: AnswerMeta.refusal(version: version, from: started, to: now())))
    }

    let run = Run(
      driver: driver,
      root: root,
      version: version,
      now: now,
      git: git,
      lock: lock,
      capturer: capturer)
    let command = MidiImportCommand(
      argv: argv,
      facts: facts,
      dialog: dialog,
      limitMs: limitMs,
      clock: clock,
      sleeper: sleeper)
    return printer.write(run.run(change: command, confirmed: confirmed))
  }

  /// The failure a refusal of the disk stopped the command with.
  static func failure(for error: Error) -> Failure {
    if let refusal = error as? ImportFile.Refusal {
      return refusal.failure
    }
    return Failure(
      code: .invalidArgument,
      message: "--file must name a file that can be read: \(error)",
      details: .object(["field": .string("--file")]))
  }
}

/// The import of one MIDI file, as the run of a command sees it.
///
/// It changes the project, so it goes through the guard: a project logicctl did not make is left
/// alone until a person says `--confirm`. The run takes the lock, records the step and answers the
/// envelope around it.
struct MidiImportCommand: LogicCommand {
  let name = "midi import"

  let argv: [String]

  /// Where the file is and what its bytes hash to.
  let facts: ImportFile.Facts

  /// The route through the panel of Logic.
  let dialog: ImportDialog

  /// How long each wait of this command may take, in milliseconds.
  let limitMs: Int

  /// The clock the waits read.
  let clock: Wait.Clock

  /// How a wait sleeps between two reads.
  let sleeper: Wait.Sleeper

  /// Walks the panel to the file, presses Import, and answers the track Logic made for it.
  ///
  /// A press that Logic took proves nothing by itself, so the command reads the project
  /// afterwards. It reports success only once the project holds the new track and that track holds
  /// a region. A press that made no track, and a track that came up empty, both mean the notes are
  /// not in the project, and a person reading a success there would go looking for a region that
  /// is not there.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let before = try driver.readState().tracks
    try dialog.importTheFile(at: facts.path, limitMs: limitMs, clock: clock, sleeper: sleeper)

    try waitForTheProject {
      try driver.readState().tracks.count == before.count + 1
    }
    let after = try driver.readState().tracks
    guard var added = TracksAddCommand.theTrack(gainedFrom: before, in: after) else {
      throw MidiImportCommand.didNotReachTheProject
    }

    try waitForTheProject {
      try MidiImportCommand.theRegion(ofTrackNumbered: added.index, in: driver) != nil
    }
    guard let region = try MidiImportCommand.theRegion(ofTrackNumbered: added.index, in: driver)
    else {
      throw MidiImportCommand.didNotReachTheProject
    }

    // The header of a track says nothing about its kind, so a row read back from Logic reads as
    // the kind that is neither. Logic makes a software instrument track for a MIDI file, and there
    // is no other kind it could have made.
    added.type = .softwareInstrument
    return .object([
      "track": .object([
        "index": .number(Double(added.index)),
        "name": .string(added.name),
        "type": .string(added.type.rawValue),
      ]),
      "region": .object([
        "startBar": MidiImportCommand.bar(in: region.start),
        "endBar": MidiImportCommand.bar(in: region.end),
      ]),
      "sha256": .string(facts.sha256),
    ])
  }

  /// Waits for Logic to show what the import did, and says that the import did not land when it
  /// never does.
  ///
  /// A wait that runs out here is not Logic being slow. The press was taken and the project did
  /// not change, so the answer says that rather than blaming the clock.
  private func waitForTheProject(_ holds: () throws -> Bool) throws {
    do {
      try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper, holds)
    } catch is Wait.RanOut {
      throw MidiImportCommand.didNotReachTheProject
    }
  }

  /// The first region of one track, or nothing when the track holds none.
  static func theRegion(ofTrackNumbered number: Int, in driver: any LogicDriver) throws -> Region? {
    try driver.readState().tracks.first { $0.index == number }?.regions.first
  }

  /// What the command stops with when the notes did not reach the project.
  static let didNotReachTheProject = ImportDialog.Refusal(
    reason:
      "The import did not reach the project: Logic took the press and the project holds no new "
      + "track with a region on it.")

  /// The bar a region starts or ends at, read from the words Logic shows, for example `2 bars`.
  ///
  /// Logic writes the position of a region as text, and the answer carries a number so that an
  /// agent can compare two imports without reading English. Text that carries no number answers
  /// null rather than a number nobody measured.
  static func bar(in shown: String) -> JSONValue {
    let digits = shown.prefix { $0.isNumber }
    guard let number = Int(digits) else {
      return .null
    }
    return .number(Double(number))
  }
}
