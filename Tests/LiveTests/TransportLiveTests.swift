import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LogicctlCore
import LogicctlMac
import Testing

/// This file, read as text.
///
/// The acceptance of a phase is a run on a Mac with Logic on it, and the pipeline has neither. So
/// the pipeline reads the file the acceptance is written in, the way the phase 0 step reads the
/// Makefile, and it answers the one question it can answer from here.
private let liveFile = URL(fileURLWithPath: #filePath)

/// The line the suite of phase 3 is declared on, as it is written.
///
/// The text carries a real line break, and this file writes that break as an escape, so this
/// constant cannot match the line it sits on. The check reads only the text after this
/// declaration, which is why every other pattern it looks for is safe to write out whole.
private let suiteDeclaration =
  "@Suite(.serialized, .enabled(if: LiveHarness.runsLive()))\n" + "struct Phase3LiveScenarios {"

/// One live scenario of phase 3: the name it carries, and the command it drives.
private struct PhaseThreeScenario {
  /// The name of the scenario. It prints this name itself, and `make accept` counts the line.
  let name: String

  /// The words of the command the scenario gives logicctl.
  let command: [String]
}

/// The live scenarios of phase 3, in the order a person walks the phase.
///
/// The order is the order of the stories: find the bus, move the transport, record into it, set
/// the tempo, write a file and import it.
private let phaseThreeScenarios: [PhaseThreeScenario] = [
  PhaseThreeScenario(name: "setupFindsTheBusOnThisMac", command: ["midi", "setup"]),
  PhaseThreeScenario(name: "playStartsTheTransport", command: ["transport", "play"]),
  PhaseThreeScenario(name: "stopStopsTheTransport", command: ["transport", "stop"]),
  PhaseThreeScenario(name: "recordTakesTheNotesIntoARegion", command: ["transport", "record"]),
  PhaseThreeScenario(name: "tempoSetsTheTempoOfTheProject", command: ["transport", "tempo"]),
  PhaseThreeScenario(name: "writeFileGivesTheStoredBytes", command: ["midi", "write-file"]),
  PhaseThreeScenario(name: "importPutsTheFileOnANewTrack", command: ["midi", "import"]),
]

/// Phase 3 is accepted when every command of it moved the real Logic on this Mac.
///
/// The pipeline proves each of these commands against a tree that `inspect` recorded from Logic
/// 12.3.1. A recorded tree says nothing about whether Logic still moves when its Control Bar
/// button is pressed, still takes a note on the bus, still shows the tempo field where it was, or
/// still makes a track for an imported file.
/// `make accept PART=3` is where the running application answers, and the output of that run, with
/// the picture of the tempo field, is what proves this step.
///
/// That run needs a Mac and this check has none. What it can do is refuse an acceptance that would
/// report a pass while a command of the phase drove nothing: a phase 3 with a command missing, a
/// scenario that prints the name of another scenario so the count reads high, a suite that runs in
/// the pipeline where there is no Logic, or a run that works on the project of a person rather
/// than on a copy.
@Test func phaseThreeAgainstLogic() throws {
  let source = try String(contentsOf: liveFile, encoding: .utf8)

  guard let declared = source.range(of: suiteDeclaration) else {
    Issue.record(
      """
      make accept PART=3 filters on Phase3LiveScenarios, and this file declares no such suite, \
      or declares it without .serialized and .enabled(if: LiveHarness.runsLive()). A suite that \
      is not off by default runs in the pipeline, where there is no Logic to drive.
      """)
    return
  }
  let suite = source[declared.lowerBound...]

  #expect(
    suite.contains("LiveHarness.copyOfTheScratchProject"),
    "phase 3 works on a copy in a temporary folder, never on the project of a person")

  var readSoFar = suite.startIndex
  for scenario in phaseThreeScenarios {
    let declaration = "@Test func \(scenario.name)("
    guard let starts = suite.range(of: declaration, range: readSoFar..<suite.endIndex) else {
      Issue.record(
        """
        phase 3 drives \(scenario.command.joined(separator: " ")), and no scenario named \
        \(scenario.name) comes after the one before it in the flow. An acceptance with this \
        command missing reports a pass for a command that never ran.
        """)
      continue
    }
    readSoFar = starts.upperBound

    let body = suite[starts.upperBound..<endOfScenario(in: suite, after: starts.upperBound)]
    #expect(
      body.contains("LiveHarness.liveScenario(\"\(scenario.name)\")"),
      """
      \(scenario.name) prints no line of its own, or prints the name of another scenario. \
      make accept counts those lines, so a scenario that never ran would be counted as one \
      that did.
      """)
    for word in scenario.command {
      #expect(
        body.contains("\"\(word)\""),
        "\(scenario.name) never gives logicctl \(scenario.command.joined(separator: " "))")
    }
  }
}

/// Where the scenario that starts at this point ends, which is where the next one starts.
private func endOfScenario(in suite: Substring, after point: Substring.Index) -> Substring.Index {
  suite.range(of: "@Test func ", range: point..<suite.endIndex)?.lowerBound ?? suite.endIndex
}

/// Phase 3 of the stories, against the Logic that runs on this Mac.
///
/// The bus, the transport, the notes, the tempo and the import all answer here, on a copy of the
/// scratch project and never on the work of a person. Every scenario leaves the transport still,
/// so each one stands on its own whatever order the runner picks.
///
/// They run one at a time, because all of them drive the one Logic this Mac has, and they share
/// the one copy of the project it has open.
@Suite(.serialized, .enabled(if: LiveHarness.runsLive()))
struct Phase3LiveScenarios {
  /// The bus phase 3 sends on is on this Mac, and Logic is listening to it (story S3.1).
  ///
  /// The notes of the phase reach Logic over this port. A Mac with the driver off takes nothing,
  /// and the take would then hold none of the keys this phase played into it.
  @Test func setupFindsTheBusOnThisMac() throws {
    LiveHarness.liveScenario("setupFindsTheBusOnThisMac")

    let found = try answered(BusAnswer.self, from: ["midi", "setup"])
    #expect(found.bus == LiveNames.bus, "the bus of phase 3 is named logicctl: \(found.bus)")
    #expect(found.seenByLogic, "the port is not offline, so what this phase sends reaches Logic")
  }

  /// Logic starts playing when logicctl presses the Play button of the Control Bar (story S3.2).
  @Test func playStartsTheTransport() throws {
    LiveHarness.liveScenario("playStartsTheTransport")
    _ = try ScratchCopy.open()

    let moving = try answered(TransportAnswer.self, from: ["transport", "play"])
    #expect(moving.playing, "Logic reads back as playing after the press of Play")

    let still = try answered(TransportAnswer.self, from: ["transport", "stop"])
    #expect(still.playing == false, "and the scenario leaves the transport still for the next one")
  }

  /// Logic stops when logicctl presses the Stop button of the Control Bar (story S3.2).
  ///
  /// It plays first, because a transport that was never moving reads as stopped whatever the press
  /// of Stop did.
  @Test func stopStopsTheTransport() throws {
    LiveHarness.liveScenario("stopStopsTheTransport")
    _ = try ScratchCopy.open()

    let moving = try answered(TransportAnswer.self, from: ["transport", "play"])
    #expect(moving.playing, "the transport is moving, so the stop has something to stop")

    let still = try answered(TransportAnswer.self, from: ["transport", "stop"])
    #expect(still.playing == false, "Logic reads back as stopped after the press of Stop")
  }

  /// The notes logicctl sends while Logic records land in a region of the track (stories S3.2,
  /// S3.3).
  ///
  /// This is the one scenario where the bus, the transport and the project meet. A note reaches
  /// the port, Logic takes it as a performance, and what it wrote is read back out of the Event
  /// List. The Event List of the take is open before the run, because logicctl does not open it.
  /// A take writes into the project, and the project belongs to a person, so the record goes
  /// through `--confirm`.
  ///
  /// Logic records onto the selected track, and a copy opens with whatever track was selected when
  /// it was saved. Measured on this Mac on 2026-09-27 against Logic 12.3.1: a copy of the scratch
  /// project opened with track 2 selected, a take then wrote nothing onto track 3, and the arm of
  /// every track read false while Logic was recording. So the arm says nothing about whether a
  /// take lands, and the selected track is what decides. The scenario selects the track itself.
  @Test func recordTakesTheNotesIntoARegion() throws {
    LiveHarness.liveScenario("recordTakesTheNotesIntoARegion")
    _ = try ScratchCopy.open()

    let listed = try answered(TracksAnswer.self, from: ["tracks", "list"])
    let wanted = listed.tracks.first(where: { $0.index == LiveNames.recordedTrack })
    guard let instrument = wanted else {
      throw LiveRefusal(
        reason: """
          the scratch copy has no track \(LiveNames.recordedTrack), and phase 3 records on the \
          software instrument that sits there
          """)
    }
    #expect(
      instrument.type == "software-instrument",
      "a performance on the bus records onto a software instrument: \(instrument.type)")
    #expect(
      instrument.name == LiveNames.recordedTrackName,
      "track \(LiveNames.recordedTrack) of the scratch copy is \(instrument.name)")

    let before = try regionsOnTrack(LiveNames.recordedTrack)

    // The count above reads the state, and a state read opens the Mixer and closes it again, so the
    // selection is proven after it and not before, as close to the take as the scenario can get.
    try select(trackNumbered: LiveNames.recordedTrack, of: listed.tracks.count)

    let recording = try answered(TransportAnswer.self, from: ["transport", "record", "--confirm"])
    #expect(recording.recording, "Logic reads back as recording after the press of Record")

    _ = try answered(
      SentAnswer.self,
      from: ["midi", "note", "--pitch", "60", "--velocity", "100", "--length", "500ms"])
    _ = try answered(
      SentAnswer.self,
      from: ["midi", "chord", "--pitches", "64,67,72", "--velocity", "100", "--length", "500ms"])

    let still = try answered(TransportAnswer.self, from: ["transport", "stop"])
    #expect(still.recording == false, "the take is closed, so Logic wrote what it heard")

    let after = try regionsOnTrack(LiveNames.recordedTrack)
    let selected = selectedTrackNow(of: listed.tracks.count)
    #expect(
      after == before + 1,
      """
      Logic wrote no region on track \(LiveNames.recordedTrack): it held \(before) before the \
      take and \(after) after it. The selected track reads \(selected), and Logic records onto \
      the selected track.
      """)
    guard after == before + 1 else {
      return
    }

    try showTheEventList(ofTrack: LiveNames.recordedTrack, region: after)
    let read = try answered(
      NotesAnswer.self,
      from: [
        "midi", "notes", "--track", String(LiveNames.recordedTrack), "--region", String(after),
      ])
    let heard = Set(read.notes.map(\.pitch))
    #expect(
      heard.isSuperset(of: LiveNames.sentPitches),
      """
      the region holds \(heard.sorted()), and this scenario played \
      \(LiveNames.sentPitches.sorted()) into it
      """)
  }

  /// Logic takes the tempo logicctl types into the tempo field, and shows it back (story S3.2).
  ///
  /// The project belongs to a person, so the change goes through `--confirm`. The step keeps the
  /// picture of the window the tempo field sits in, and the line this prints says where that
  /// picture went, or why this Mac took none.
  @Test func tempoSetsTheTempoOfTheProject() throws {
    LiveHarness.liveScenario("tempoSetsTheTempoOfTheProject")
    _ = try ScratchCopy.open()

    let command = ["transport", "tempo", String(LiveNames.tempo), "--confirm"]
    let (read, status) = try envelope(TempoAnswer.self, from: command)
    #expect(status == 0, "the tempo went in: \(read.error?.code ?? "no failure")")
    #expect(
      read.data?.tempo == Double(LiveNames.tempo),
      "Logic shows \(LiveNames.tempo) in the tempo field: \(read.data?.tempo ?? -1)")
    print("tempo field picture: \(pictureNote(of: read.meta))")
  }

  /// The same notes give the same bytes, from the binary this Mac signed (story S3.4).
  ///
  /// This command reads no Logic. It is in the phase because the file it writes is the file the
  /// import scenario gives Logic, so a run where the bytes moved would import something else.
  @Test func writeFileGivesTheStoredBytes() throws {
    LiveHarness.liveScenario("writeFileGivesTheStoredBytes")

    let folder = try LiveHarness.temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let written = folder.appending(path: "notes.mid")

    let made = try answered(
      WrittenAnswer.self,
      from: [
        "midi", "write-file", "--in", fixture("notes.json").path, "--out", written.path,
      ])
    #expect(made.notes == 8, "the fixture carries eight notes: \(made.notes)")

    let stored = try Data(contentsOf: fixture("notes.mid"))
    let fresh = try Data(contentsOf: written)
    #expect(
      fresh == stored,
      """
      the file this Mac wrote is the file the repository holds: \(fresh.count) bytes \
      against \(stored.count)
      """)
  }

  /// Logic makes a track for an imported file, and logicctl reads back what it made (story S3.5).
  ///
  /// Logic asks about the tempo when the file disagrees with the project, and the answer to that
  /// question is stored in the preferences of this Mac, so the question may never show. Both ways
  /// are read: a question that shows fails the command with `dialog_open` and logicctl presses
  /// nothing, and a question that does not show leaves the track and the region to read.
  ///
  /// The file is copied to a folder Logic can walk to first, and the folder goes again at the end.
  @Test func importPutsTheFileOnANewTrack() throws {
    LiveHarness.liveScenario("importPutsTheFileOnANewTrack")
    _ = try ScratchCopy.open()

    let folder = try visibleFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "notes.mid")
    try FileManager.default.copyItem(at: fixture("notes.mid"), to: file)

    let command = ["midi", "import", "--file", file.path, "--confirm"]
    let (read, status) = try envelope(ImportAnswer.self, from: command)

    if let refused = read.error {
      let said = refused.text ?? refused.message
      print("tempo question: shown, and logicctl pressed nothing: \(said)")
      #expect(
        refused.code == "dialog_open",
        "a question from Logic stops the import and names itself: \(refused.code)")
      #expect(status == 16, "dialog_open exits 16: \(status)")
      #expect(
        refused.buttons?.isEmpty == false,
        "the failure carries the buttons, so a person answers it in Logic without looking")
      return
    }

    print("tempo question: none showed, so the preferences of this Mac hold the answer")
    guard let made = read.data else {
      throw LiveRefusal(reason: "the import neither answered nor failed: \(status)")
    }
    #expect(made.track.index > 0, "Logic made a track for the file: \(made.track.index)")
    #expect(
      made.track.type == "software-instrument",
      "and a MIDI file lands on a software instrument: \(made.track.type)")
    #expect(made.region.startBar != nil, "the region Logic made starts at a bar it reads back")
    #expect(made.sha256.count == 64, "the step holds the file by its hash: \(made.sha256)")
    print("tempo field picture: \(pictureNote(of: read.meta))")
  }
}

/// What the scenarios of phase 3 name, in one place.
private enum LiveNames {
  /// The port Logic and logicctl meet on.
  static let bus = "logicctl"

  /// The track of the scratch copy the take is recorded onto.
  static let recordedTrack = 3

  /// What Logic calls that track.
  static let recordedTrackName = "Studio Grand"

  /// The keys this phase plays into the take.
  static let sentPitches: Set<Int> = [60, 64, 67, 72]

  /// The tempo this phase types into the tempo field.
  static let tempo = 96

  /// The key code of the down arrow, which moves the selection to the next track down.
  ///
  /// Measured on this Mac on 2026-09-27 against Logic 12.3.1: with the Tracks window holding the
  /// focus, one of these moved the selection from track 2 to track 3.
  static let downArrow: CGKeyCode = 125

  /// The key code of the up arrow, which moves the selection to the track above.
  static let upArrow: CGKeyCode = 126

  /// How long Logic is given to move the selection after one arrow key, in milliseconds.
  static let selectionLimitMs = 5000

  /// How long Logic is given to come to the front and hold the focus, in milliseconds.
  static let focusLimitMs = 10000

  /// How long the scenario leaves between two reads of Logic, in milliseconds.
  static let pollMs = 200

  /// The item of the Window menu that opens the Event List in a window of its own.
  ///
  /// It is the walk to Open Mixer with the last step changed, so the two items are reached through
  /// one path, and a change to the walk moves both. Measured on this Mac on 2026-09-27 against
  /// Logic 12.3.1: the item is titled `Open Event List` and the window it opens is titled
  /// `<project> - MIDI Region - Event List`, which is what `EventList.window` looks for.
  static let openEventList = Locator(
    name: "menu.window.openEventList",
    path: Array(Locators.openMixer.path.dropLast())
      + [LocatorStep(role: "AXMenuItem", title: "Open Event List")])

  /// A region number past any region a scratch project holds.
  ///
  /// `midi notes` refuses a region that is not there and says how many the track has, so one
  /// refusal answers the count. No command prints the regions of a track.
  static let pastEveryRegion = 9999
}

/// The one copy of the scratch project this run works on, open in Logic.
///
/// Logic reads the project window of the front project, so a run that opened a copy for each
/// scenario would leave several projects open and the reads would not say which one they read. The
/// copy is made once, and every scenario of the phase works in it.
///
/// It is left where it is when the run ends, in the temporary folder of this Mac, so a person can
/// open what the acceptance did and look at it.
private enum ScratchCopy {
  /// The copy, or why this run has none.
  static let made: Result<URL, LiveRefusal> = {
    do {
      let folder = try LiveHarness.temporaryFolder()
      let copy = try LiveHarness.copyOfTheScratchProject(into: folder)
      try LiveHarness.openInLogic(copy)
      print("live copy: \(copy.path)")
      return .success(copy)
    } catch {
      return .failure(LiveRefusal(reason: String(describing: error)))
    }
  }()

  /// The copy Logic has open.
  static func open() throws -> URL {
    try made.get()
  }
}

/// What stopped a live scenario before it could assert anything.
private struct LiveRefusal: Error, CustomStringConvertible {
  /// What a person reads, and what they do about it.
  let reason: String

  var description: String { reason }
}

/// A folder of this run that Logic can walk to, every step of the way down.
///
/// The Import panel of macOS lists visible folders alone, so `midi import` refuses a file whose
/// path passes through a hidden folder before it asks Logic anything. `/tmp` resolves under
/// `/private`, and the temporary folder of a process sits under `/private/var`, so a file in
/// either one is refused. A folder in the home folder is visible the whole way, and the scenario
/// that makes one removes it again.
private func visibleFolder() throws -> URL {
  let home = FileManager.default.homeDirectoryForCurrentUser
  let folder = home.appending(path: "logicctl-live-import-\(UUID().uuidString)")
  guard LiveHarness.isUnder(LiveHarness.musicFolder, folder) == false else {
    throw LiveRefusal(
      reason: "\(folder.path) is under the music folder of this Mac, so nothing is written there")
  }
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder
}

/// A fixture of the repository, by its name under `Tests/Fixtures`.
private func fixture(_ name: String) -> URL {
  liveFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Fixtures")
    .appending(path: name)
}

/// Where the picture of the window went, or why this Mac took none.
///
/// A failed capture does not fail the command, so `meta.details.screenshot` carries the reason and
/// the step holds no picture. This Mac has no Screen Recording grant yet, so the line is the one
/// place a person reads which of the two happened.
private func pictureNote(of meta: MetaRead) -> String {
  if let said = meta.details?.screenshot {
    return said
  }
  return "the step \(meta.step ?? "of this command") holds it"
}

/// How many regions one track carries.
///
/// `midi notes` refuses a region that is not there with `region_not_found`, and that failure says
/// how many regions the track has, so one refusal answers the count.
private func regionsOnTrack(_ track: Int) throws -> Int {
  let command = [
    "midi", "notes", "--track", String(track), "--region", String(LiveNames.pastEveryRegion),
  ]
  let (read, _) = try envelope(NotesAnswer.self, from: command)
  guard let refused = read.error, refused.code == "region_not_found" else {
    throw LiveRefusal(
      reason: """
        counting the regions of track \(track) asked for region \(LiveNames.pastEveryRegion) and \
        did not get region_not_found back
        """)
  }
  guard let counted = refused.regions else {
    throw LiveRefusal(reason: "region_not_found carried no count of the regions of track \(track)")
  }
  return counted
}

/// Runs the signed logicctl and reads the whole envelope, `meta` and all.
///
/// `LiveHarness.read` throws on a failure, which is what most reads want. A scenario that reads a
/// failure on purpose, and every scenario that prints where the picture went, needs the envelope
/// as it was printed.
private func envelope<Answered: Decodable>(
  _ shape: Answered.Type,
  from arguments: [String]
) throws -> (read: FullEnvelope<Answered>, status: Int32) {
  let ran = try LiveHarness.logicctl(arguments)
  let command = arguments.joined(separator: " ")
  guard let bytes = ran.printed.data(using: .utf8) else {
    throw LiveRefusal(reason: "logicctl \(command) printed nothing: \(ran.complained)")
  }
  do {
    return (try JSONDecoder().decode(FullEnvelope<Answered>.self, from: bytes), ran.status)
  } catch {
    throw LiveRefusal(
      reason: "logicctl \(command) printed no envelope this suite reads back: \(ran.printed)")
  }
}

/// What one command answered, or a refusal naming why it did not.
private func answered<Answered: Decodable>(
  _ shape: Answered.Type,
  from arguments: [String]
) throws -> Answered {
  let (read, _) = try envelope(shape, from: arguments)
  guard let carried = read.data else {
    throw LiveRefusal(
      reason: """
        logicctl \(arguments.joined(separator: " ")) failed with \
        \(read.error?.code ?? "no code"): \(read.error?.message ?? "")
        """)
  }
  return carried
}

/// The envelope of one answer, as this file reads it.
private struct FullEnvelope<Answered: Decodable>: Decodable {
  /// What the command answered, or nothing when it failed.
  let data: Answered?

  /// Why the command failed, or nothing when it did not.
  let error: FailureRead?

  /// What the command says about itself.
  let meta: MetaRead
}

/// The failure an envelope carries, with the fields phase 3 reads out of `details`.
private struct FailureRead: Decodable {
  /// The code of the design system, for example `dialog_open`.
  let code: String

  /// The line a person reads.
  let message: String

  private let details: FailureDetails?

  /// What a dialog of Logic says, when the failure is a dialog.
  var text: String? { details?.text }

  /// The buttons that dialog offers.
  var buttons: [String]? { details?.buttons }

  /// How many regions the track has, when the failure is a region that is not there.
  var regions: Int? { details?.regions }
}

/// The fields of `error.details` phase 3 reads.
private struct FailureDetails: Decodable {
  let text: String?
  let buttons: [String]?
  let regions: Int?
}

/// The `meta` of an answer, with the fields phase 3 reads.
private struct MetaRead: Decodable {
  /// The commit of the step this command wrote, or nothing.
  let step: String?

  /// What else the answer has to say about itself, or nothing.
  let details: MetaDetails?
}

/// The fields of `meta.details` phase 3 reads.
private struct MetaDetails: Decodable {
  /// Why no picture of the window was taken, or nothing when one was.
  let screenshot: String?
}

/// What `midi setup` answers.
private struct BusAnswer: Decodable {
  let bus: String
  let seenByLogic: Bool
}

/// What `transport play`, `stop` and `record` answer.
private struct TransportAnswer: Decodable {
  let playing: Bool
  let recording: Bool
}

/// What `transport tempo` answers.
private struct TempoAnswer: Decodable {
  let tempo: Double
}

/// What `midi note` and `midi chord` answer.
private struct SentAnswer: Decodable {
  let sent: Int
}

/// What `tracks list` answers.
private struct TracksAnswer: Decodable {
  let tracks: [TrackRow]
}

/// One row of `tracks list`.
private struct TrackRow: Decodable {
  let index: Int
  let name: String
  let type: String
  let arm: Bool
}

/// What `midi notes` answers.
private struct NotesAnswer: Decodable {
  let notes: [NoteRow]
}

/// One row of `midi notes`.
private struct NoteRow: Decodable {
  let pitch: Int
  let velocity: Int
}

/// What `midi write-file` answers.
private struct WrittenAnswer: Decodable {
  let path: String
  let notes: Int
  let sha256: String
}

/// What `midi import` answers.
private struct ImportAnswer: Decodable {
  let track: ImportedTrack
  let region: ImportedRegion
  let sha256: String
}

/// The track Logic made for the imported file.
private struct ImportedTrack: Decodable {
  let index: Int
  let name: String
  let type: String
}

/// The region Logic made on that track.
private struct ImportedRegion: Decodable {
  let startBar: Int?
  let endBar: Int?
}

/// Makes one track the selected track of the Tracks window, and proves it before it goes on.
///
/// Logic records onto the selected track, and a copy opens with whatever track was selected when it
/// was saved. Nothing in logicctl selects a track, and a write of `AXSelected` on the header of a
/// track changes nothing, so the selection moves the way a person moves it: the arrow keys of the
/// Tracks window, one key at a time.
///
/// A key is an event at the window server and not an argument, so a key that lands anywhere else
/// changes something nobody asked for and no later read can tell. Every key here is proven twice
/// over: the gate sends nothing unless Logic is frontmost and no window of Logic is modal, and this
/// reads the focused window of Logic and refuses unless it is the window the project sits in. The
/// selection is read back after every key, so a key that moved nothing stops the scenario rather
/// than turning into a second key.
private func select(trackNumbered wanted: Int, of tracks: Int) throws {
  let logic = try theRunningLogic()
  try bringTheTracksWindowToTheFront(logic)

  guard var selected = try selectedTrack(of: tracks) else {
    throw LiveRefusal(
      reason: """
        no track of the Tracks window reads AXSelected true, so there is nowhere for an arrow key \
        to move from and this scenario sends none
        """)
  }

  let gate = InputGate.live(logic: logic.processIdentifier)
  var keys = 0
  while selected != wanted && keys < tracks {
    let key = selected < wanted ? LiveNames.downArrow : LiveNames.upArrow
    try proveTheTracksWindowHasTheFocus(logic)
    try gate.post(.key(key, flags: [], focus: nil))
    keys += 1

    let was = selected
    do {
      try Wait.until(limitMs: LiveNames.selectionLimitMs, pollMs: LiveNames.pollMs) {
        try selectedTrack(of: tracks) != was
      }
    } catch {
      throw LiveRefusal(
        reason: """
          one arrow key reached Logic and the selected track still reads \(was), so the keys of \
          this scenario are moving nothing and it sends no more of them
          """)
    }
    guard let moved = try selectedTrack(of: tracks) else {
      throw LiveRefusal(
        reason: "an arrow key left no track of the Tracks window reading AXSelected true")
    }
    selected = moved
  }

  guard selected == wanted else {
    throw LiveRefusal(
      reason: """
        the selected track of the Tracks window reads \(selected) and the take needs track \
        \(wanted), after \(keys) arrow keys
        """)
  }
}

/// The track the Tracks window reads as selected, counted from 1, or nothing when none does.
///
/// It reads `AXSelected` of the header of each track, which is the one place Logic says which track
/// a take lands on. The walk to a header is the walk the state reader makes, so this reads the
/// tracks logicctl reads and not a list of its own.
private func selectedTrack(of tracks: Int) throws -> Int? {
  let window = try theTracksWindow()
  for number in 0..<tracks {
    let locator = Locators.trackHeader(number: number)
    let item = try LocatorResolver.element(of: locator, in: window.root)
    if try readsSelected(item, named: "track \(number + 1)") {
      return number + 1
    }
  }
  return nil
}

/// The selected track as one word, for a failure that has to say what it was.
private func selectedTrackNow(of tracks: Int) -> String {
  do {
    guard let read = try selectedTrack(of: tracks) else {
      return "no track"
    }
    return String(read)
  } catch {
    return "a track nothing could read: \(error)"
  }
}

/// Whether one track header reads `AXSelected` true.
///
/// A header Accessibility refuses to answer for is not read as false: false is what an unselected
/// track answers, and a read nobody could make would then look like one. The type of the value is
/// read before the value, because a number bridges to `Bool` as well and a `1` that is not a
/// boolean would then read as a selected track.
private func readsSelected(_ item: any AXNode, named what: String) throws -> Bool {
  guard let live = item as? LiveAXNode else {
    throw LiveRefusal(reason: "\(what) came from a recorded tree, which selects nothing")
  }
  var carried: CFTypeRef?
  let answered = AXUIElementCopyAttributeValue(
    live.element, kAXSelectedAttribute as CFString, &carried)
  guard answered == .success, let value = carried,
    CFGetTypeID(value) == CFBooleanGetTypeID()
  else {
    throw LiveRefusal(
      reason: """
        AXSelected of \(what) answered error \(answered.rawValue), so this scenario cannot tell \
        what Logic has selected
        """)
  }
  return value as? Bool == true
}

/// The tree of Logic starting at the window the project sits in.
private func theTracksWindow() throws -> LogicTree {
  guard let window = try LogicTree.ofRunningLogic().atTheProjectWindow() else {
    throw LiveRefusal(reason: "Logic shows no window with the header of the tracks in it")
  }
  return window
}

/// The Logic that runs on this Mac.
private func theRunningLogic() throws -> NSRunningApplication {
  let running = NSRunningApplication.runningApplications(
    withBundleIdentifier: LogicTree.bundleIdentifier)
  guard let logic = running.first else {
    throw LiveRefusal(reason: "no Logic runs on this Mac, so there is no track to select")
  }
  return logic
}

/// Brings Logic to the front and raises the window the project sits in.
///
/// `make accept` runs from a terminal, so the terminal is the frontmost application and the gate
/// would refuse every key. Logic is asked to come forward, and the project window is raised. Logic
/// keeps the Mixer and the Event List open beside it, and an arrow key belongs to whichever of them
/// holds the focus.
private func bringTheTracksWindowToTheFront(_ logic: NSRunningApplication) throws {
  logic.activate()
  do {
    try Wait.until(limitMs: LiveNames.focusLimitMs, pollMs: LiveNames.pollMs) {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == logic.processIdentifier
    }
  } catch {
    throw LiveRefusal(reason: "Logic did not come to the front, so no key would reach it")
  }

  guard let window = try theTracksWindow().root as? LiveAXNode else {
    throw LiveRefusal(reason: "the project window came from a recorded tree, which nothing raises")
  }
  let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
  guard raised == .success else {
    throw LiveRefusal(
      reason: "Logic refused to raise the window of the project, error \(raised.rawValue)")
  }
  try proveTheTracksWindowHasTheFocus(logic)
}

/// Stops unless Logic holds the focus on the window the project sits in.
///
/// A Logic that answers nothing for its focused window is read as a Logic holding the focus
/// somewhere else, because a focus nothing can read is not a focus a key can land in.
private func proveTheTracksWindowHasTheFocus(_ logic: NSRunningApplication) throws {
  do {
    try Wait.until(limitMs: LiveNames.focusLimitMs, pollMs: LiveNames.pollMs) {
      try theTracksWindowHoldsTheFocus(of: logic)
    }
  } catch {
    throw LiveRefusal(
      reason: """
        the window of the project does not hold the focus of Logic, so an arrow key would move \
        something else and this scenario sends none
        """)
  }
}

/// Whether the window the project sits in is the window of Logic that takes keys.
private func theTracksWindowHoldsTheFocus(of logic: NSRunningApplication) throws -> Bool {
  guard let wanted = try theTracksWindow().root as? LiveAXNode else {
    return false
  }
  let application = AXUIElementCreateApplication(logic.processIdentifier)
  var carried: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &carried)
      == .success,
    let focused = carried, CFGetTypeID(focused) == AXUIElementGetTypeID()
  else {
    return false
  }
  return CFEqual(focused, wanted.element)
}

/// Selects one region of one track and leaves the Event List showing it.
///
/// `midi notes` reads the notes out of the window Logic shows them in, and it does not open that
/// window. Measured on this Mac on 2026-09-27 against Logic 12.3.1: a copy opens with no Event List
/// at all, and the Event List shows whichever region is selected, so a take that is not selected
/// reads as the notes of whatever region is. Both halves are this scenario's to arrange, so it
/// selects the take and then opens the window.
///
/// The selection is a write of `AXSelected` on the item of the region, which Logic takes, unlike
/// the same write on the header of a track. It is read back, because a write Logic ignored and a
/// write Logic took answer the same.
private func showTheEventList(ofTrack track: Int, region: Int) throws {
  let item = try regionItem(onTrack: track, numbered: region)
  guard let live = item as? LiveAXNode else {
    throw LiveRefusal(
      reason: "region \(region) of track \(track) came from a recorded tree, which selects nothing")
  }
  let written = AXUIElementSetAttributeValue(
    live.element, kAXSelectedAttribute as CFString, true as CFTypeRef)
  guard written == .success else {
    throw LiveRefusal(
      reason: """
        Logic refused the write of AXSelected on region \(region) of track \(track), error \
        \(written.rawValue)
        """)
  }
  guard try readsSelected(item, named: "region \(region) of track \(track)") else {
    throw LiveRefusal(
      reason: """
        the write of AXSelected on region \(region) of track \(track) went through and the region \
        still reads false, so the Event List would show another region
        """)
  }

  try openTheEventList()
}

/// Opens the Event List of Logic, and waits until one window of Logic is showing it.
///
/// The item is pressed through a walk of the menu bar that starts again for every read, which is
/// what the press of Open Mixer does. A press through Accessibility asks the element to act on
/// itself, so it is not an event at the window server and it does not go through the input gate.
///
/// A window that is already showing an Event List is left as it is. The Event List follows the
/// selection, so the one that is open is already showing the region this run just selected, and a
/// second press would only put another window on the screen.
private func openTheEventList() throws {
  let open = try LogicTree.ofRunningLogic()
  if EventList.window(of: open) != nil {
    return
  }

  try AutomationMenus.pressTheItem(
    LiveNames.openEventList,
    of: { try LogicTree.ofRunningLogic().root },
    offered: { try readsEnabled($0, named: "the item Window, Open Event List") },
    act: { try press($0, named: "the item Window, Open Event List") })

  do {
    try Wait.until(limitMs: LiveNames.focusLimitMs, pollMs: LiveNames.pollMs) {
      let tree = try LogicTree.ofRunningLogic()
      return EventList.window(of: tree) != nil
    }
  } catch {
    throw LiveRefusal(
      reason: """
        the item Window, Open Event List was pressed and no window of Logic is showing an Event \
        List, so the notes of the take cannot be read
        """)
  }
}

/// The item of one region of one track, in the Tracks window.
///
/// It is the walk the region reader makes, so the numbers here are the numbers `--region` takes:
/// Logic puts one layout area under the contents group for every track, in the order of the rows
/// from the top, and one more after them for the room under the last track.
private func regionItem(onTrack track: Int, numbered region: Int) throws -> any AXNode {
  let window = try theTracksWindow()
  guard let contents = theContentsGroup(under: window.root) else {
    throw LiveRefusal(
      reason: "the Tracks window holds no group described \(RegionReader.contentsGroup)")
  }
  let areas = contents.children.filter { $0.role == RegionReader.trackRole }
  guard track >= 1, track <= areas.count - 1 else {
    throw LiveRefusal(
      reason: "the contents group holds \(areas.count) areas, and track \(track) is not among them")
  }
  let items = areas[track - 1].children.filter { $0.role == RegionReader.regionRole }
  guard region >= 1, region <= items.count else {
    throw LiveRefusal(
      reason: """
        track \(track) shows \(items.count) regions, and region \(region) is not one of them
        """)
  }
  return items[region - 1]
}

/// The group that holds one area per track, wherever it sits under the window.
private func theContentsGroup(under node: any AXNode) -> (any AXNode)? {
  if node.description == RegionReader.contentsGroup {
    return node
  }
  for child in node.children {
    if let found = theContentsGroup(under: child) {
      return found
    }
  }
  return nil
}

/// Whether one element reads `AXEnabled` true.
///
/// An element whose state Accessibility refuses is read as one Logic does not offer. A press of an
/// item whose state nothing could read is a press nobody can account for.
private func readsEnabled(_ item: any AXNode, named what: String) throws -> Bool {
  guard let live = item as? LiveAXNode else {
    throw LiveRefusal(reason: "\(what) came from a recorded tree, which offers nothing")
  }
  var carried: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(live.element, kAXEnabledAttribute as CFString, &carried)
      == .success,
    let value = carried, CFGetTypeID(value) == CFBooleanGetTypeID()
  else {
    return false
  }
  return value as? Bool == true
}

/// Asks one element to act on itself.
private func press(_ item: any AXNode, named what: String) throws {
  guard let live = item as? LiveAXNode else {
    throw LiveRefusal(reason: "\(what) came from a recorded tree, which presses nothing")
  }
  let pressed = AXUIElementPerformAction(live.element, kAXPressAction as CFString)
  guard pressed == .success else {
    throw LiveRefusal(reason: "Logic refused the press of \(what), error \(pressed.rawValue)")
  }
}
