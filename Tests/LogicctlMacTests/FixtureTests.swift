import Foundation
import LogicctlMac
import Testing

/// The version of Logic every tree in the fixture folder was read from.
private let recordedVersion = "12.3.1"

/// The states of Logic that Setup recorded, one file each. A later step adds its own files here and
/// leaves these, so the test asks for these by name and reads whatever else it finds as well.
private let recordedStates = [
  "empty.json",
  "event-list-automation.json",
  "event-list-notes.json",
  "mixer.json",
  "one-track.json",
  "plugin-menu.json",
  "region.json",
]

/// Where the recorded trees sit.
///
/// The folder is read from the source tree, and not as a resource of this test target, because it
/// sits beside the test targets rather than inside one, and a file outside a target is not a
/// resource any target can carry. Every module that walks a tree reads the same seven files for it.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// A later step can trust a recorded tree.
///
/// The pipeline has no Logic, so the locators of step 6 and every driver read after them are proved
/// against these files and nothing else. Two things make a file worth that. It says which Logic it
/// came from, because an element found by a path through 12.3.1 says nothing about another build.
/// And it names no path under the music folder of this Mac, because a tree is recorded from a copy
/// in a temporary folder and never from the projects a person keeps. A folder with no tree in it
/// fails too: a run that reads nothing reports success in the same words as a run that read them
/// all.
@Test func everyFixtureIsFromLogic1231() throws {
  let recorded = try treesInTheFixtureFolder()
  try #require(!recorded.isEmpty, "the fixture folder carries no tree, so this run proves nothing")
  for state in recordedStates {
    #expect(recorded.contains(state), "\(state) is one of the states Setup recorded")
  }

  for state in recorded {
    let tree = try RecordedTree(contentsOf: fixtureFolder.appending(path: state))
    #expect(tree.logicVersion == recordedVersion, "the version of Logic \(state) came from")
    #expect(elements(under: tree.root) > 1, "\(state) reads back as a tree of elements")
    let named = pathsUnderTheMusicFolder(under: tree.root)
    #expect(named.isEmpty, "\(state) names no project under the music folder: \(named)")
  }
}

/// The trees the folder carries, by name, in one order, so a failure names the same file every run.
private func treesInTheFixtureFolder() throws -> [String] {
  let read = try FileManager.default.contentsOfDirectory(atPath: fixtureFolder.path)
  return read.filter { $0.hasSuffix(".json") }.sorted()
}

/// How many elements a tree carries: this one, and every element under it.
private func elements(under node: any AXNode) -> Int {
  node.children.reduce(1) { counted, child in counted + elements(under: child) }
}

/// Every text in the tree that names a path under the music folder of this Mac.
///
/// A file cannot say which project it was read from, so this is the closest question it answers: no
/// window title, no field of a save panel and no help text carries such a path. Logic writes the
/// name of the open project into the title of its window, so a tree recorded from a project under
/// `~/Music` is the one that would carry one.
private func pathsUnderTheMusicFolder(under node: any AXNode) -> [String] {
  let carried = [node.title, node.identifier, node.value, node.description, node.help]
  var named = carried.compactMap { $0 }.filter { $0.contains("/Music/") }
  for child in node.children {
    named += pathsUnderTheMusicFolder(under: child)
  }
  return named
}
