import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

/// The tempo the display of a running Logic answers. The pipeline has no running Logic, so a test
/// gives it.
private let aTempo = 96

/// One tree of one window, as `inspect` recorded it from Logic 12.3.1.
private func recorded(_ file: String) throws -> LogicTree {
  let read = try RecordedTree(contentsOf: fixtureFolder.appending(path: file))
  return LogicTree(logicVersion: read.logicVersion, root: read.root)
}

/// A folder no command has written in.
private func aTemporaryFolder() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "logicctl-driver-\(UUID().uuidString)")
}

/// The path of the project the recorded tree shows, under a folder that holds no file.
///
/// The conformance case reads the name of the project out of this path, and the state reader reads
/// the time of the last save from the folder, so a path that holds no file gives a project that was
/// never saved.
private func aProjectPath(under folder: URL) -> String {
  folder.appending(path: "F-T3b.logicx").path
}

/// The driver over one recorded tree.
///
/// Every read a running Logic answers is given here, as `StateReader` and `ProjectReader` and
/// `DialogReader` are each given their reads, so the pipeline drives the same driver the Mac drives
/// and only the reads behind it differ.
private func driver(
  over tree: LogicTree,
  at path: String? = nil,
  runningAs processID: Int32 = 4242,
  waitingOn dialog: @escaping AXDriver.DialogRead = { _ in nil },
  startingFrom recordedState: @escaping AXDriver.RecordedStateRead = { _ in nil }
) -> AXDriver {
  let state = StateReader(
    tree: { tree },
    status: AXDriver(tree: { tree }, applicationInFront: { nil }).status,
    name: { ProjectReader.name(inTitle: tree.atTheFrontWindow()?.root.title ?? "") },
    path: { path },
    tempo: { aTempo })
  return AXDriver(
    tree: { tree },
    applicationInFront: { nil },
    state: state.state(after:),
    path: { path },
    processID: { processID },
    dialog: dialog,
    recordedState: recordedState)
}

/// The project the recorded tree holds, as the recording shows it: three tracks, every button off,
/// and one region on the third track from a MIDI import.
///
/// It is written out here rather than read back through the reader the driver reads through. A test
/// that reads twice and compares the two answers proves only that the reader is steady.
private func theRecordedProject() -> State {
  State(
    logic: LogicVersion(version: Locators.recordedFrom),
    project: Project(name: "F-T3b"),
    transport: Transport(tempo: Double(aTempo)),
    tracks: [
      Track(index: 1, name: "Deluxe Classic", type: .other),
      Track(index: 2, name: "Deluxe Classic", type: .other),
      Track(
        index: 3, name: "Studio Grand", type: .other,
        regions: [Region(index: 1, name: "MIDI Region", start: "1 bar", end: "2 bars")]),
    ])
}

/// The same project with one plugin on every track, which is what a session records once a person
/// opened the Mixer.
private func theSameProjectWithPlugins() -> State {
  var state = theRecordedProject()
  state.tracks[0].plugins = [Plugin(slot: 1, name: "Sculpture")]
  state.tracks[1].plugins = [Plugin(slot: 1, name: "Compressor")]
  state.tracks[2].plugins = [Plugin(slot: 1, name: "Space Designer")]
  return state
}

/// A session of the project at one path, with the state it recorded last, written as a real
/// repository under one root.
private func aSession(ofProjectAt path: String, holding state: State, root: URL) throws {
  let session = Session(
    project: Session.Project(name: "F-T3b", path: path),
    versions: Session.Versions(logicctl: "0.1.0", logic: Locators.recordedFrom, macos: "15.0.0"))
  _ = try SessionRepository.start(session: session, root: root, state: state)
}

/// What one run of a command wrote, on each channel, and the number it exited with.
private struct Answer {
  let out: String
  let status: Int32

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// The rows the answer carries under `data.tracks`.
  func rows() throws -> [[String: Any]] {
    let data = try printed()["data"] as? [String: Any] ?? [:]
    return data["tracks"] as? [[String: Any]] ?? []
  }

  /// The code the answer failed with, or nothing when it did not fail.
  func code() throws -> String? {
    let failure = try printed()["error"] as? [String: Any] ?? [:]
    return failure["code"] as? String
  }
}

/// Runs `logicctl tracks list` through one driver.
///
/// The driver of this run answers no path, which is a project that was never saved, so there is no
/// session to write a step into and nothing of the run touches the disk.
private func tracksList(through driver: any LogicDriver) -> Answer {
  var out = ""
  let status = Tracks.List.answer(
    driver: driver,
    root: aTemporaryFolder(),
    standardOutput: { out += $0 },
    standardError: { _ in })
  return Answer(out: out, status: status)
}

/// A person types a command and reads what the Logic in front of them holds.
///
/// Every command reaches Logic through one driver and through nothing else. Until this step that
/// driver refused every read, so `tracks list` on a Mac with Logic open answered a failure with no
/// code of its own and no track in it. Now the driver over Accessibility answers, and the answer is
/// the project: three tracks of the recorded project, in the order Logic shows them.
///
/// The suite is the same suite the double answers, so the two cannot drift: a double that answered
/// what the real driver refuses would turn every test of every command into a false pass. And a
/// read that refuses reaches the person as the code of that refusal, `element_not_found` and exit
/// 5, because a person who gets `internal` has nothing to act on.
@Test func everyCommandGetsTheRealDriver() throws {
  let project = theRecordedProject()
  let tracksWindow = try recorded("region.json")
  let path = aProjectPath(under: aTemporaryFolder())
  let live = driver(over: tracksWindow, at: path)
  let read = try live.readState()

  #expect(read == project, "the project the recorded tree holds, read through the live driver")

  for one in Conformance.cases {
    try one.run(against: live, holding: project)
    try one.run(against: FakeLogicDriver(state: project, path: path), holding: project)
  }

  let waiting = driver(
    over: try recorded("tempo-question.json"),
    at: path,
    waitingOn: { root in DialogReader(modal: { _ in true }).dialog(in: root) })
  let asked = try #require(try waiting.modalDialog())

  #expect(asked.buttons == ["No", "Import Tempo", "Cancel"], "the answers Logic offers")
  try Conformance.namesTheDialogLogicWaitsOn.run(against: waiting, holding: project)

  let listed = tracksList(through: NewProject.liveDriver(driver(over: tracksWindow)))
  let rows = try listed.rows()

  #expect(listed.status == 0, "a read of the tracks is not a failure")
  #expect(rows.count == 3, "one row per track of the recorded project")
  #expect(
    rows.map { $0["name"] as? String } == ["Deluxe Classic", "Deluxe Classic", "Studio Grand"],
    "the tracks of the recorded project, in the order Logic shows them")
  #expect(rows.map { $0["index"] as? Int } == [1, 2, 3], "counted from 1")

  let refusing = AXDriver(
    tree: { tracksWindow },
    applicationInFront: { nil },
    state: { _ in throw StateReader.Refusal(reason: "Logic shows no window.") },
    path: { nil },
    processID: { 4242 },
    dialog: { _ in nil })
  let refused = tracksList(through: NewProject.liveDriver(refusing))

  #expect(try refused.code() == "element_not_found", "the code the reader refused with")
  #expect(refused.status == 5, "the number that code exits with")
}

/// A person keeps the Mixer closed, and the plugins of their project stay where they are.
///
/// The plugins of a track are read from the Mixer, and Logic shows the Mixer only while a person
/// keeps it open. So a walk that sees no strip keeps the plugins the read before it held, and the
/// first read of a command has no read before it: it takes them from the state the session of that
/// project recorded. A driver that started from nothing would answer a project with no plugin on
/// any track, and the comparison with `state.json` would report every plugin of every track as one
/// that a person removed by hand.
@Test func theDriverStartsFromTheStateTheSessionRecorded() throws {
  let root = aTemporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }

  let recordedState = theSameProjectWithPlugins()
  let path = aProjectPath(under: aTemporaryFolder())
  try aSession(ofProjectAt: path, holding: recordedState, root: root)

  let live = driver(
    over: try recorded("region.json"),
    at: path,
    startingFrom: { at in NewProject.stateRecorded(ofProjectAt: at, root: root) })
  let first = try live.readState()
  let second = try live.readState()

  #expect(
    first.tracks.map(\.plugins) == recordedState.tracks.map(\.plugins),
    "the plugins the session recorded, on a tree that shows no Mixer")
  #expect(
    second.tracks.map(\.plugins) == recordedState.tracks.map(\.plugins),
    "and the second read of the command keeps them, from the read before it")
  #expect(first.tracks.map(\.name) == second.tracks.map(\.name), "the tracks are read every time")

  let unknown = driver(
    over: try recorded("region.json"),
    at: aProjectPath(under: aTemporaryFolder()),
    startingFrom: { at in NewProject.stateRecorded(ofProjectAt: at, root: root) })
  let alone = try unknown.readState()

  #expect(
    alone.tracks.allSatisfy { $0.plugins.isEmpty },
    "a project that no session carries has no plugin to carry over")
}
