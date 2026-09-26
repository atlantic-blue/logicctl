import Foundation
import LogicctlCore
import Testing

/// Phase 4 of the stories, against the Logic that runs on this Mac.
///
/// The pipeline proves every command of this phase against a fake, which says nothing about what
/// Logic does when the command reaches it. Five of the nine edits below never ran against the
/// application at all: quantize, velocity, the two automation writes and the plugin insert. This
/// is where that is answered.
///
/// The phase works on one copy of the scratch project, in a folder of the run, and it makes its
/// own region: it writes a MIDI file of four notes off the grid and imports that file onto a new
/// track. So what each read must answer is known before Logic answers it.
enum PhaseFour {
  /// The grid the run quantizes onto.
  static let grid = "1/16"

  /// The region every scenario works on, the one the import made on its new track.
  static let region = "1"

  /// The tempo of the file the run writes.
  static let tempo = 120.0

  /// The plugin the run inserts, named as Logic writes it in the menu.
  static let plugin = "Channel EQ"

  /// A plugin Logic does not offer, so the run reads `plugin_not_found`.
  static let pluginUnknown = "No Such EQ"

  /// The note the run changes, and the velocity it gives it.
  static let notePicked = 2
  static let velocityGiven = 90

  /// The point the run changes, and the value it gives it.
  static let pointPicked = 1
  static let valueGiven = 60

  /// A note and a point the region does not hold, so the run reads the two not found codes.
  static let noteUnknown = 9
  static let pointUnknown = 9

  /// How long the run waits for a person at the Mac, and how long it leaves between two reads.
  static let byHandLimitMs = 180_000
  static let byHandPollMs = 2_000

  /// One note of the file the run imports.
  struct KnownNote: Equatable, Sendable {
    let pitch: Int
    let velocity: Int
    let start: Double
    let length: Double
    let channel: Int
  }

  /// The notes the run writes into its MIDI file, and reads back out of Logic.
  ///
  /// None of them starts on a sixteenth, so quantize has something to move, and no two of them
  /// land on the same sixteenth when it does. The velocities are four different numbers, so a
  /// velocity that reached the wrong note cannot read as the value that note already had.
  static let knownNotes: [KnownNote] = [
    KnownNote(pitch: 60, velocity: 40, start: 0.1, length: 0.5, channel: 1),
    KnownNote(pitch: 62, velocity: 70, start: 0.9, length: 0.5, channel: 1),
    KnownNote(pitch: 64, velocity: 100, start: 2.1, length: 0.5, channel: 1),
    KnownNote(pitch: 65, velocity: 127, start: 2.85, length: 0.5, channel: 1),
  ]

  /// One command of the phase, and what it leaves alone while it runs.
  struct Edit: Equatable, Sendable {
    /// The words a person types, for example `midi quantize`.
    let command: String

    /// The contract it answers, for example `CMD-S4.2`.
    let contract: String

    /// The scenario that drives it, and the name that scenario prints as it starts.
    let scenario: String

    /// What still carries the value it carried before, in the words a person reads.
    let keeps: String
  }

  /// Every command of phase 4, in the order the acceptance run drives them.
  ///
  /// An acceptance run is counted and not read: `make accept PART=4` counts the line each
  /// scenario prints as it starts, and it refuses a run that left one out. So the phase is a
  /// list, and a command with no entry here is a command an accepted phase 4 never drove.
  static let flow: [Edit] = [
    Edit(
      command: "midi notes",
      contract: "CMD-S4.1",
      scenario: "notesOfTheImportedRegionMatchTheFile",
      keeps: "the region as the file wrote it"),
    Edit(
      command: "midi quantize",
      contract: "CMD-S4.2",
      scenario: "quantizeMovesEveryNoteOntoTheGrid",
      keeps: "the pitch, the velocity, the length and the channel of every note"),
    Edit(
      command: "midi velocity",
      contract: "CMD-S4.3",
      scenario: "velocityChangesOneNoteAndLeavesTheRest",
      keeps: "every note the command did not name"),
    Edit(
      command: "automation add",
      contract: "CMD-S4.4",
      scenario: "automationAddPrintsThePointsLogicMade",
      keeps: "every note of the region"),
    Edit(
      command: "automation list",
      contract: "CMD-S4.5",
      scenario: "automationListReadsThePointsOfTheRegion",
      keeps: "every point and every note, because it changes nothing"),
    Edit(
      command: "automation set",
      contract: "CMD-S4.6",
      scenario: "automationSetChangesOnePointAndLeavesTheRest",
      keeps: "every other point, and every note"),
    Edit(
      command: "plugins list",
      contract: "CMD-S4.7",
      scenario: "pluginsListReadsTheStripInSlotOrder",
      keeps: "the channel strip, because it changes nothing"),
    Edit(
      command: "plugins insert",
      contract: "CMD-S4.8",
      scenario: "pluginsInsertFillsTheFirstEmptySlot",
      keeps: "the slot and the name of every plugin the strip already held"),
    Edit(
      command: "midi velocity",
      contract: "RUN-8",
      scenario: "anEditMeetingTwoSelectedRowsChangesNothing",
      keeps: "every note, because the edit stops before it writes"),
  ]
}

extension PhaseFour {
  /// One note row of the Event List, as `midi notes` prints it.
  struct Note: Decodable, Equatable, Sendable {
    var note: Int
    var position: String
    var pitch: Int
    var velocity: Int
    var length: String
    var channel: Int
  }

  /// One automation point of the region, as `automation list` prints it.
  struct Point: Decodable, Equatable, Sendable {
    var point: Int
    var position: String
    var parameter: String
    var value: Int
  }

  /// One plugin of the channel strip, as `plugins list` prints it.
  struct Plugin: Decodable, Equatable, Sendable {
    var slot: Int
    var name: String
  }

  /// What the three commands that answer with the notes of the region print.
  struct NotesAnswer: Decodable {
    var notes: [Note]
  }

  /// What the three automation commands print.
  struct PointsAnswer: Decodable {
    var track: Int
    var region: Int
    var points: [Point]
  }

  /// What `plugins list` and `plugins insert` print.
  struct PluginsAnswer: Decodable {
    var plugins: [Plugin]
  }

  /// What `midi write-file` prints.
  struct WrittenAnswer: Decodable {
    var path: String
    var notes: Int
    var sha256: String
  }

  /// What `midi import` prints.
  struct ImportedAnswer: Decodable {
    /// The track Logic made for the file.
    struct Track: Decodable {
      var index: Int
      var name: String
      var type: String
    }

    /// The bars the region covers, as Logic shows them.
    struct Region: Decodable {
      var startBar: Int?
      var endBar: Int?
    }

    var track: Track
    var region: Region
    var sha256: String
  }

  /// What `midi velocity` prints.
  struct VelocityAnswer: Decodable {
    var track: Int
    var region: Int
    var note: Int
    var velocity: Int
  }

  /// The failure of one command, with the rows a `selection_mismatch` names.
  ///
  /// The harness reads a code and a message. `RUN-8` is about the rows underneath them, so this
  /// phase reads the envelope again for the one field it needs.
  struct Refused: Decodable {
    /// What the envelope carries under `error`.
    struct Body: Decodable {
      var code: String
      var message: String
      var details: Details?
    }

    /// The one field of `error.details` this phase reads.
    struct Details: Decodable {
      var selected: [String]?
    }

    var error: Body?
  }
}

extension PhaseFour {
  /// Why phase 4 stopped before it could say anything about Logic.
  enum Trouble: Error, CustomStringConvertible {
    /// `midi write-file` wrote a file that carries other notes than the ones the run knows.
    case theFileHoldsOtherNotes(wrote: Int, wanted: Int)

    /// The Mac never showed what the run asked a person for.
    case theMacNeverShowed(asking: String, waitedMs: Int)

    /// A command printed text that is no envelope.
    case theCommandPrintedNoEnvelope(command: String, printed: String)

    var description: String {
      switch self {
      case .theFileHoldsOtherNotes(let wrote, let wanted):
        return """
          midi write-file wrote \(wrote) notes and the run knows \(wanted), so the region would \
          be read against a file it did not come from
          """
      case .theMacNeverShowed(let asking, let waitedMs):
        return "the Mac never showed this in \(waitedMs)ms. It asked for: \(asking)"
      case .theCommandPrintedNoEnvelope(let command, let printed):
        return "logicctl \(command) printed no envelope this phase reads back: \(printed)"
      }
    }
  }
}

extension PhaseFour {
  /// The text of the file `midi write-file` reads.
  ///
  /// It is built from the notes above rather than kept beside them, so the notes the scenarios
  /// check and the notes the file carries cannot drift apart.
  static var notesFileText: String {
    let rows = knownNotes.map { note in
      "{\"pitch\": \(note.pitch), \"velocity\": \(note.velocity), "
        + "\"start\": \(note.start), \"length\": \(note.length), \"channel\": \(note.channel)}"
    }
    return "{\"tempo\": \(tempo), \"notes\": [" + rows.joined(separator: ", ") + "]}\n"
  }

  /// The words that read the notes of the region.
  static func notesOf(track: Int) -> [String] {
    ["midi", "notes", "--track", "\(track)", "--region", region]
  }

  /// The words that quantize the region onto the grid.
  ///
  /// There is no `--confirm` here, and none on `midi velocity` either. Both change the project
  /// and neither one goes through the guard that `RUN-4` describes, which the other three writes
  /// of this phase do go through. The run calls them as they are.
  static func quantizeOf(track: Int) -> [String] {
    [
      "midi", "quantize", "--track", "\(track)", "--region", region, "--value", grid,
      "--strength", "100",
    ]
  }

  /// The words that set the velocity of one note.
  static func velocityOf(track: Int, note: Int, value: Int) -> [String] {
    [
      "midi", "velocity", "--track", "\(track)", "--region", region, "--note", "\(note)",
      "--value", "\(value)",
    ]
  }

  /// The words that make the automation points of the region.
  static func automationAddOf(track: Int) -> [String] {
    ["automation", "add", "--track", "\(track)", "--region", region, "--confirm"]
  }

  /// The words that read the automation points of the region.
  static func automationListOf(track: Int) -> [String] {
    ["automation", "list", "--track", "\(track)", "--region", region]
  }

  /// The words that set the value of one automation point.
  static func automationSetOf(track: Int, point: Int, value: Int) -> [String] {
    [
      "automation", "set", "--track", "\(track)", "--region", region, "--point", "\(point)",
      "--value", "\(value)", "--confirm",
    ]
  }

  /// The words that read the channel strip of the track.
  static func pluginsListOf(track: Int) -> [String] {
    ["plugins", "list", "--track", "\(track)"]
  }

  /// The words that insert one plugin into the first empty slot of the strip.
  static func pluginsInsertOf(track: Int, name: String) -> [String] {
    ["plugins", "insert", "--track", "\(track)", "--name", name, "--confirm"]
  }
}

extension PhaseFour {
  /// Names every note that is not the note it was, and says what moved.
  ///
  /// The position is left out on purpose. Quantize moves a position, and that is the change it is
  /// for, so a position that moved is not a note that changed. Everything else is what the
  /// stories mean by a note that keeps its value, and an edit that reached a note it was never
  /// given shows up here as a line.
  static func notesThatChanged(from before: [Note], to after: [Note]) -> [String] {
    []
  }

  /// Names every point that is not the point it was, and says what moved.
  ///
  /// A point carries a position as well as a value, and `automation set` moves neither one but
  /// the value it was given. So all four fields are read here, unlike the notes above.
  static func pointsThatChanged(from before: [Point], to after: [Point]) -> [String] {
    []
  }

  /// Every way the region does not carry the notes of the file it came from.
  ///
  /// The position and the length come back in the words Logic shows, which are bars and beats
  /// against the tempo of the project, and the file wrote beats from its own start. So those two
  /// are not compared as numbers. What is compared is what an import does not change: how many
  /// notes there are, the pitch, the velocity and the channel of each one, and the order. The
  /// file gave every note one length, so the rows carry one length between them too.
  static func differencesFromTheFile(_ read: [Note]) -> [String] {
    []
  }

  /// The numbers Logic shows in a position, or nothing when it shows something else.
  static func numbers(of position: String) -> [Int]? {
    let parts = position.split(separator: " ").map(String.init)
    let read = parts.compactMap { Int($0) }
    guard !read.isEmpty, read.count == parts.count else {
      return nil
    }
    return read
  }

  /// Whether Logic shows this position on the grid, with nothing after the division.
  ///
  /// Logic writes a position as four numbers: the bar, the beat, the division and the tick. A
  /// division is a sixteenth and the tick counts from 1 inside it, so a note that quantize put on
  /// the grid reads with a tick of 1, and a note between two sixteenths reads with anything else.
  static func onTheGrid(_ position: String) -> Bool {
    true
  }

  /// Whether these positions rise, read as the numbers Logic shows and not as text.
  ///
  /// Text is the wrong order, because bar 10 sorts before bar 9 as words.
  static func inTimeOrder(_ positions: [String]) -> Bool {
    true
  }

  /// Whether one position comes after another, place by place.
  static func rises(from earlier: [Int], to later: [Int]) -> Bool {
    for (was, now) in zip(earlier, later) where now != was {
      return now > was
    }
    return false
  }

  /// The slot a plugin lands in: the first number from 1 up that the strip does not hold.
  static func firstEmptySlot(after plugins: [Plugin]) -> Int {
    1
  }

  /// The failure one command printed, read for the rows it names.
  static func refusal(of answer: LiveHarness.Answer, from command: String) throws -> Refused {
    guard let bytes = answer.printed.data(using: .utf8) else {
      throw Trouble.theCommandPrintedNoEnvelope(command: command, printed: answer.printed)
    }
    do {
      return try JSONDecoder().decode(Refused.self, from: bytes)
    } catch {
      throw Trouble.theCommandPrintedNoEnvelope(command: command, printed: answer.printed)
    }
  }

  /// Asks a person at the Mac for something, and waits until it is there.
  ///
  /// Two things in this phase need a hand. Logic shows the notes and the points of a region in
  /// the Event List of that region, and the plugins in the Mixer, and no command opens either
  /// window. And a selection of two rows is a thing no command makes, because the guard of every
  /// edit writes the whole selection itself before it reads it back.
  ///
  /// The line starts with `by hand:` and not with `live scenario:`, because `make accept` counts
  /// the second one and a line that asked for something is not a scenario that ran. The wait ends
  /// at the limit rather than holding the run for ever, and it says what it asked for.
  static func byHand(
    _ asking: String,
    limitMs: Int = PhaseFour.byHandLimitMs,
    pollMs: Int = PhaseFour.byHandPollMs,
    clock: Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: Wait.Sleeper = Wait.sleepMilliseconds,
    until holds: () throws -> Bool
  ) throws {
    print("by hand: \(asking)")
  }
}

/// The one project the scenarios of phase 4 work on.
///
/// Logic shows one project at a time, and the import makes one track in it, so the phase opens
/// one copy and every scenario works on that. The suite is serialized, so one scenario reads this
/// at a time, and the lock is here for the day that changes.
///
/// The folder is left where it is when the run ends. It sits under the temporary folder of this
/// Mac, never under the music folder, and the session repository of the run is the record of what
/// the phase did to it.
private final class AcceptanceRun: @unchecked Sendable {
  /// What the phase made before its first scenario read anything.
  struct Opened {
    /// The folder of this run.
    let folder: URL

    /// The copy Logic has open.
    let copy: URL

    /// The MIDI file the run wrote and imported.
    let file: URL

    /// The track the import made.
    let track: Int
  }

  private let lock = NSLock()
  private var opened: Opened?

  /// The copy and the imported track, made on the first read and shared after it.
  func ready() throws -> Opened {
    lock.lock()
    defer { lock.unlock() }
    if let made = opened {
      return made
    }
    let made = try start()
    opened = made
    return made
  }

  private func start() throws -> Opened {
    let folder = try LiveHarness.temporaryFolder()
    let copy = try LiveHarness.copyOfTheScratchProject(into: folder)
    try LiveHarness.openInLogic(copy)

    let notes = folder.appending(path: "phase-four-notes.json")
    let file = folder.appending(path: "phase-four.mid")
    try PhaseFour.notesFileText.write(to: notes, atomically: true, encoding: .utf8)
    let written = try LiveHarness.read(
      PhaseFour.WrittenAnswer.self,
      from: ["midi", "write-file", "--in", notes.path, "--out", file.path])
    guard written.notes == PhaseFour.knownNotes.count else {
      throw PhaseFour.Trouble.theFileHoldsOtherNotes(
        wrote: written.notes, wanted: PhaseFour.knownNotes.count)
    }

    let imported = try LiveHarness.read(
      PhaseFour.ImportedAnswer.self,
      from: ["midi", "import", "--file", file.path, "--confirm"])
    let track = imported.track.index

    try PhaseFour.byHand(
      "select region \(PhaseFour.region) on track \(track), the one the import just made, "
        + "then open its Event List and open the Mixer, and leave both windows open. Every read "
        + "of this phase walks to those two windows.",
      until: {
        let answer = try LiveHarness.logicctl(PhaseFour.notesOf(track: track))
        let read = try? LiveHarness.envelope(
          PhaseFour.NotesAnswer.self, of: answer, from: "midi notes")
        return read?.data?.notes.count == PhaseFour.knownNotes.count
      })

    return Opened(folder: folder, copy: copy, file: file, track: track)
  }
}

/// The one acceptance run of this phase.
private let theRun = AcceptanceRun()

/// The edits of phase 4, driven against the Logic that runs on this Mac.
///
/// They run one at a time and in this order, because they work on one region: the import makes
/// it, the automation points arrive part way through, and each edit reads back what the one
/// before it left.
@Suite(.serialized, .enabled(if: LiveHarness.runsLive()))
struct Phase4LiveScenarios {}

/// Where the text of the live scenarios ends.
///
/// The scenario below reads this file, to say that every edit of the flow has a scenario and that
/// each one prints the line an acceptance run counts. The words it looks for are written in the
/// scenario itself as well, so a scan of the whole file would find its own assertions and report
/// a phase with no scenarios as a phase with all of them. The scan stops at the first place this
/// sentence appears, which is this line.
private let liveScenariosEndHere = "private let liveScenariosEndHere"

extension PhaseFour {
  /// The text of this file, up to the line that ends the live scenarios.
  static func sourceOfTheLiveScenarios() throws -> String {
    let whole = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
    guard let end = whole.range(of: liveScenariosEndHere) else {
      return whole
    }
    return String(whole[whole.startIndex..<end.lowerBound])
  }

  /// Every scenario declared in that text, in the order it declares them.
  static func scenariosDeclared(in source: String) -> [String] {
    source.components(separatedBy: "@Test func ").dropFirst().compactMap {
      piece -> String? in
      let name = piece.prefix { $0 != "(" }
      return name.isEmpty ? nil : String(name)
    }
  }
}

/// An accepted phase 4 drove every edit against Logic, and left every value it did not name.
///
/// This scenario runs in the pipeline, where there is no Logic, so it is not the phase passing.
/// It is the shape of the pass: the run drives all nine edits, in the order they depend on each
/// other, each one announces itself so `make accept PART=4` can count it, and the comparison each
/// one leans on reports a value that moved and stays quiet about one that did not. A phase that
/// went green while a command had no scenario, or while the comparison named nothing whatever
/// Logic did, would say nothing about Logic at all.
@Test func phaseFourAgainstLogic() throws {
  #expect(
    PhaseFour.flow.map(\.contract) == [
      "CMD-S4.1", "CMD-S4.2", "CMD-S4.3", "CMD-S4.4", "CMD-S4.5", "CMD-S4.6", "CMD-S4.7",
      "CMD-S4.8", "RUN-8",
    ],
    "the run answers every contract of phase 4: \(PhaseFour.flow.map(\.contract))")
  #expect(
    PhaseFour.flow.map(\.command) == [
      "midi notes", "midi quantize", "midi velocity", "automation add", "automation list",
      "automation set", "plugins list", "plugins insert", "midi velocity",
    ],
    "in the order one edit needs the last: \(PhaseFour.flow.map(\.command))")
  #expect(
    PhaseFour.flow.allSatisfy { !$0.keeps.isEmpty },
    "and each one says what it leaves alone, which is what the run reads back")

  let source = try PhaseFour.sourceOfTheLiveScenarios()
  let declared = PhaseFour.scenariosDeclared(in: source)
  #expect(
    declared == PhaseFour.flow.map(\.scenario),
    "every edit has a scenario that drives it, and no other scenario is in the phase: \(declared)")
  for edit in PhaseFour.flow {
    #expect(
      source.contains("LiveHarness.liveScenario(\"\(edit.scenario)\")"),
      "\(edit.command) announces itself, so an acceptance run counts it as one that ran")
  }
  #expect(
    source.contains("@Suite(.serialized, .enabled(if: LiveHarness.runsLive()))"),
    "the scenarios are off unless a person turns the live suite on, one at a time when it is on")
  #expect(
    source.contains("LiveHarness.copyOfTheScratchProject(into: folder)")
      && source.contains("LiveHarness.temporaryFolder()"),
    "and they work on a copy, in a folder of the run, never on the project of a person")

  let object = try JSONSerialization.jsonObject(with: Data(PhaseFour.notesFileText.utf8))
  let file = object as? [String: Any]
  #expect(
    (file?["notes"] as? [[String: Any]])?.count == PhaseFour.knownNotes.count,
    "the run writes its own file, so the region is known before Logic answers for it")
  #expect(
    PhaseFour.knownNotes.allSatisfy { $0.start.truncatingRemainder(dividingBy: 0.25) != 0 },
    "and the notes of that file start off the grid, so quantize has something to move")

  let before = [
    PhaseFour.Note(
      note: 1, position: "58 1 1 75", pitch: 60, velocity: 40, length: "0 0 1 1", channel: 1),
    PhaseFour.Note(
      note: 2, position: "58 1 4 139", pitch: 62, velocity: 70, length: "0 0 1 1", channel: 1),
  ]
  var quieter = before
  quieter[1].velocity = PhaseFour.velocityGiven
  var quantized = before
  quantized[0].position = "58 1 1 1"
  #expect(
    PhaseFour.notesThatChanged(from: before, to: before).isEmpty,
    "a region nothing touched reads as a region nothing touched")
  #expect(
    PhaseFour.notesThatChanged(from: before, to: quieter) == ["note 2 velocity 70 to 90"],
    "a velocity that moved is named, with the note it belongs to")
  #expect(
    PhaseFour.notesThatChanged(from: before, to: quantized).isEmpty,
    "and a position that moved is not, because that is the change quantize is for")
  #expect(
    PhaseFour.notesThatChanged(from: before, to: Array(before.dropLast())).isEmpty == false,
    "a note that went missing is a change, whatever the notes that are left say")

  let points = [
    PhaseFour.Point(point: 1, position: "58 1 1 1", parameter: "Volume", value: 90),
    PhaseFour.Point(point: 2, position: "60 1 1 1", parameter: "Volume", value: 90),
  ]
  var lowered = points
  lowered[0].value = PhaseFour.valueGiven
  #expect(
    PhaseFour.pointsThatChanged(from: points, to: points).isEmpty,
    "the same points read as the same points")
  #expect(
    PhaseFour.pointsThatChanged(from: points, to: lowered) == ["point 1 value 90 to 60"],
    "and the one value that moved is named, with the point it belongs to")

  #expect(PhaseFour.onTheGrid("58 1 1 1"), "a note on a sixteenth reads with a tick of 1")
  #expect(
    PhaseFour.onTheGrid("58 1 1 75") == false, "and a note between two sixteenths does not")
  #expect(PhaseFour.onTheGrid("58 1 1") == false, "a position Logic did not write is no grid")
  #expect(
    PhaseFour.inTimeOrder(["9 1 1 1", "10 1 1 1"]),
    "bar 10 comes after bar 9, which it does not as words")
  #expect(PhaseFour.inTimeOrder(["10 1 1 1", "9 1 1 1"]) == false, "and never the other way")

  let strip = [
    PhaseFour.Plugin(slot: 1, name: "Piano"), PhaseFour.Plugin(slot: 2, name: "Channel EQ"),
  ]
  #expect(PhaseFour.firstEmptySlot(after: strip) == 3, "a plugin lands after the ones there")
  #expect(PhaseFour.firstEmptySlot(after: []) == 1, "and in slot 1 on a strip with nothing on it")

  var ticks = 0
  var reads = 0
  let clock: Wait.Clock = { ticks }
  let sleeper: Wait.Sleeper = { ticks += $0 }
  try PhaseFour.byHand(
    "select note 1 and note 2", limitMs: 10_000, pollMs: 1_000, clock: clock, sleeper: sleeper,
    until: {
      reads += 1
      return reads == 3
    })
  #expect(reads == 3, "the run reads again while the Mac is not ready yet")

  var waited = 0
  var said = "it waited for nothing"
  let stuckClock: Wait.Clock = { waited }
  let stuckSleeper: Wait.Sleeper = { waited += $0 }
  do {
    try PhaseFour.byHand(
      "select note 1 and note 2 in the Event List", limitMs: 10_000, pollMs: 1_000,
      clock: stuckClock, sleeper: stuckSleeper, until: { false })
  } catch {
    said = String(describing: error)
  }
  #expect(said.contains("note 1"), "a wait that ran out says what it asked for: \(said)")
  #expect(said.contains("note 2"), "both rows, so a person reads which two: \(said)")
  #expect(said.contains("10000ms"), "and how long it waited before it gave up: \(said)")
}
