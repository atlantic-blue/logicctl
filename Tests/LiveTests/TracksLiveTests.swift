import Foundation
import Testing

/// One command of phase 2, and the live scenario that drives it against Logic.
struct Phase2Command: Sendable, Equatable {
  /// The name of the live scenario that drives this command on this Mac.
  let liveScenario: String

  /// The command as a person types it.
  let typed: String
}

/// The commands of phase 2, in the order a person drives them.
///
/// The live scenarios read this, and so does the scenario of the pipeline, so the phase has one
/// order and both read the same one.
enum Phase2Flow {
  /// Every command of phase 2, in order.
  static let inOrder: [Phase2Command] = []
}

/// What a live scenario of phase 2 does, and what it never does to the work of a person.
enum Phase2Live {
  /// The name of the project each live scenario makes.
  static let projectName = "Phase2.logicx"

  /// The folder where a person keeps their projects of Logic.
  static var logicFolder: URL {
    LiveHarness.musicFolder.appending(path: "Logic")
  }

  /// Whether this run drives the real Logic.
  static func runsOnThisMac(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    true
  }

  /// Says on the output of the run that one live scenario is about to drive Logic.
  static func announce(
    _ command: Phase2Command,
    through say: (String) -> Void = LiveHarness.liveScenario
  ) {
    say("")
  }

  /// Where a live scenario saves the project it made.
  static func saveTarget(
    in folder: URL,
    musicFolder: URL = LiveHarness.musicFolder
  ) throws -> URL {
    folder
  }

  /// The names directly under the folder of Logic projects, and nothing deeper.
  static func namesUnderTheLogicFolder(
    _ folder: URL = Phase2Live.logicFolder,
    fileManager: FileManager = .default
  ) -> [String] {
    []
  }

  /// The lines that name what arrived under the folder of Logic projects while the run drove Logic.
  static func newEntryLines(before: [String], after: [String]) -> [String] {
    []
  }

  /// The line that names the session the run leaves behind.
  static func sessionLine(_ session: String) -> String {
    ""
  }

  /// The line that says what `meta` said about the picture of the window of Logic.
  static func screenshotLine(_ said: String?) -> String? {
    nil
  }
}

/// Phase 2 of the stories is accepted on this Mac, and it leaves a session the journal replays.
///
/// `make accept PART=2` is the run that answers whether logicctl builds the track layout of a
/// project in the real Logic Pro 12.3.1. The pipeline cannot answer that: it has no Logic, no
/// project and no grant. So this scenario holds the part of the answer a machine with no Logic can
/// hold, and it holds it where the pipeline reads it on every pull request.
///
/// A phase made of live scenarios alone could not do this. The runner counts a scenario it left out
/// as a test that ran, so a live only scenario reads as a pass on every machine with no Logic.
/// A phase that drove nothing at all would then close the step.
///
/// So this scenario asserts the acceptance of phase 2. The phase drives every command of phase 2,
/// in the order a person drives them. Each command answers for itself on the output, so the count
/// of those lines says how many of them ran. The phase drives Logic nowhere by accident. It works
/// on a project in a folder of the run, and it refuses the folder a person keeps their own work in.
/// And it names the session it leaves behind, because the journal part replays that session.
@Test func phaseTwoAgainstLogic() throws {
  let typed = Phase2Flow.inOrder.map(\.typed)
  #expect(
    typed == [
      "tracks add --type software-instrument",
      "tracks add --type audio",
      "tracks rename --index 1 --name Bass",
      "tracks mute --index 1 --on",
      "tracks mute --index 1 --off",
      "tracks solo --index 1 --on",
      "tracks delete --index 2",
      "tracks list",
    ],
    "phase 2 is every command of the phase, in the order a person drives them: \(typed)")

  var said: [String] = []
  for command in Phase2Flow.inOrder {
    Phase2Live.announce(command, through: { said.append($0) })
  }
  #expect(
    said == Phase2Flow.inOrder.map(\.liveScenario),
    "each command answers for itself, by the name of the scenario that drives it: \(said)")
  #expect(
    said.isEmpty == false && Set(said).count == said.count,
    "and no two of them answer to one name, which a count reads as one scenario: \(said)")

  #expect(Phase2Live.runsOnThisMac([:]) == false, "a run that names nothing drives no Logic")
  #expect(Phase2Live.runsOnThisMac(["LOGICCTL_LIVE": "0"]) == false)
  #expect(
    Phase2Live.runsOnThisMac(["LOGICCTL_LIVE": "1"]),
    "and a person turns the phase on with the one variable, on the Mac that has Logic")

  let folder = try LiveHarness.temporaryFolder()
  defer { try? FileManager.default.removeItem(at: folder) }

  let target = try Phase2Live.saveTarget(in: folder)
  #expect(
    LiveHarness.isUnder(folder, target),
    "the project of a scenario is saved in the folder of the run: \(target.path)")
  #expect(target.pathExtension == "logicx", "and it is a project of Logic: \(target.path)")

  var refused: Error?
  do {
    _ = try Phase2Live.saveTarget(in: Phase2Live.logicFolder)
  } catch {
    refused = error
  }
  #expect(
    isTheMusicFolderRefusal(refused),
    "the folder a person keeps their work in is refused: \(String(describing: refused))")

  let arrived = Phase2Live.newEntryLines(
    before: ["Sketch.logicx"], after: ["Phase2.logicx", "Sketch.logicx"])
  #expect(
    arrived == ["music folder: new entry Phase2.logicx"],
    "a name that arrived under the folder of Logic projects is reported: \(arrived)")
  #expect(
    Phase2Live.newEntryLines(before: ["Sketch.logicx"], after: []).isEmpty,
    "and the report names what arrived, because the run removes nothing there")

  #expect(
    Phase2Live.sessionLine("7f3a9c11") == "live session: 7f3a9c11",
    "the run names the session it leaves behind, which the journal part replays")

  #expect(
    Phase2Live.screenshotLine(nil) == nil,
    "a step that carries a picture of the window says nothing more about it")
  #expect(
    Phase2Live.screenshotLine("no grant") == "live screenshot: no grant",
    "and a Mac that took none says what it said, without failing the phase")
}

/// Whether the harness refused a path for sitting under the music folder of this Mac.
private func isTheMusicFolderRefusal(_ error: Error?) -> Bool {
  switch error as? LiveHarness.Refusal {
  case .theProjectIsUnderTheMusicFolder, .theCopyWouldBeUnderTheMusicFolder:
    return true
  default:
    return false
  }
}
