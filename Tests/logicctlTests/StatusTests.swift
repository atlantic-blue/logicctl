import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// The project the empty tree of Logic 12.3.1 was recorded from, as Logic wrote it into the title
/// of its window.
private let recordedWindow = "F-T0.logicx - Tracks"

/// The version of Logic every recorded tree came from.
private let recordedVersion = "12.3.1"

/// Where the recorded trees sit. They are read from the source tree, because the folder sits beside
/// the test targets rather than inside one.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// What one run wrote, on each channel.
private final class Answer {
  var out = ""
  var err = ""

  func write(_ text: String) {
    out += text
  }

  func writeError(_ text: String) {
    err += text
  }

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// The `data` of the answer, or an empty object when it carries none.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }
}

/// The Logic that a driver reads, on a Mac where Logic is not running.
private func aMacWithNoLogic() -> AXDriver {
  AXDriver(tree: { nil }, applicationInFront: { nil })
}

/// The Logic that a driver reads from a tree that was recorded from Logic 12.3.1, with Logic in
/// front.
private func theRecordedLogic(_ tree: LogicTree) -> AXDriver {
  AXDriver(tree: { tree }, applicationInFront: { LogicTree.bundleIdentifier })
}

/// A person or an agent asks logicctl what Logic is doing, and Logic is not running.
///
/// The answer is a state and not a failure. `running` is false, there is nothing else to say, and
/// the command exits 0. That number is the whole point: a script reads the one field and launches
/// Logic, where an exit code of 4 would stop it on a condition that is not a fault. So there is no
/// failure in the envelope, standard error stays empty, and the three fields that need a Logic to
/// answer are null rather than absent, because a caller reads the same four keys every time.
///
/// The same command over the tree that was recorded from Logic 12.3.1 answers the other way: Logic
/// runs, Logic is in front, the window is the one Logic shows, and the version is the one it
/// reports. A fake Logic with nothing open answers exactly as the driver on a Mac with no Logic
/// does, because a stand in that answered anything else there would pass a test that a real Mac
/// fails.
@Test func statusReportsLogicNotRunningAsAState() throws {
  let typed = try Logicctl.parseAsRoot(["status"])
  #expect(typed is Status)

  let quiet = Answer()
  let exited = Status.answer(
    of: aMacWithNoLogic(),
    standardOutput: quiet.write,
    standardError: quiet.writeError)

  #expect(exited == 0)
  #expect(quiet.err.isEmpty)
  #expect(quiet.out.hasSuffix("}\n"))
  #expect(quiet.out.filter(\.isNewline).count == 1)

  let read = try quiet.printed()
  #expect(read["error"] is NSNull)
  let state = try quiet.data()
  #expect(state["running"] as? Bool == false)
  #expect(state["frontmost"] as? Bool == false)
  #expect(state["window"] is NSNull)
  #expect(state["version"] is NSNull)
  #expect(state.keys.sorted() == ["frontmost", "running", "version", "window"])

  let meta = read["meta"] as? [String: Any]
  #expect(meta?["version"] as? String == Logicctl.version)
  #expect(meta?["session"] is NSNull)
  #expect(meta?["step"] is NSNull)
  #expect(meta?["durationMs"] as? Int != nil)

  let standIn = Answer()
  let alsoExited = Status.answer(
    of: FakeLogicDriver(),
    standardOutput: standIn.write,
    standardError: standIn.writeError)
  #expect(alsoExited == 0)
  let alsoState = try standIn.data()
  #expect(alsoState["running"] as? Bool == false)
  #expect(alsoState["frontmost"] as? Bool == false)
  #expect(alsoState["window"] is NSNull)
  #expect(alsoState["version"] is NSNull)
  #expect(alsoState.keys.sorted() == state.keys.sorted())

  let file = fixtureFolder.appending(path: "empty.json")
  try #require(
    FileManager.default.fileExists(atPath: file.path),
    "the empty project of Logic 12.3.1 was not recorded, so this run proves nothing")
  let recorded = try RecordedTree(contentsOf: file)
  let tree = LogicTree(logicVersion: recorded.logicVersion, root: recorded.root)

  let open = Answer()
  let ran = Status.answer(
    of: theRecordedLogic(tree),
    standardOutput: open.write,
    standardError: open.writeError)

  #expect(ran == 0)
  #expect(open.err.isEmpty)
  let shown = try open.data()
  #expect(shown["running"] as? Bool == true)
  #expect(shown["frontmost"] as? Bool == true)
  #expect(shown["window"] as? String == recordedWindow)
  #expect(shown["version"] as? String == recordedVersion)
}
