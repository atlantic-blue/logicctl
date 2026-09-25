import Foundation
import LogicctlCore
import LogicctlMac
import Testing

@testable import logicctl

/// The version of Logic the tree was recorded from.
private let recordedVersion = "12.3.1"

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// The title Logic gives the window that shows the tracks of this project.
private let theProjectWindow = "F-T13.logicx - Tracks"

/// The title Logic gives the first window of the recording, which is the Event List.
private let theFirstWindow = "F-T13.logicx - MIDI Region - Event List"

/// The tempo a running Logic answers. The pipeline has no running Logic, so a test gives it.
private let aTempo = 120

/// The whole application of Logic, with four windows open, as `inspect` recorded it.
private func theRecordedApplication() throws -> LogicTree {
  let file = fixtureFolder.appending(path: "mixer-and-event-list-in-front.json")
  let read = try RecordedTree(contentsOf: file)
  return LogicTree(logicVersion: read.logicVersion, root: read.root)
}

/// The same application with one of its windows closed.
private func theRecordedApplication(without window: String) throws -> LogicTree {
  let whole = try theRecordedApplication()
  let kept = whole.root.children.filter { ($0.title ?? "") != window }
  return LogicTree(logicVersion: whole.logicVersion, root: ApplicationOfLogic(windows: kept))
}

/// An application element that holds the windows a test gives it.
///
/// A recorded element is read from a file and nothing can take a child off it, so this stands for
/// the application while a person has one window closed.
private struct ApplicationOfLogic: AXNode {
  let windows: [any AXNode]

  let role = "AXApplication"
  let title: String? = "Logic Pro"
  let identifier: String? = nil
  let value: String? = nil
  let valueDescription: String? = nil
  let description: String? = nil
  let help: String? = nil
  let actions: [String] = []

  var children: [any AXNode] { windows }
}

/// A folder no command has written in.
private func aTemporaryFolder() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "logicctl-window-\(UUID().uuidString)")
}

/// The driver over one tree, with every read a running Logic answers given to it.
///
/// The project sits nowhere, which is a project that was never saved, so there is no session to
/// write a step into and nothing of a run touches the disk.
private func driver(over tree: LogicTree) -> AXDriver {
  let state = StateReader(
    tree: { tree },
    status: AXDriver(tree: { tree }, applicationInFront: { nil }).status,
    name: { ProjectReader.name(inTitle: tree.atTheProjectWindow()?.root.title ?? "") },
    path: { nil },
    tempo: { aTempo })
  return AXDriver(
    tree: { tree },
    applicationInFront: { nil },
    state: state.state(after:),
    path: { nil },
    processID: { 4242 },
    dialog: { _ in nil })
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

  /// The rows the answer carries under one key of `data`.
  func rows(_ key: String) throws -> [[String: Any]] {
    let data = try printed()["data"] as? [String: Any] ?? [:]
    return data[key] as? [[String: Any]] ?? []
  }

  /// The code the answer failed with, or nothing when it did not fail.
  func code() throws -> String? {
    let failure = try printed()["error"] as? [String: Any] ?? [:]
    return failure["code"] as? String
  }

  /// One field of the details the failure carries.
  func detail(_ key: String) throws -> String? {
    let failure = try printed()["error"] as? [String: Any] ?? [:]
    let details = failure["details"] as? [String: Any] ?? [:]
    return details[key] as? String
  }
}

/// Runs `logicctl tracks list` against a Logic that shows this tree.
private func tracksList(over tree: LogicTree) -> Answer {
  var out = ""
  let status = Tracks.List.answer(
    driver: NewProject.liveDriver(driver(over: tree)),
    root: aTemporaryFolder(),
    standardOutput: { out += $0 },
    standardError: { _ in })
  return Answer(out: out, status: status)
}

/// Runs `logicctl plugins list --track <n>` against a Logic that shows this tree.
private func pluginsList(over tree: LogicTree, track: String) throws -> Answer {
  var out = ""
  let typed = try Logicctl.parseAsRoot(["plugins", "list", "--track", track])
  let list = try #require(typed as? Plugins.List)
  let status = list.answer(
    driver: NewProject.liveDriver(driver(over: tree)),
    of: { tree },
    root: aTemporaryFolder(),
    standardOutput: { out += $0 },
    standardError: { _ in })
  return Answer(out: out, status: status)
}

/// A person reads their project while the Mixer and the Event List are open.
///
/// Logic keeps several windows open at once, and the window a person raised is not the first
/// window of the list. The Event List of this recording stays first while the Mixer is in front.
/// A read that takes the first window reads the Event List, which carries no Control Bar and no
/// track header, so every command fails with `element_not_found` on `transport.playButton`.
///
/// That made two commands impossible and one command awkward. `midi notes` and `automation list`
/// need the Event List open, so a person who opens it can no longer read anything. `plugins list`
/// needs the Mixer open, so it worked only while the Tracks window was raised.
///
/// The read now finds the window that holds the tracks of the project, wherever it sits in the
/// list. A Logic that shows no such window answers nothing, and the command says so with the name
/// of the locator it reached for.
@Test func everyReadFindsTheProjectWindow() throws {
  let logic = try theRecordedApplication()

  let first = try #require(logic.atTheFrontWindow())
  #expect(first.root.title == theFirstWindow, "the first window of the list is the Event List")

  let project = try #require(
    logic.atTheProjectWindow(), "the application shows a window with the tracks in it")
  #expect(project.root.title == theProjectWindow, "the window the tracks of the project sit in")
  #expect(
    try driver(over: logic).status().window == theProjectWindow,
    "status names the project window and not the window in front")

  let listed = tracksList(over: logic)
  let tracks = try listed.rows("tracks")

  #expect(listed.status == 0, "a read of the tracks is not a failure while the Mixer is open")
  #expect(tracks.count == 5, "one row per track of the recorded project")
  #expect(
    tracks.map { $0["name"] as? String } == [
      "Deluxe Classic", "Deluxe Classic", "Studio Grand", "Studio Grand", "Studio Grand",
    ],
    "the tracks of the recorded project, in the order Logic shows them")
  #expect(tracks.map { $0["index"] as? Int } == [1, 2, 3, 4, 5], "counted from 1")

  let read = try pluginsList(over: logic, track: "1")

  #expect(read.status == 0, "the Mixer is open, so the strip of the track is there to read")
  #expect(
    try read.rows("plugins").map { $0["name"] as? String } == ["E-Piano", "Channel EQ"],
    "the chain of track 1, in slot order")

  let closed = try theRecordedApplication(without: theProjectWindow)
  let refused = tracksList(over: closed)

  #expect(closed.atTheProjectWindow() == nil, "no window of this Logic holds a track header")
  #expect(try refused.code() == "element_not_found", "the code a read with no project window ends")
  #expect(try refused.detail("locator") == "window.main", "the locator the read asked for")
  #expect(refused.status == 5, "the number that code exits with")
}
