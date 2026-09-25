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

/// A route over the recorded panel, where every control is found by its locator in the tree.
///
/// The reads answer from the tree and the presses are recorded, so a walk that named a control the
/// panel does not carry fails here rather than on the Mac.
private final class ARecordedPanel {
  /// The names of the locators that were pressed, in order.
  private(set) var pressed: [String] = []

  /// Whether the Import button reads enabled once the file is selected.
  private let importIsEnabled: Bool

  /// The folder the panel says it is in.
  private var folder = "Desktop"

  init(importIsEnabled: Bool) {
    self.importIsEnabled = importIsEnabled
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
      openFolder: { name in self.folder = name },
      folderShown: { self.folder },
      startUpDisk: { "A Disk Of Its Own" },
      selection: SelectionGuard(select: { _ in }, selection: { [thePath.name] }))
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
