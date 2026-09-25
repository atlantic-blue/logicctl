import Foundation
import LogicctlMac
import Testing

/// Phase 0 of the stories, against the Logic that runs on this Mac.
///
/// The pipeline proves the tree reader against a tree that `inspect` recorded from Logic 12.3.1,
/// which says nothing about whether the reads still work on the running application. These two
/// scenarios are where that is answered: the grants this Mac gave the signed binary are real, and
/// `inspect` reads the window of a project Logic has open now.
///
/// They run one at a time, because both drive the one Logic this Mac has.
@Suite(.serialized, .enabled(if: LiveHarness.runsLive()))
struct Phase0LiveScenarios {
  /// The operator gave logicctl both grants, and the signed binary still holds them (story S0.1).
  ///
  /// macOS keys a grant on the signature, so this answer belongs to the binary `make sign` built
  /// and to no other. A run that reads `false` here is a Mac where every later scenario would read
  /// an empty interface and report a project with nothing in it, which is why phase 0 asks this
  /// first.
  @Test func permissionsReadsBothGrantsOfThisMac() throws {
    let answer = try LiveHarness.logicctl(["permissions"])
    let read = try LiveHarness.envelope(
      LiveHarness.GrantsAnswer.self, of: answer, from: "permissions")

    #expect(
      answer.status == 0,
      "a Mac that granted both exits 0: \(answer.printed) \(answer.complained)")
    #expect(read.data?.accessibility == true, "this Mac lets logicctl read Logic and drive it")
    #expect(read.data?.screenRecording == true, "and lets it save the picture every step carries")
  }

  /// The operator reads the tree of a project Logic has open (story S0.3).
  ///
  /// The project is a copy in a folder of this run, so the work of a person is never opened,
  /// changed or saved. Logic shows the copy by name, and `inspect --window main` answers with that
  /// window and the version of Logic it read it from.
  @Test func inspectReadsTheTreeOfTheScratchCopy() throws {
    let folder = try LiveHarness.temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let copy = try LiveHarness.copyOfTheScratchProject(into: folder)
    try LiveHarness.openInLogic(copy)

    let tree = try LiveHarness.read(
      RecordedTree.self, from: ["inspect", "--window", "main", "--depth", "2"])
    let name = copy.deletingPathExtension().lastPathComponent

    #expect(
      tree.logicVersion == LiveHarness.logicVersion,
      "the tree says which Logic it came from: \(tree.logicVersion)")
    #expect(
      tree.root.title?.hasPrefix(name) == true,
      "and the window it read is the copy: \(tree.root.title ?? "no title")")
    #expect(tree.root.recordedChildren.isEmpty == false, "the window carries elements to read")
  }
}
