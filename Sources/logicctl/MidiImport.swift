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
  ///
  /// The dialog carries four controls, read from Logic 12.3.1 on 2026-09-25: the buttons
  /// `action-button-1` No, `action-button-2` Import Tempo and `action-button-3` Cancel, and the
  /// checkbox `supression-checkbox`, Don’t ask again. logicctl presses none of them. The checkbox
  /// is the one that would last: a tick there stops Logic asking anybody again, on every later
  /// import a person makes by hand.
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
    let channels: [Int]
    do {
      facts = try disk.facts(of: file)
      channels = MidiImportCommand.channels(usedIn: [UInt8](try disk.read(facts.path.resolved)))
    } catch {
      return printer.write(
        Envelope.failure(
          Midi.Import.failure(for: error),
          meta: AnswerMeta.refusal(version: version, from: started, to: now())))
    }
    guard !channels.isEmpty else {
      return printer.write(
        Envelope.failure(
          Midi.Import.namesNoChannel(file),
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
      channels: channels,
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

  /// What the command refuses a file with when its bytes name no MIDI channel.
  ///
  /// Logic makes one track for each channel a file uses, so a file that uses none gives the
  /// command nothing to wait for. A run that pressed Import here would wait out its limit and
  /// answer a timeout for a file that carries no notes at all.
  static func namesNoChannel(_ file: String) -> Failure {
    Failure(
      code: .invalidArgument,
      message: "--file must name a MIDI file that carries notes, and \(file) carries no event "
        + "on any MIDI channel.",
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

  /// The MIDI channels the events of the file use, from 1, lowest first. Logic makes one track
  /// for each of them, so this is how many tracks the command waits for.
  let channels: [Int]

  /// The route through the panel of Logic.
  let dialog: ImportDialog

  /// How long each wait of this command may take, in milliseconds.
  let limitMs: Int

  /// The clock the waits read.
  let clock: Wait.Clock

  /// How a wait sleeps between two reads.
  let sleeper: Wait.Sleeper

  /// Walks the panel to the file, presses Import, and answers every track Logic made for it.
  ///
  /// Logic makes one software instrument track for each MIDI channel the file uses. Measured on
  /// this Mac on 2026-09-27: a copy of 5 tracks held 7 after a file of two channels was imported.
  /// So the command waits for one new track for each channel of the file, and answers all of
  /// them. A command that waited for one would wait out its limit and report that nothing
  /// happened, while the notes were in the project and the person had tracks nobody asked for.
  ///
  /// A press that Logic took proves nothing by itself, so the command reads the project
  /// afterwards. It reports success only once every one of those tracks holds a region. A press
  /// that made no track, and a track that came up empty, both mean notes are missing from the
  /// project, and a person reading a success there would go looking for a region that is not
  /// there.
  ///
  /// `track` and `region` carry the first of the tracks, which is what they carried when the
  /// answer named one track, so a caller written against that answer reads the same two fields.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let before = try driver.readState().tracks
    try dialog.importTheFile(at: facts.path, limitMs: limitMs, clock: clock, sleeper: sleeper)

    try waitForTheProject {
      try driver.readState().tracks.count == before.count + channels.count
    }
    let after = try driver.readState().tracks
    let made = TracksAddCommand.theTracks(gainedFrom: before, in: after)
    guard made.count == channels.count else {
      throw MidiImportCommand.didNotReachTheProject
    }

    try waitForTheProject {
      let rows = try driver.readState().tracks
      return made.allSatisfy { track in
        rows.first(where: { $0.index == track.index })?.regions.first != nil
      }
    }

    var landed: [(track: Track, region: Region)] = []
    for row in made {
      guard let region = try MidiImportCommand.theRegion(ofTrackNumbered: row.index, in: driver)
      else {
        throw MidiImportCommand.didNotReachTheProject
      }
      // The header of a track says nothing about its kind, so a row read back from Logic reads
      // as the kind that is neither. Logic makes a software instrument track for each channel of
      // a MIDI file, and there is no other kind it could have made.
      var track = row
      track.type = .softwareInstrument
      landed.append((track: track, region: region))
    }
    guard let first = landed.first else {
      throw MidiImportCommand.didNotReachTheProject
    }

    return .object([
      "track": MidiImportCommand.row(of: first.track),
      "region": MidiImportCommand.bars(of: first.region),
      "tracks": .array(landed.map { MidiImportCommand.entry(of: $0.track, with: $0.region) }),
      "sha256": .string(facts.sha256),
    ])
  }

  /// One track of the answer: its number, its name and its kind.
  static func row(of track: Track) -> JSONValue {
    .object([
      "index": .number(Double(track.index)),
      "name": .string(track.name),
      "type": .string(track.type.rawValue),
    ])
  }

  /// Where a region starts and ends, as bars.
  static func bars(of region: Region) -> JSONValue {
    .object([
      "startBar": MidiImportCommand.bar(in: region.start),
      "endBar": MidiImportCommand.bar(in: region.end),
    ])
  }

  /// One entry of `tracks`: a track Logic made, and where the region on it sits.
  static func entry(of track: Track, with region: Region) -> JSONValue {
    .object([
      "index": .number(Double(track.index)),
      "name": .string(track.name),
      "type": .string(track.type.rawValue),
      "region": MidiImportCommand.bars(of: region),
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

extension MidiImportCommand {
  /// One chunk of a standard MIDI file: its name, and where its bytes start and end.
  struct Chunk {
    let name: String
    let start: Int
    let end: Int
  }

  /// The MIDI channels the events of a standard MIDI file use, from 1, lowest first.
  ///
  /// The bytes are walked and not searched. A file may write a run of notes in running status,
  /// where the status byte is left out and the data bytes follow on their own, so a search for
  /// bytes from 0x80 to 0xEF would read a data byte as a status byte and count a channel nobody
  /// used. The walk reads a delta time, then the event, and it knows how long each event is.
  ///
  /// Bytes the walk cannot read end the walk and keep what it read up to there. A file that is
  /// not a standard MIDI file names no channel, and the caller refuses it before Logic is asked
  /// anything.
  static func channels(usedIn bytes: [UInt8]) -> [Int] {
    var used: Set<Int> = []
    var place = 0
    while let chunk = MidiImportCommand.chunk(at: place, in: bytes) {
      if chunk.name == "MTrk" {
        MidiImportCommand.readEvents(of: Array(bytes[chunk.start..<chunk.end]), into: &used)
      }
      place = chunk.end
    }
    return used.sorted()
  }

  /// The chunk that starts at one place, or nothing when the bytes carry no whole chunk there.
  ///
  /// A chunk is four bytes of name, four bytes of length with the highest byte first, and then
  /// that many bytes.
  static func chunk(at place: Int, in bytes: [UInt8]) -> Chunk? {
    guard place >= 0, place + 8 <= bytes.count else {
      return nil
    }
    let name = String(decoding: bytes[place..<(place + 4)], as: UTF8.self)
    var length = 0
    for step in 0..<4 {
      length = (length << 8) | Int(bytes[place + 4 + step])
    }
    let start = place + 8
    let end = start + length
    guard end <= bytes.count else {
      return nil
    }
    return Chunk(name: name, start: start, end: end)
  }

  /// Every channel the events of one track chunk use, added to what is known already.
  ///
  /// A meta event and a system exclusive event each carry their own length and are stepped over.
  /// A byte under 0x80 where a status byte belongs is running status: the event repeats the
  /// status of the event before it, and only a channel event may be repeated that way.
  static func readEvents(of bytes: [UInt8], into used: inout Set<Int>) {
    var place = 0
    var running: UInt8?
    while place < bytes.count {
      guard let time = MidiImportCommand.variableLength(at: place, in: bytes) else {
        return
      }
      place = time.after
      guard place < bytes.count else {
        return
      }

      var status = bytes[place]
      if status < 0x80 {
        guard let repeated = running else {
          return
        }
        status = repeated
      } else {
        place += 1
      }

      if status < 0xf0 {
        running = status
        used.insert(Int(status & 0x0f) + 1)
        place += MidiImportCommand.dataBytes(after: status)
        continue
      }

      running = nil
      switch status {
      case 0xff:
        guard place < bytes.count else {
          return
        }
        place += 1
        guard let length = MidiImportCommand.variableLength(at: place, in: bytes) else {
          return
        }
        place = length.after + length.value
      case 0xf0, 0xf7:
        guard let length = MidiImportCommand.variableLength(at: place, in: bytes) else {
          return
        }
        place = length.after + length.value
      case 0xf2:
        place += 2
      case 0xf3:
        place += 1
      default:
        break
      }
    }
  }

  /// How many data bytes follow one channel status byte. A program change and a channel pressure
  /// carry one, and every other channel message carries two.
  static func dataBytes(after status: UInt8) -> Int {
    let kind = status & 0xf0
    return (kind == 0xc0 || kind == 0xd0) ? 1 : 2
  }

  /// A variable length quantity read at one place: its value, and the place after it.
  ///
  /// The format writes seven bits of the number in each byte, with the top bit set on every byte
  /// but the last, and four bytes at most.
  static func variableLength(at place: Int, in bytes: [UInt8]) -> (value: Int, after: Int)? {
    var value = 0
    var here = place
    for _ in 0..<4 {
      guard here >= 0, here < bytes.count else {
        return nil
      }
      let byte = bytes[here]
      here += 1
      value = (value << 7) | Int(byte & 0x7f)
      if byte & 0x80 == 0 {
        return (value, here)
      }
    }
    return nil
  }
}
