import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import Testing

@testable import logicctl

/// A tree of Logic of four levels, as `inspect` writes one against a real project.
///
/// The elements are the ones later steps look for: the window of the project, the header of the
/// tracks, and a plugin slot, which Accessibility names in its description and nowhere else.
private let aTreeOfFourLevels = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXApplication",
      "title": "Logic Pro",
      "actions": [],
      "children": [
        {
          "role": "AXWindow",
          "title": "Sketch",
          "identifier": "_NS:main",
          "description": "window",
          "help": "The window of the project",
          "actions": ["AXRaise"],
          "children": [
            {
              "role": "AXGroup",
              "title": "Tracks",
              "children": [
                {
                  "role": "AXLayoutItem",
                  "description": "audio plug-in",
                  "value": "Channel EQ",
                  "actions": ["AXPress", "AXShowMenu"]
                }
              ]
            }
          ]
        },
        {
          "role": "AXMenuBar",
          "children": [{ "role": "AXMenuBarItem", "title": "Track" }]
        }
      ]
    }
  }
  """

/// The same tree, cut to the element it starts at and the elements one level under it.
private let theSameTreeAtDepthTwo = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXApplication",
      "title": "Logic Pro",
      "children": [
        {
          "role": "AXWindow",
          "title": "Sketch",
          "identifier": "_NS:main",
          "description": "window",
          "help": "The window of the project",
          "actions": ["AXRaise"]
        },
        { "role": "AXMenuBar" }
      ]
    }
  }
  """

/// A tree read from the text a file carries.
private func tree(from text: String) throws -> RecordedTree {
  try JSONDecoder().decode(RecordedTree.self, from: Data(text.utf8))
}

/// The tree of Logic that a test hands the command, in place of the Logic it cannot run.
private func source(_ recorded: RecordedTree) -> () throws -> LogicTree {
  { LogicTree(logicVersion: recorded.logicVersion, root: recorded.root) }
}

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-inspect-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

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

  /// What the command answered with.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }

  /// The code of the failure the answer carries, or nil when it carries none.
  func failureCode() throws -> String? {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["code"] as? String
  }
}

/// The tree of Logic is read on the Mac that has Logic, and every later step is proved in a
/// pipeline that has none. The file this command writes is the only route between the two, so a
/// file that does not read back leaves the fixtures of step 5 unusable and the paths of step 6
/// with nothing to resolve against.
///
/// So the tree that goes in comes back: the file reads back as the same elements, with the same
/// roles, titles, identifiers, values, actions and children, cut where `--depth` said to cut. It
/// keeps the description of an element too, because a plugin slot of Logic is named there and
/// nowhere else.
@Test func inspectWritesATreeThatReadsBack() throws {
  let folder = try temporaryFolder()
  let file = folder.appendingPathComponent("tree.json")
  let logic = try tree(from: aTreeOfFourLevels)
  let answer = Answer()

  let typed = try Logicctl.parseAsRoot(["inspect", "--depth", "2", "--out", file.path])
  let inspect = try #require(typed as? Inspect)

  let status = inspect.answer(
    of: source(logic),
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 0)
  #expect(answer.err.isEmpty)
  #expect(answer.out.hasSuffix("}\n"))
  #expect(answer.out.filter(\.isNewline).count == 1)

  let readBack = try RecordedTree(contentsOf: file)
  #expect(readBack == (try tree(from: theSameTreeAtDepthTwo)))
  #expect(readBack.logicVersion == "12.3.1")
  #expect(readBack.root.recordedChildren.map(\.role) == ["AXWindow", "AXMenuBar"])
  #expect(readBack.root.recordedChildren.first?.description == "window")
  #expect(readBack.root.recordedChildren.allSatisfy { $0.recordedChildren.isEmpty })

  let data = try answer.data()
  #expect(data["logicVersion"] as? String == "12.3.1")
  #expect(data["depth"] as? Int == 2)
  #expect(data["out"] as? String == file.path)
  #expect(data["elementsAtEachDepth"] as? [Int] == [1, 2])
  let printedRoot = data["root"] as? [String: Any]
  #expect(printedRoot?["role"] as? String == "AXApplication")
  #expect((printedRoot?["children"] as? [Any])?.count == 2)

  let meta = try answer.printed()["meta"] as? [String: Any]
  #expect(meta?["session"] is NSNull)
  #expect(meta?["step"] is NSNull)

  try FileManager.default.removeItem(at: folder)
}

/// A person who runs this without Logic gets the one cause of it, and a script reads the number
/// that says so. An empty tree would read the same as a Logic that shows nothing, so the command
/// refuses instead of printing one.
@Test func inspectWithoutLogicSaysLogicIsNotRunning() throws {
  let answer = Answer()
  let typed = try Logicctl.parseAsRoot(["inspect"])
  let inspect = try #require(typed as? Inspect)

  let status = inspect.answer(
    of: { throw DriverRefusal.logicNotRunning },
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 4)
  #expect(try answer.failureCode() == "logic_not_running")
  #expect(try answer.printed()["data"] is NSNull)
  #expect(answer.err.hasPrefix("logicctl: logic_not_running: "))
}

/// `--window main` reads the window of the project and leaves the menu bar out, which is what a
/// person wants when they are looking at what a project shows. Without the flag the tree starts at
/// the application, and it prints four levels, which is the depth the story asks for.
@Test func inspectStartsAtTheWindowWhenItIsAsked() throws {
  let logic = try tree(from: aTreeOfFourLevels)
  let answer = Answer()

  let typed = try Logicctl.parseAsRoot(["inspect", "--window", "main"])
  let inspect = try #require(typed as? Inspect)
  #expect(inspect.depth == 4)

  let status = inspect.answer(
    of: source(logic),
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 0)
  let data = try answer.data()
  let root = data["root"] as? [String: Any]
  #expect(root?["role"] as? String == "AXWindow")
  #expect(root?["title"] as? String == "Sketch")
  #expect(data["elementsAtEachDepth"] as? [Int] == [1, 1, 1])

  let whole = Answer()
  let application = try #require(try Logicctl.parseAsRoot(["inspect"]) as? Inspect)
  _ = application.answer(
    of: source(logic),
    standardOutput: whole.write,
    standardError: whole.writeError)
  #expect((try whole.data()["root"] as? [String: Any])?["role"] as? String == "AXApplication")
  #expect(try whole.data()["elementsAtEachDepth"] as? [Int] == [1, 2, 2, 1])
}

/// A flag that logicctl cannot act on stops before Logic is asked anything, so nothing is read and
/// nothing is written. Each one comes back as the JSON every other answer is written in.
@Test func inspectRefusesFlagsItCannotActOnBeforeItReadsLogic() throws {
  for arguments in [
    ["inspect", "--window", "nope"],
    ["inspect", "--depth", "0"],
    ["inspect", "--out", "/logicctl-no-such-folder/tree.json"],
  ] {
    let answer = Answer()
    let status = Logicctl.run(
      arguments: arguments,
      standardOutput: answer.write,
      standardError: answer.writeError)

    #expect(status == 2)
    #expect(try answer.failureCode() == "invalid_argument")
    #expect(try answer.printed()["data"] is NSNull)
  }
}
