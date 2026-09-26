import Foundation
import LogicctlMac
import Testing

/// The version of Logic the trees were recorded from.
private let recordedVersion = "12.3.1"

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// The window of the project `new-project` makes, recorded with the Library closed and the sheet
/// that asks for a track open.
private let theNewProject = "empty-project-new-track-sheet.json"

/// The window of a project that holds three tracks, recorded with the Library open.
private let theProjectWithTheLibraryOpen = "region.json"

/// The title Logic gives the window of the project `new-project` makes.
private let theNewProjectWindow = "Untitled.logicx - Tracks"

/// What Logic calls the group that holds the header of every track.
private let theHeaderOfTheTracks = "Tracks header"

/// How many tracks the recorded project with the Library open holds.
private let tracksOfThatProject = 3

/// A person makes a project, and then reads it.
///
/// `new-project` made an empty project on this Mac at 01:50 on 2026-09-26, and every read after it
/// failed with `element_not_found` and the name `window.main`. Logic opens a project it has just
/// made with the Library closed, and the trees of the fixtures were recorded with the Library open.
/// So the group that holds the track headers is the fourth group of one window and the third group
/// of the other, and a walk that counts groups finds the header in the first project and nothing in
/// the second. A person who closes the Library on any project loses the same reads.
///
/// The walk names the group by what Logic calls it. So the tracks of a new project are read, the
/// tracks of a project with the Library open are read, and the number of panes a person has open
/// stops deciding whether a command works.
@Test func theTracksHeaderIsFoundWithTheLibraryClosed() throws {
  let newProject = try windowOfTheRecording(theNewProject)
  let header = try LocatorResolver.element(of: Locators.tracksHeader, in: newProject)

  #expect(
    header.description == theHeaderOfTheTracks,
    "the group of the track headers, in a project Logic shows no Library for")

  let logic = LogicTree(logicVersion: recordedVersion, root: LogicShowing(windows: [newProject]))
  let project = try #require(
    logic.atTheProjectWindow(), "a read finds the window the new project sits in")

  #expect(project.root.title == theNewProjectWindow, "the window `new-project` leaves open")

  let openLibrary = try windowOfTheRecording(theProjectWithTheLibraryOpen)
  let found = try LocatorResolver.element(of: Locators.tracksHeader, in: openLibrary)
  let headers = found.children.filter { $0.role == "AXLayoutItem" }

  #expect(
    found.description == theHeaderOfTheTracks,
    "the same group as before, in a project Logic shows the Library for")
  #expect(headers.count == tracksOfThatProject, "one header per track of the recorded project")
}

/// The window a recorded tree starts at.
private func windowOfTheRecording(_ file: String) throws -> any AXNode {
  try RecordedTree(contentsOf: fixtureFolder.appending(path: file)).root
}

/// The application of Logic, showing the windows a test gives it.
///
/// A recorded tree starts at one window, and `atTheProjectWindow()` answers a tree that starts at a
/// window unchanged. So the recorded window is put under an application here, which is the shape
/// the running Logic answers with and the shape that makes the read look for its window.
private struct LogicShowing: AXNode {
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
