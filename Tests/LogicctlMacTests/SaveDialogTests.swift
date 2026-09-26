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

/// A save walks the panel to the folder and types the name of the project, and nothing else.
///
/// Measured on this Mac at 12:46 on 2026-09-26: the route wrote the whole path into the name field,
/// Logic read that value as a name, and it made a project called
/// `:private:tmp:logicctl-probe:np79.logicx` in the music folder while the command answered
/// `timeout`. The panel takes no path in that field. It lists the folders of this Mac in one column
/// per part of the path, so the route walks those columns and types the name on its own.
///
/// A folder the column does not list stops the walk before anything is typed. The panel closes, the
/// failure names that folder, and the project stays where it is.
@Test func saveWalksThePanelToTheFolderAndTypesOnlyTheName() throws {
  let panel = ARecordedSavePanel()

  try panel.dialog().save(
    toPath: "/private/tmp/logicctl-probe/Song.logicx", limitMs: 10, clock: { 0 }, sleeper: { _ in })

  #expect(
    panel.opened == ["private in column 1", "tmp in column 2", "logicctl-probe in column 3"],
    "the route walked the columns of the panel, one folder of the path at a time")
  let typed = try #require(panel.written[Locators.saveNameField.name], "the field was written")
  #expect(typed == "Song.logicx", "the name field takes the name of the project and nothing else")
  #expect(!typed.contains("/"), "a path in that field is read as a name")
  #expect(!typed.contains(":"), "and every slash of it comes back as a colon")
  #expect(panel.pressed == [Locators.saveButton.name], "Save was pressed, and Cancel was not")

  let missing = ARecordedSavePanel()
  let refused = #expect(throws: SaveDialog.Refusal.self) {
    try missing.dialog().save(
      toPath: "/private/tmp/nowhere/Song.logicx", limitMs: 10, clock: { 0 }, sleeper: { _ in })
  }

  let refusal = try #require(refused)
  #expect(refusal.failure.code == .invalidArgument, "the path is what a person fixes")
  #expect(refusal.failure.code.exitCode == 2, "the number the process exits with")
  #expect(refusal.reason.contains("nowhere"), "the reason names the folder that is not there")
  #expect(
    missing.opened == ["private in column 1", "tmp in column 2"],
    "the walk stopped at the folder the column does not list")
  #expect(missing.written.isEmpty, "nothing was typed into the panel")
  #expect(missing.pressed == [Locators.saveCancelButton.name], "and the panel was closed")
}

/// An open is read back from the panel, and never taken from what the action answered.
///
/// Measured on this Mac at 15:00 on 2026-09-26: `AXOpen` on the name of a folder in a column
/// answers -25205, and the panel opens that folder all the same. So what the action answered says
/// nothing, and the route reads the Where popup until it shows the folder. A panel that never
/// shows it stops the walk with `timeout`, and the reason names the folder. A walk that went on
/// from there would type the name of the project into a panel standing in another folder.
@Test func aPanelThatNeverReachesTheFolderStopsTheWalkWithTimeout() throws {
  #expect(SaveDialog.opensAnyway(-25205), "the answer Logic gives while it opens the folder")
  #expect(!SaveDialog.opensAnyway(-25204), "and every other answer is a refusal")

  let panel = ARecordedSavePanel(reachesTheFolder: false)
  let time = ATime()

  let refused = #expect(throws: SaveDialog.Refusal.self) {
    try panel.dialog().save(
      toPath: "/private/tmp/logicctl-probe/Song.logicx", limitMs: 200, clock: time.read,
      sleeper: time.sleep)
  }

  let refusal = try #require(refused)
  #expect(refusal.failure.code == .timeout, "Logic did not get there")
  #expect(refusal.failure.code.exitCode == 6, "the number the process exits with")
  #expect(refusal.reason.contains("private"), "the reason names the folder it never reached")
  #expect(panel.opened == ["private in column 1"], "the walk stopped at that folder")
  #expect(panel.written.isEmpty, "nothing was typed into the panel")
  #expect(panel.pressed == [Locators.saveCancelButton.name], "and the panel was closed")
}

/// Every failure after the panel opened closes the panel.
///
/// Measured on this Mac at 15:00 on 2026-09-26: an open that Logic refused left the Save panel
/// standing over the project window, with the Mixer behind it. Logic takes nothing else while a
/// panel is open, so the next command reads that panel and stops with `dialog_open`. A person is
/// then left closing a window by hand to carry on. What Logic said still reaches the caller.
@Test func aFailureInsideTheWalkClosesThePanel() throws {
  let panel = ARecordedSavePanel(refusesTheOpen: true)

  let refused = #expect(throws: SaveDialog.Refusal.self) {
    try panel.dialog().save(
      toPath: "/private/tmp/logicctl-probe/Song.logicx", limitMs: 10, clock: { 0 },
      sleeper: { _ in })
  }

  let refusal = try #require(refused)
  #expect(refusal.failure.code == .internalFailure, "what Logic said reaches the caller")
  #expect(refusal.reason.contains("private"), "and it names the folder it was opening")
  #expect(panel.pressed == [Locators.saveCancelButton.name], "the panel was closed")
  #expect(panel.written.isEmpty, "and nothing was typed into it")
}

/// Each column of the panel is read by its number, and a row carries its name in a field.
///
/// The recorded panel was walked to `/private/tmp/logicctl-probe`, so column 1 lists the root of
/// the start up disk and each column to the right lists the folder opened before it. A read that
/// took two columns as one would leave the walk looking for `tmp` among the folders of the root.
@Test func theColumnsOfTheSavePanelAreReadOneAtATime() throws {
  let panel = try treeRoot(of: "save-panel-expanded.json")

  #expect(try SaveDialog.names(inColumnNumbered: 0, of: panel).contains("private"))
  #expect(try SaveDialog.names(inColumnNumbered: 1, of: panel) == ["etc", "tmp", "var"])
  #expect(
    try SaveDialog.names(inColumnNumbered: 2, of: panel) == ["logicctl-fixtures", "logicctl-probe"])

  let name = try SaveDialog.nameField(of: "tmp", inColumnNumbered: 1, of: panel)
  #expect(name.role == "AXTextField", "the name of a row is a field of it")
  #expect(name.actions.contains(SaveDialog.openAction), "and opening that field opens the folder")

  let refused = #expect(throws: LocatorResolver.Refusal.self) {
    try SaveDialog.names(inColumnNumbered: 9, of: panel)
  }
  #expect(refused?.locator == Locators.saveColumn(number: 9).name, "a column that is not there")
}

/// A route over the recorded Save panel, walked the way Logic answers it.
///
/// The columns are the ones Logic listed, so a folder this panel does not hold is a folder the walk
/// cannot find here either. A recorded tree does not move, so the Where popup answers the last
/// folder the route opened, which is what Logic does with it.
private final class ARecordedSavePanel {
  /// Every folder the route opened, with the column it opened it in.
  private(set) var opened: [String] = []

  /// The names of the locators the route pressed, in order.
  private(set) var pressed: [String] = []

  /// What the route wrote into each field.
  private(set) var written: [String: String] = [:]

  /// True while the panel is open, which the press of Save ends.
  private var showing = true

  /// The folder the Where popup shows.
  private var folder = ""

  /// Whether the Where popup follows the opens, as the panel of Logic does.
  private let reachesTheFolder: Bool

  /// Whether Logic refuses the open, the way it does for any answer that is not -25205.
  private let refusesTheOpen: Bool

  init(reachesTheFolder: Bool = true, refusesTheOpen: Bool = false) {
    self.reachesTheFolder = reachesTheFolder
    self.refusesTheOpen = refusesTheOpen
  }

  /// The route, with every read taken from the recorded panel.
  func dialog() throws -> SaveDialog {
    let panel = try treeRoot(of: "save-panel-expanded.json")
    return SaveDialog(
      openTheMenuItem: {},
      showsThePanel: { self.showing },
      write: { locator, text in
        // The walk has to find the field in the recorded panel before it can be written into.
        _ = try LocatorResolver.element(of: locator, in: panel)
        self.written[locator.name] = text
      },
      press: { locator in
        _ = try LocatorResolver.element(of: locator, in: panel)
        self.pressed.append(locator.name)
        if locator.name == Locators.saveButton.name {
          self.showing = false
        }
      },
      resolve: { $0 },
      namesInColumn: { number in
        try SaveDialog.names(inColumnNumbered: number, of: panel)
      },
      openFolder: { number, name in
        _ = try SaveDialog.nameField(of: name, inColumnNumbered: number, of: panel)
        self.opened.append("\(name) in column \(number + 1)")
        guard !self.refusesTheOpen else {
          throw SaveDialog.Refusal(
            reason: "Logic refused to open \(name) in the Save panel, error -25204.",
            code: .internalFailure)
        }
        if self.reachesTheFolder {
          self.folder = name
        }
      },
      folderShown: { self.folder })
  }
}

/// A clock and a sleep a test moves itself, so a wait of any length costs the suite no time.
private final class ATime {
  private var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
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
