import Foundation
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
/// 12.3.1. A recorded tree says nothing about whether Logic still answers a Machine Control
/// message, still shows the tempo field where it was, or still makes a track for an imported file.
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
  /// Every other scenario of the phase reaches Logic over this port. A Mac with the driver off
  /// takes nothing, and the transport scenarios would then report a Logic that never moved.
  @Test func setupFindsTheBusOnThisMac() throws {
    LiveHarness.liveScenario("setupFindsTheBusOnThisMac")

    let found = try answered(BusAnswer.self, from: ["midi", "setup"])
    #expect(found.bus == LiveNames.bus, "the bus of phase 3 is named logicctl: \(found.bus)")
    #expect(found.seenByLogic, "the port is not offline, so what this phase sends reaches Logic")
  }

  /// Logic starts playing when logicctl sends the Machine Control play message (story S3.2).
  @Test func playStartsTheTransport() throws {
    LiveHarness.liveScenario("playStartsTheTransport")
    _ = try ScratchCopy.open()

    let moving = try answered(TransportAnswer.self, from: ["transport", "play"])
    #expect(moving.playing, "Logic reads back as playing after the play message")

    let still = try answered(TransportAnswer.self, from: ["transport", "stop"])
    #expect(still.playing == false, "and the scenario leaves the transport still for the next one")
  }

  /// Logic stops when logicctl sends the Machine Control stop message (story S3.2).
  ///
  /// It plays first, because a transport that was never moving reads as stopped whatever the stop
  /// message did.
  @Test func stopStopsTheTransport() throws {
    LiveHarness.liveScenario("playStartsTheTransport")
    _ = try ScratchCopy.open()

    let moving = try answered(TransportAnswer.self, from: ["transport", "play"])
    #expect(moving.playing, "the transport is moving, so the stop has something to stop")

    let still = try answered(TransportAnswer.self, from: ["transport", "stop"])
    #expect(still.playing == false, "Logic reads back as stopped after the stop message")
  }

  /// The notes logicctl sends while Logic records land in a region of the track (stories S3.2,
  /// S3.3).
  ///
  /// This is the one scenario where the bus, the transport and the project meet. A note reaches
  /// the port, Logic takes it as a performance, and what it wrote is read back out of the Event
  /// List. Logic records onto the selected software instrument track, so the scratch copy holds
  /// track 3 selected and the Event List open before the run.
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

    let recording = try answered(TransportAnswer.self, from: ["transport", "record"])
    #expect(recording.recording, "Logic reads back as recording after the record message")

    _ = try answered(
      SentAnswer.self,
      from: ["midi", "note", "--pitch", "60", "--velocity", "100", "--length", "500ms"])
    _ = try answered(
      SentAnswer.self,
      from: ["midi", "chord", "--pitches", "64,67,72", "--velocity", "100", "--length", "500ms"])

    let still = try answered(TransportAnswer.self, from: ["transport", "stop"])
    #expect(still.recording == false, "the take is closed, so Logic wrote what it heard")

    let after = try regionsOnTrack(LiveNames.recordedTrack)
    #expect(
      after == before + 1,
      """
      Logic wrote no region on track \(LiveNames.recordedTrack): it held \(before) before the \
      take and \(after) after it. The track reads arm \(instrument.arm), and Logic records only \
      onto a track that is armed and selected.
      """)
    guard after == before + 1 else {
      return
    }

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
  @Test func importPutsTheFileOnANewTrack() throws {
    LiveHarness.liveScenario("importPutsTheFileOnANewTrack")
    _ = try ScratchCopy.open()

    let command = ["midi", "import", "--file", fixture("notes.mid").path, "--confirm"]
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
