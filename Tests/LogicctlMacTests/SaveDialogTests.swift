import Foundation
import LogicctlCore
import LogicctlMac
import Testing

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

/// The element a recorded tree starts at.
private func treeRoot(of file: String) throws -> any AXNode {
  try RecordedTree(contentsOf: fixtureFolder.appending(path: file)).root
}

/// A tree written in a test, read back the way a recorded tree is read.
private func treeRead(from text: String) throws -> RecordedTree {
  try JSONDecoder().decode(RecordedTree.self, from: Data(text.utf8))
}

/// The command has to know when Logic is ready to be told where the project goes.
///
/// It writes a path into a field and presses a button, and both of those land somewhere whatever
/// Logic is showing. So the panel is read first, from the window itself rather than from its
/// title, which carries a different word in every language. A project window is not the panel, and
/// a command that read one as the other would type a path into the project.
@Test func theSavePanelIsReadFromTheWindowAndNotFromItsTitle() throws {
  #expect(
    SaveDialog.isThePanel(try treeRoot(of: "save-as-window.json")),
    "the window Logic opens for File, Save As")
  #expect(
    !SaveDialog.isThePanel(try treeRoot(of: "one-track.json")),
    "a project Logic has open is not the panel")
  #expect(
    !SaveDialog.isThePanel(try treeRoot(of: "project-chooser.json")),
    "the window Logic shows while no project is open is not the panel")
  #expect(
    !SaveDialog.isThePanel(try treeRoot(of: "new-project-sheet.json")),
    "a project with the New Track sheet on it is not the panel")
}

/// The menu bar is the one thing logicctl drives that sits in no window.
///
/// Every other walk starts at a window and is a locator of `Locators.swift`. This one starts at
/// the application, so it is written here, and the title it looks for carries the ellipsis of
/// macOS, which is one character. A search for three full stops finds nothing, and the command
/// would report that Logic has no Save As at all.
@Test func theMenuWalkFindsSaveAsUnderFile() throws {
  let root = try treeRead(from: aMenuBar).root
  let item = try SaveDialog.menuItem(in: root)

  #expect(item.role == "AXMenuItem")
  #expect(item.title == SaveDialog.menuItemTitle)
  #expect(SaveDialog.menuItemTitle == "Save As\u{2026}", "the ellipsis is one character")
  #expect(
    item.identifier == "wanted", "the walk took the item under File, not the one Edit holds")
}

/// A Logic that offers no Save As is named, rather than pressed at.
@Test func aMenuWithNoSaveAsRefusesWithItsReason() throws {
  let root = try treeRead(from: aMenuBarWithNoSaveAs).root
  let refused = #expect(throws: SaveDialog.Refusal.self) {
    try SaveDialog.menuItem(in: root)
  }

  let refusal = try #require(refused)
  #expect(refusal.failure.code == .elementNotFound)
  #expect(refusal.failure.code.exitCode == 5, "the number the process exits with")
  #expect(refusal.reason.contains("Save As"), "the reason names what was not there")
}

/// An application with a File menu that carries Save As, and an Edit menu that carries one too.
private let aMenuBar = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXApplication",
      "children": [
        {
          "role": "AXMenuBar",
          "children": [
            {
              "role": "AXMenuBarItem",
              "title": "Edit",
              "children": [
                {
                  "role": "AXMenu",
                  "children": [
                    { "role": "AXMenuItem", "title": "Save As\\u2026", "identifier": "wrong" }
                  ]
                }
              ]
            },
            {
              "role": "AXMenuBarItem",
              "title": "File",
              "children": [
                {
                  "role": "AXMenu",
                  "children": [
                    { "role": "AXMenuItem", "title": "New" },
                    { "role": "AXMenuItem", "title": "Save" },
                    { "role": "AXMenuItem", "title": "Save As\\u2026", "identifier": "wanted" },
                    { "role": "AXMenuItem", "title": "Save A Copy As\\u2026" }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  }
  """

/// The same File menu, with Save As taken out of it.
private let aMenuBarWithNoSaveAs = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXApplication",
      "children": [
        {
          "role": "AXMenuBar",
          "children": [
            {
              "role": "AXMenuBarItem",
              "title": "File",
              "children": [
                {
                  "role": "AXMenu",
                  "children": [
                    { "role": "AXMenuItem", "title": "New" },
                    { "role": "AXMenuItem", "title": "Save" }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  }
  """
