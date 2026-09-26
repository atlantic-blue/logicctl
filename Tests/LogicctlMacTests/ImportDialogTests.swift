import Foundation
import LogicctlCore
import LogicctlMac
import Testing

/// The recorded Import panel of Logic 12.3.1, which every walk here is made in.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

/// The element the recorded panel starts at.
private func thePanel() throws -> any AXNode {
  try RecordedTree(contentsOf: fixtureFolder.appending(path: "import-panel.json")).root
}

/// Where the file of these tests sits, as the panel walks it.
private let thePath = ImportPath(
  resolved: "/Users/someone/Music/notes.mid",
  folders: ["Users", "someone", "Music"],
  name: "notes.mid")

/// One thing the walk did to the file list, in the order it did it.
private enum Move: Equatable {
  /// The row of this name was scrolled into view.
  case broughtIntoView(String)

  /// The row of this name was asked to open.
  case opened(String)
}

/// When the Where popup of the panel says the folder the walk asked for.
private enum WhenThePopupCatchesUp {
  /// The popup says it on the first read.
  case atOnce

  /// The popup says it on the second read, which is a panel that moved after the open answered.
  case oneReadLater

  /// The popup never says it.
  case never
}

/// A route over the recorded panel, where every control is found by its locator in the tree.
///
/// The reads answer from the tree and the presses are recorded, so a walk that named a control the
/// panel does not carry fails here rather than on the Mac.
private final class ARecordedPanel {
  /// The names of the locators that were pressed, in order.
  private(set) var pressed: [String] = []

  /// Everything the walk did to the file list, in order.
  private(set) var moves: [Move] = []

  /// Whether the Import button reads enabled once the file is selected.
  private let importIsEnabled: Bool

  /// When the popup shows a folder the walk opened.
  private let popup: WhenThePopupCatchesUp

  /// The number the open action answers, as Accessibility answers it.
  private let openAnswer: Int32

  /// The folder the panel says it is in.
  private var folder = "Desktop"

  /// The folder the popup shows on its next read, for a panel that moves one read late.
  private var next: String?

  init(importIsEnabled: Bool, popup: WhenThePopupCatchesUp = .atOnce, openAnswer: Int32 = 0) {
    self.importIsEnabled = importIsEnabled
    self.popup = popup
    self.openAnswer = openAnswer
  }

  /// The route, with every read taken from the recorded panel.
  func dialog() throws -> ImportDialog {
    let panel = try thePanel()
    return ImportDialog(
      openTheMenuItem: {},
      showsThePanel: { true },
      press: { locator in
        // The walk has to find the control in the recorded panel before it can be pressed.
        _ = try LocatorResolver.element(of: locator, in: panel)
        self.pressed.append(locator.name)
      },
      bringToFront: {},
      enabled: { locator in
        _ = try LocatorResolver.element(of: locator, in: panel)
        return self.importIsEnabled
      },
      pressItem: { title in self.folder = title },
      bringIntoView: { name in self.moves.append(.broughtIntoView(name)) },
      openFolder: { name in
        self.moves.append(.opened(name))
        if let refusal = ImportDialog.refusal(forOpenAnswer: self.openAnswer, folder: name) {
          throw refusal
        }
        switch self.popup {
        case .atOnce:
          self.folder = name
        case .oneReadLater:
          self.next = name
        case .never:
          break
        }
      },
      folderShown: {
        let shown = self.folder
        if let waiting = self.next {
          self.folder = waiting
          self.next = nil
        }
        return shown
      },
      startUpDisk: { "A Disk Of Its Own" },
      selection: SelectionGuard(select: { _ in }, selection: { [thePath.name] }))
  }
}

/// A clock a test moves itself, so a wait of any length costs no real time.
private final class WalkTime {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// A panel whose Import button is disabled takes no press, so the route stops before it.
///
/// Measured on Logic 12.3.1 on 2026-09-25, on a copy under a temporary folder: with Logic behind
/// another application, setting `AXSelected` on the file row does select it, and `OKButton` keeps
/// `AXEnabled` false. The press of a disabled button changes nothing, and the command that read
/// the project afterwards would blame the import for an answer the Mac never gave. So the route
/// reads the button and names it.
@Test func aDisabledImportButtonStopsTheRoute() throws {
  let panel = ARecordedPanel(importIsEnabled: false)
  let route = try panel.dialog()

  let refused = #expect(throws: ImportDialog.Refusal.self) {
    try route.importTheFile(at: thePath, limitMs: 10, clock: { 0 }, sleeper: { _ in })
  }

  #expect(refused?.code == .elementNotFound, "exit 5")
  #expect(refused?.reason.contains("OKButton") == true, "the reason names the control")
  #expect(panel.pressed == ["import.wherePopup"], "the Import button was never pressed")
}

/// The same panel with the button enabled presses Import, so the test above fails for the button
/// alone and not for anything else on the walk.
@Test func anEnabledImportButtonIsPressed() throws {
  let panel = ARecordedPanel(importIsEnabled: true)
  let route = try panel.dialog()

  try route.importTheFile(at: thePath, limitMs: 10, clock: { 0 }, sleeper: { _ in })

  #expect(panel.pressed == ["import.wherePopup", "import.importButton"])
}

/// A file Logic did import is imported, whatever the open action answered.
///
/// Measured on this Mac at 14:40 on 2026-09-26 (Logic 12.3.1): three imports out of three failed
/// with `internal` and "Logic refused to open Users in the Import panel, error -25205", and the
/// Where popup read the new folder every time. So the folder had opened and the person was told
/// that nothing happened. The popup says whether the panel moved, and the number the open action
/// answers says nothing about it, so a panel that moves after the answer still imports the file.
@Test func theWalkGoesOnWhenAXOpenAnswersUnsupportedButThePanelMoved() throws {
  let panel = ARecordedPanel(importIsEnabled: true, popup: .oneReadLater, openAnswer: -25205)
  let route = try panel.dialog()

  try route.importTheFile(at: thePath, limitMs: 10, clock: { 0 }, sleeper: { _ in })

  #expect(panel.pressed == ["import.wherePopup", "import.importButton"], "the file is imported")
  #expect(
    panel.moves == [
      .broughtIntoView("Users"), .opened("Users"),
      .broughtIntoView("someone"), .opened("someone"),
      .broughtIntoView("Music"), .opened("Music"),
    ],
    "every folder of the path was opened")
}

/// A panel that never shows the folder imports nothing, and it is closed on the way out.
///
/// A file of the same name sits in more than one folder on any Mac. A walk that pressed Import
/// here would put somebody else's notes in the project and report the path the person typed. The
/// measured failure left the panel open on the screen, so the walk presses Cancel before it
/// answers.
@Test func aPanelThatNeverShowsTheFolderImportsNothingAndIsClosed() throws {
  let panel = ARecordedPanel(importIsEnabled: true, popup: .never)
  let route = try panel.dialog()
  let time = WalkTime()

  let refused = #expect(throws: ImportDialog.Refusal.self) {
    try route.importTheFile(at: thePath, limitMs: 10, clock: time.read, sleeper: time.sleep)
  }

  #expect(refused?.code == .timeout, "exit 6")
  let details = try #require(refused?.details, "the failure says more than its sentence")
  #expect(
    details == .object(["folder": .string("Users"), "waitedMs": .number(10)]),
    "the details name the folder the panel never showed, and how long it was given")
  #expect(
    panel.pressed == ["import.wherePopup", "import.cancelButton"],
    "Import was never pressed, and the panel was closed")
}

/// A row out of view is scrolled to before it is opened.
///
/// Measured through AppleScript at 15:55 on 2026-09-26, on a copy of F-T13 under a temporary
/// folder: `AXOpen` on `Music`, row 23 of 23 of the home folder, did nothing and the Where popup
/// stayed where it was. The same `AXOpen` moved the popup once the vertical bar of the list view
/// was set. So a walk that does not scroll first opens nothing on any folder with a long list.
@Test func everyRowIsBroughtIntoViewBeforeItIsOpened() throws {
  let panel = ARecordedPanel(importIsEnabled: true)
  let route = try panel.dialog()

  try route.importTheFile(at: thePath, limitMs: 10, clock: { 0 }, sleeper: { _ in })

  for folder in thePath.folders {
    let scrolled = try #require(panel.moves.firstIndex(of: .broughtIntoView(folder)))
    let opened = try #require(panel.moves.firstIndex(of: .opened(folder)))
    #expect(scrolled < opened, "\(folder) was scrolled to before it was opened")
  }
}

/// A tree in the form `inspect` writes, holding the two bars of the file list.
///
/// This tree is written here rather than recorded, from the shape the measurement of 15:55 on
/// 2026-09-26 reports: the scroll area of the list view holds a horizontal bar first and a
/// vertical bar second. The rows are cut to three, because the pick does not count them.
private let aPanelWithTwoScrollBars = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXWindow",
      "identifier": "open-panel",
      "title": "Import",
      "children": [
        {
          "role": "AXScrollArea",
          "children": [
            {
              "role": "AXScrollBar",
              "orientation": "AXHorizontalOrientation",
              "value": "0"
            },
            {
              "role": "AXScrollBar",
              "orientation": "AXVerticalOrientation",
              "value": "0"
            },
            {
              "role": "AXOutline",
              "identifier": "ListView",
              "description": "list view",
              "children": [
                { "role": "AXRow" },
                { "role": "AXRow" },
                { "role": "AXRow" }
              ]
            }
          ]
        }
      ]
    }
  }
  """

/// The bar the walk moves is the vertical one, and it is not the first bar of the scroll area.
///
/// Both bars carry the role `AXScrollBar`, and the horizontal one comes first, so a walk that took
/// the first bar would scroll the list sideways and leave the row where it was.
@Test func theBarThatScrollsTheFileListIsTheVerticalOne() throws {
  let panel = try JSONDecoder()
    .decode(RecordedTree.self, from: Data(aPanelWithTwoScrollBars.utf8))
  let area = try #require(panel.root.recordedChildren.first)
  let bars = area.recordedChildren.filter { $0.role == "AXScrollBar" }
  #expect(bars.first?.orientation == "AXHorizontalOrientation", "the first bar is the wrong one")

  let moved = ImportDialog.verticalScrollBarOfTheFileList(in: panel.root)

  #expect(moved?.orientation == "AXVerticalOrientation", "the second bar is the one that scrolls")
  #expect(ImportDialog.scrollValue(forRow: 23, of: 23) == 1, "the last row sits at the bottom")
  #expect(ImportDialog.scrollValue(forRow: 1, of: 23) == 0, "the first row sits at the top")
  #expect(ImportDialog.scrollValue(forRow: 1, of: 1) == nil, "one row cannot be scrolled to")
}
