import Foundation
import LogicctlCore
import LogicctlMac
import Testing

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

/// The tempo a test hands the reader. The display of the running Logic answers it on this Mac,
/// and the pipeline has no running Logic.
private let aTempo = 96

/// One tree of one window, as `inspect` recorded it from Logic 12.3.1.
private func recorded(_ file: String) throws -> LogicTree {
  let read = try RecordedTree(contentsOf: fixtureFolder.appending(path: file))
  return LogicTree(logicVersion: read.logicVersion, root: read.root)
}

/// The tree a running Logic answers: one application that carries every window it shows.
///
/// A recorded tree starts at one window, because `inspect --window main` writes the front window
/// as the root. A walk that reads the tracks and the Mixer at once needs both windows, so the
/// windows of two recordings hang here under one application, in the order Logic answers them.
private func application(showing windows: [any AXNode]) -> LogicTree {
  LogicTree(
    logicVersion: Locators.recordedFrom,
    root: Element(role: "AXApplication", children: windows))
}

/// One element a test builds, where no recording carries the one it needs.
private struct Element: AXNode {
  var role: String
  var title: String? = nil
  var identifier: String? = nil
  var value: String? = nil
  var valueDescription: String? = nil
  var description: String? = nil
  var help: String? = nil
  var actions: [String] = []
  var children: [any AXNode] = []
}

/// A reader over one tree, with every read a running Logic answers given as a test gives it.
///
/// The version comes from `AXDriver.status`, which reads it from the tree, so a recorded tree
/// answers the version it was recorded from. The name comes from the title of the front window,
/// which is the read `ProjectReader` makes on this Mac.
private func reader(over tree: LogicTree, path: String? = nil) -> StateReader {
  StateReader(
    tree: { tree },
    status: AXDriver(tree: { tree }, applicationInFront: { nil }).status,
    name: { ProjectReader.name(inTitle: tree.atTheFrontWindow()?.root.title ?? "") },
    path: { path },
    tempo: { aTempo })
}

/// A project folder that holds the file Logic writes when a person saves, and its time.
private func aSavedProject() throws -> (folder: URL, savedAt: Date) {
  let folder = FileManager.default.temporaryDirectory
    .appending(path: "logicctl-state-\(UUID().uuidString).logicx")
  let file = folder.appending(path: StateReader.projectData)
  try FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("a project".utf8).write(to: file)
  let read = try FileManager.default.attributesOfItem(atPath: file.path)
  return (folder, try #require(read[.modificationDate] as? Date))
}

/// The state of the last step: the three tracks of the recorded project, each with a plugin that
/// no strip of the recorded Mixer carries.
private func aStateWithAPluginOnEveryTrack() -> State {
  State(
    logic: LogicVersion(version: Locators.recordedFrom),
    project: Project(name: "F-T3b"),
    transport: Transport(tempo: Double(aTempo)),
    tracks: [
      Track(index: 1, name: "Deluxe Classic", type: .other, plugins: [aPlugin("Sculpture")]),
      Track(index: 2, name: "Deluxe Classic", type: .other, plugins: [aPlugin("Compressor")]),
      Track(index: 3, name: "Studio Grand", type: .other, plugins: [aPlugin("Space Designer")]),
    ])
}

/// One plugin in the first slot of a strip.
private func aPlugin(_ name: String) -> Plugin {
  Plugin(slot: 1, name: name)
}

/// The plugins one track carries in a state.
private func plugins(ofTrack number: Int, in state: State) throws -> [Plugin] {
  try #require(state.tracks.first { $0.index == number }).plugins
}

/// A person reads what Logic holds, and every command reads it twice: once before it acts and
/// once after. The journal keeps both, so this read is the whole record of the project at each
/// step, and it is what tells a person that Logic changed under them.
///
/// A region that the read drops, and a plugin list that it empties because nobody opened the
/// Mixer, both become a history that Logic never held. Nothing later can find that error, because
/// the state is the only record of the moment it was read.
///
/// The recorded project carries three tracks and one region, imported from a MIDI file onto the
/// third track. The recorded Mixer carries the strip of one track, with two plugins on it. Logic
/// shows the Mixer only while a person keeps it open, and it shows the strips that person scrolled
/// to, so the last three reads are the ones where a strip is missing or belongs to another track.
/// The plugins of the last state stand there, and every other field is read from the tree as
/// before.
@Test func stateReaderReadsTheTracksOfTheRecordedProject() throws {
  let saved = try aSavedProject()
  defer { try? FileManager.default.removeItem(at: saved.folder) }

  let tracksWindow = try recorded("region.json")
  let state = try reader(over: tracksWindow, path: saved.folder.path).state(after: nil)

  #expect(state.logic.version == "12.3.1", "the version the tree was recorded from")
  #expect(state.project.name == "F-T3b", "the name in the title of the window")
  #expect(state.project.savedAt == saved.savedAt, "the time Logic last wrote ProjectData")
  #expect(state.transport.playing == false, "the Play button of that window reads 0")
  #expect(state.transport.recording == false, "the Record button of that window reads 0")
  #expect(state.transport.tempo == Double(aTempo), "the tempo the display answered")
  #expect(
    state.tracks.map(\.name) == ["Deluxe Classic", "Deluxe Classic", "Studio Grand"],
    "the three tracks, in the order Logic shows them")
  #expect(state.tracks.map(\.index) == [1, 2, 3], "counted from 1")

  let third = try #require(state.tracks.first { $0.index == 3 })
  let region = try #require(third.regions.first)

  #expect(third.regions.count == 1, "the import put one region on the third track")
  #expect(region.index == 1, "counted from 1, in order from the left")
  #expect(region.name == "MIDI Region", "the text of the region item")
  #expect(region.start == "1 bar", "where the help text of the region says it starts")
  #expect(region.end == "2 bars", "and where it says it ends")
  #expect(try plugins(ofTrack: 1, in: state).isEmpty, "no Mixer, and no state before this one")
  #expect(
    state.tracks.filter { $0.index != 3 }.allSatisfy { $0.regions.isEmpty },
    "the other two tracks carry nothing")

  let mixerWindow = try recorded("mixer.json")
  let shown = application(showing: [try recorded("one-track.json").root, mixerWindow.root])
  let open = try reader(over: shown).state(after: nil)
  let strip = try #require(open.tracks.first)

  #expect(open.tracks.map(\.name) == ["Deluxe Classic"], "the one track of that project")
  #expect(strip.plugins.map(\.name) == ["E-Piano", "Channel EQ"], "the slots of its strip")
  #expect(strip.plugins.map(\.slot) == [1, 2], "counted from 1, the instrument first")

  let before = aStateWithAPluginOnEveryTrack()
  let again = try reader(over: tracksWindow).state(after: before)

  #expect(
    again.tracks.map(\.plugins) == before.tracks.map(\.plugins),
    "the Tracks window shows no strip, so every plugin list is the one the last state held")
  #expect(again.tracks.map(\.name) == before.tracks.map(\.name), "and the tracks are still read")

  let scrolled = try reader(over: application(showing: [tracksWindow.root, mixerWindow.root]))
    .state(after: before)

  #expect(
    try plugins(ofTrack: 1, in: scrolled) == strip.plugins,
    "the strip in the first place carries the name of the first track, so it is read")
  #expect(
    try plugins(ofTrack: 2, in: scrolled) == plugins(ofTrack: 2, in: before),
    "the strip in the second place is the output of the Mixer, so the last state stands")
  #expect(
    try plugins(ofTrack: 3, in: scrolled) == plugins(ofTrack: 3, in: before),
    "and the third place is the master strip")

  let emptyMixer = Element(role: "AXWindow", title: "F-T3b.logicx - Mixer: Tracks")
  let scrolledAway = try reader(over: application(showing: [tracksWindow.root, emptyMixer]))
    .state(after: before)

  #expect(
    scrolledAway.tracks.map(\.plugins) == before.tracks.map(\.plugins),
    "a Mixer that shows no strip of these tracks leaves every plugin list as it was")
}

/// What a person gets when the read cannot answer a state at all.
///
/// A Mac where Logic is not running refuses, as every other read about a project refuses, because
/// there is no project to answer about. A Logic that shows no window, and a window that names no
/// project, refuse for the same reason: a state built there would name a project nobody has open.
@Test func stateReaderRefusesWhatItCannotRead() throws {
  let tree = try recorded("region.json")

  let noLogic = StateReader(
    tree: { throw DriverRefusal.logicNotRunning },
    status: { LogicStatus.notRunning },
    name: { "F-T3b" },
    path: { nil },
    tempo: { aTempo })
  let noVersion = StateReader(
    tree: { tree },
    status: { LogicStatus.notRunning },
    name: { "F-T3b" },
    path: { nil },
    tempo: { aTempo })

  #expect(throws: DriverRefusal.logicNotRunning) { try noLogic.state(after: nil) }
  #expect(throws: DriverRefusal.logicNotRunning) { try noVersion.state(after: nil) }

  let windowless = #expect(throws: StateReader.Refusal.self) {
    try reader(over: application(showing: [])).state(after: nil)
  }
  let noWindow = try #require(windowless)

  #expect(noWindow.failure.code == .elementNotFound, "the code a caller reads")
  #expect(noWindow.failure.code.exitCode == 5, "the number the process exits with")

  let unnamed = #expect(throws: StateReader.Refusal.self) {
    try reader(over: application(showing: [Element(role: "AXWindow", title: "Logic Pro")]))
      .state(after: nil)
  }
  let noProject = try #require(unnamed)

  #expect(noProject.failure.code == .elementNotFound, "the code a caller reads")
}
