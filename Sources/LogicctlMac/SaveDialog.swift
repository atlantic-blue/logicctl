import ApplicationServices
import Foundation
import LogicctlCore

/// Writes the open project to a path, through the window Logic opens for File, "Save As...".
///
/// Every operation is a closure the caller gives, as they are for `ProjectChooser`. The pipeline
/// has no Logic and no window server, so a test drives the same route with a Logic of its own and
/// macOS opens nothing.
///
/// The route waits for the panel to close before it answers. That window is the expected answer to
/// the menu item, so nothing reads it as a dialog to stop on, and a command that answered while it
/// was still open would tell a person their work is on disk while Logic is still asking where to
/// put it. Every other modal window of Logic is read after the action, by the run of the command,
/// which stops with `dialog_open`.
public struct SaveDialog {
  /// Why the route stopped. The reason reaches the answer of the command, so a person reads what
  /// Logic refused without going to look for a log.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// One short reason, in the words of the Mac that refused.
    public let reason: String

    /// The code a caller reads and exits with.
    public let code: ErrorCode

    public init(reason: String, code: ErrorCode = .elementNotFound) {
      self.reason = reason
      self.code = code
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(code: code, message: reason)
    }
  }

  /// Asks Logic for File, "Save As...". It answers nothing, because the window comes later and
  /// the route reads for it.
  public typealias OpenTheMenuItem = () throws -> Void

  /// True while Logic shows the panel that asks where the project goes.
  public typealias Read = () throws -> Bool

  /// Writes one text into the field a locator names, in place of what is in it.
  public typealias Write = (Locator, String) throws -> Void

  /// Presses the one element a locator names.
  public typealias Press = (Locator) throws -> Void

  /// The path with every symbolic link resolved, which is the path the panel shows.
  public typealias Resolve = (String) throws -> String

  /// The names one column of the browser lists, counted from 0.
  public typealias ReadNames = (Int) throws -> [String]

  /// Opens the folder of this name in the column at this number, counted from 0.
  public typealias OpenFolder = (Int, String) throws -> Void

  /// The folder the panel is in, as the Where popup shows it.
  public typealias ReadFolder = () throws -> String

  /// Presses the item of the open menu whose title is this.
  public typealias PressItem = (String) throws -> Void

  /// The name of the start up disk of this Mac.
  public typealias ReadDisk = () throws -> String

  /// Puts the rows of the column at this number in view, at a place from 0 to 1.
  public typealias Scroll = (Int, Double) throws -> Void

  /// Asks Logic for File, "Save As...".
  public let openTheMenuItem: OpenTheMenuItem

  /// Reads whether Logic shows the panel.
  public let showsThePanel: Read

  /// Writes into a field of the panel.
  public let write: Write

  /// Presses a button of the panel.
  public let press: Press

  /// Resolves the folder of the path before the walk.
  public let resolve: Resolve

  /// Reads the names one column of the browser lists.
  public let namesInColumn: ReadNames

  /// Opens one folder of a column.
  public let openFolder: OpenFolder

  /// Reads which folder the panel reached.
  public let folderShown: ReadFolder

  /// Presses an item of the menu the Where popup opens.
  public let pressItem: PressItem

  /// Reads what the start up disk is called.
  public let startUpDisk: ReadDisk

  /// Puts the rows of one column in view.
  public let scroll: Scroll

  public init(
    openTheMenuItem: @escaping OpenTheMenuItem,
    showsThePanel: @escaping Read,
    write: @escaping Write,
    press: @escaping Press,
    resolve: @escaping Resolve,
    namesInColumn: @escaping ReadNames,
    openFolder: @escaping OpenFolder,
    folderShown: @escaping ReadFolder,
    pressItem: @escaping PressItem,
    startUpDisk: @escaping ReadDisk,
    scroll: @escaping Scroll
  ) {
    self.openTheMenuItem = openTheMenuItem
    self.showsThePanel = showsThePanel
    self.write = write
    self.press = press
    self.resolve = resolve
    self.namesInColumn = namesInColumn
    self.openFolder = openFolder
    self.folderShown = folderShown
    self.pressItem = pressItem
    self.startUpDisk = startUpDisk
    self.scroll = scroll
  }
}

extension SaveDialog {
  /// Where the project goes, as the columns of the panel name it.
  public struct Destination: Equatable, Sendable {
    /// The folders of the path, from the root of the start up disk down, with the links resolved.
    public let folders: [String]

    /// The name of the project, which is the one text the name field takes.
    public let name: String

    public init(folders: [String], name: String) {
      self.folders = folders
      self.name = name
    }
  }

  /// Where one path puts the project, with the folders read the way the panel lists them.
  ///
  /// The folders are resolved and the name is not. `/tmp` is a link to `/private/tmp` on this Mac,
  /// and a column lists what a link resolves to, so a walk of `/tmp` would find no `tmp` in the
  /// first column. There is nothing to resolve in the name, because the project is not on disk yet.
  public func destination(of path: String) throws -> Destination {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    guard !name.isEmpty, name != "/" else {
      throw Refusal(
        reason: "--path names the file the project goes into, and \(path) names a folder.",
        code: .invalidArgument)
    }
    let folder = try resolve(url.deletingLastPathComponent().path)
    let folders = folder.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    return Destination(folders: folders, name: name)
  }

  /// Writes the open project to one path, and answers once Logic has closed the panel.
  ///
  /// The panel carries no field for a path. A value written into the name field is read as a name,
  /// so a path there becomes one project whose name carries a colon for every slash, in the folder
  /// the panel was showing. Measured on this Mac at 12:46 on 2026-09-26: a path in that field made
  /// a project called `:private:tmp:logicctl-probe:np79.logicx` in the music folder.
  ///
  /// So the route walks the columns of the panel, one folder of the path per column, and the field
  /// takes the name of the project on its own. The folder is read back after each open. An open
  /// that landed somewhere else would leave the project in that folder under the right name, and no
  /// read of the name afterwards would catch it.
  ///
  /// Measured on this Mac at 15:30 on 2026-09-26, and this is what shapes the walk. The panel opens
  /// wherever it likes, and `AXOpen` on a row of an earlier column does nothing, so the route moves
  /// the panel to the start up disk first, which leaves exactly one column. `AXOpen` reaches a row
  /// of the last column, and only while that row is in view, so the place of the row goes into the
  /// scroll bar of that column first. Setting `AXSelected` on a row is refused, and setting
  /// `AXSelectedChildren` of the list of a column changes nothing, so neither is a way in.
  ///
  /// A folder the column does not list stops the route before it writes anything. The route closes
  /// the panel and names that folder. The project stays where it is.
  public func save(
    toPath path: String,
    limitMs: Int = Wait.defaultLimitMs,
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds
  ) throws {
    let destination = try self.destination(of: path)
    try openTheMenuItem()
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      try showsThePanel()
    }
    do {
      try press(Locators.saveWherePopup)
      try pressItem(startUpDisk())
      for (number, folder) in destination.folders.enumerated() {
        let listed = try namesInColumn(number)
        guard let row = listed.firstIndex(of: folder) else {
          throw Refusal(
            reason: "Column \(number + 1) of the Save panel does not list \(folder). The walk to "
              + "\(path) stopped, and nothing was written.",
            code: .invalidArgument)
        }
        if let place = SaveDialog.place(ofRow: row, of: listed.count) {
          try scroll(number, place)
        }
        try openFolder(number, folder)
        try reach(folder, ofPath: path, limitMs: limitMs, clock: clock, sleeper: sleeper)
      }
      try write(Locators.saveNameField, destination.name)
      try press(Locators.saveButton)
      try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
        let showing = try showsThePanel()
        return !showing
      }
    } catch {
      closeThePanel()
      throw error
    }
  }

  /// Where the scroll bar of a column has to sit for one row of that column to be in view.
  ///
  /// Measured on this Mac at 15:30 on 2026-09-26: the folder at row 14 of the 22 in the home folder
  /// did not open until the scroll bar of its column was set to (14 - 1) / (22 - 1). The rows are
  /// counted from 0 here, so the first row is 0 and the last is 1.
  ///
  /// A column of one row needs no scroll, and the division has nothing to divide by, so it answers
  /// nothing. A row that is not in the column answers nothing either.
  public static func place(ofRow row: Int, of count: Int) -> Double? {
    guard count > 1, row >= 0, row < count else {
      return nil
    }
    return Double(row) / Double(count - 1)
  }

  /// Waits for the Where popup to show one folder, and fails with `timeout` when it never does.
  ///
  /// The action that opens a folder answers -25205 while it opens the folder all the same, so what
  /// the action answered is no evidence. The popup is, and it moves some time after the open, as
  /// every other read of Logic does. A panel that never shows the folder cannot be walked any
  /// further, and the reason names that folder because it is where a person picks the walk up.
  private func reach(
    _ folder: String,
    ofPath path: String,
    limitMs: Int,
    clock: @escaping Wait.Clock,
    sleeper: @escaping Wait.Sleeper
  ) throws {
    do {
      try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
        try folderShown() == folder
      }
    } catch let ranOut as Wait.RanOut {
      throw Refusal(
        reason: "The Save panel did not reach \(folder) within \(ranOut.waitedMs)ms. The walk to "
          + "\(path) stopped, and nothing was written.",
        code: .timeout)
    }
  }

  /// Closes the panel, which every failure after it opened would otherwise leave standing.
  ///
  /// Measured on this Mac at 15:00 on 2026-09-26: a failure inside the walk left the panel open
  /// over the project, so the next command read a Logic with a panel on it and stopped with
  /// `dialog_open`. What the press answers is not read, because the failure a person acts on is the
  /// one from the walk and a Cancel that Logic refused does not replace it.
  private func closeThePanel() {
    _ = try? press(Locators.saveCancelButton)
  }
}

extension SaveDialog {
  /// The Logic of this Mac, asked through its menu bar and driven through the Accessibility tree.
  public static func live() -> SaveDialog {
    SaveDialog(
      openTheMenuItem: SaveDialog.askTheLogicOfThisMacToSaveAs,
      showsThePanel: SaveDialog.theLogicOfThisMacShowsThePanel,
      write: SaveDialog.writeIntoTheLogicOfThisMac,
      press: SaveDialog.pressInTheLogicOfThisMac,
      resolve: SaveDialog.resolveOnThisMac,
      namesInColumn: SaveDialog.theNamesInTheColumnOfThisMac,
      openFolder: SaveDialog.openTheFolderInTheLogicOfThisMac,
      folderShown: SaveDialog.theFolderTheLogicOfThisMacShows,
      pressItem: SaveDialog.pressTheOpenMenuItemOfThisMac,
      startUpDisk: SaveDialog.theStartUpDiskOfThisMac,
      scroll: SaveDialog.scrollTheColumnOfThisMac)
  }

  /// What the menu item of Logic is called, under the File menu.
  ///
  /// The ellipsis is one character and not three full stops. A menu of macOS carries the one
  /// character, so a search for three would find nothing.
  public static let menuItemTitle = "Save As\u{2026}"

  /// The menu that the item sits under.
  public static let menuTitle = "File"

  /// Asks the Logic of this Mac for File, "Save As...".
  public static func askTheLogicOfThisMacToSaveAs() throws {
    guard let logic = try AXDriver.treeOfRunningLogic() else {
      throw DriverRefusal.logicNotRunning
    }
    let item = try SaveDialog.menuItem(in: logic.root)
    try SaveDialog.askToPress(item, named: menuItemTitle)
  }

  /// The menu item File, "Save As..." of one tree.
  ///
  /// The menu bar of an application is not part of any window, so this walk starts at the
  /// application. Every other walk of logicctl starts at a window and is a locator of
  /// `Locators.swift`, and a recorded tree of a window cannot hold this one.
  public static func menuItem(in application: any AXNode) throws -> any AXNode {
    guard let bar = application.children.first(where: { $0.role == "AXMenuBar" }) else {
      throw Refusal(reason: "Logic shows no menu bar, so \(menuItemTitle) could not be pressed.")
    }
    let file = bar.children.first { $0.role == "AXMenuBarItem" && $0.title == menuTitle }
    guard let menu = file?.children.first(where: { $0.role == "AXMenu" }) else {
      throw Refusal(reason: "Logic shows no \(menuTitle) menu, so \(menuItemTitle) is not there.")
    }
    let found = menu.children.filter { $0.title == menuItemTitle }
    guard found.count == 1, let item = found.first else {
      let says = "the \(menuTitle) menu of Logic carries \(found.count) items called "
      throw Refusal(reason: says + menuItemTitle + ".")
    }
    return item
  }

  /// True while the Logic of this Mac shows the panel that asks where the project goes.
  public static func theLogicOfThisMacShowsThePanel() throws -> Bool {
    guard let front = try AXDriver.treeOfRunningLogic()?.atTheFrontWindow() else {
      return false
    }
    return SaveDialog.isThePanel(front.root)
  }

  /// True when one element is the panel.
  ///
  /// The panel carries an identifier of its own, and no other window of Logic carries it, so the
  /// walk that finds it is the whole of the question.
  public static func isThePanel(_ root: any AXNode) -> Bool {
    (try? LocatorResolver.element(of: Locators.saveWindow, in: root)) != nil
  }

  /// Writes one text into the field a locator names, in the window Logic shows in front.
  public static func writeIntoTheLogicOfThisMac(_ locator: Locator, _ text: String) throws {
    let element = try SaveDialog.liveElement(of: locator)
    let answered = AXUIElementSetAttributeValue(
      element, kAXValueAttribute as CFString, text as CFTypeRef)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused the write into \(locator.name), error \(answered.rawValue).",
        code: .internalFailure)
    }
  }

  /// Presses the element one locator names, in the window Logic shows in front.
  ///
  /// A press through Accessibility is not a mouse event, so it does not go through the input gate.
  /// The gate exists because a posted click lands wherever the pointer is, and this asks the one
  /// element the walk found to act on itself.
  public static func pressInTheLogicOfThisMac(_ locator: Locator) throws {
    let element = try LocatorResolver.element(of: locator, in: SaveDialog.frontWindow())
    try SaveDialog.askToPress(element, named: locator.name)
  }

  /// Asks one element of the running Logic to press itself.
  private static func askToPress(_ element: any AXNode, named name: String) throws {
    guard let live = element as? LiveAXNode else {
      throw Refusal(
        reason: "\(name) was found in a recorded tree, which nothing can press.",
        code: .internalFailure)
    }
    let answered = AXUIElementPerformAction(live.element, kAXPressAction as CFString)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused the press of \(name), error \(answered.rawValue).",
        code: .internalFailure)
    }
  }

  /// The element of the running Logic that one locator names.
  private static func liveElement(of locator: Locator) throws -> AXUIElement {
    let found = try LocatorResolver.element(of: locator, in: SaveDialog.frontWindow())
    guard let live = found as? LiveAXNode else {
      throw Refusal(
        reason: "\(locator.name) was found in a recorded tree, which nothing can drive.",
        code: .internalFailure)
    }
    return live.element
  }

  /// The window the Logic of this Mac shows in front.
  ///
  /// This reader waits on a panel, and Logic puts a panel in front of the project window, so the
  /// window in front is the one to read here and the project window is not.
  private static func frontWindow() throws -> any AXNode {
    guard let front = try AXDriver.treeOfRunningLogic()?.atTheFrontWindow() else {
      throw Refusal(reason: "Logic shows no window, so nothing in it could be reached.")
    }
    return front.root
  }
}

extension SaveDialog {
  /// The action the name of a folder carries to move the panel into that folder.
  public static let openAction = "AXOpen"

  /// The names one column of the browser lists, in a tree of the panel.
  ///
  /// A row of a column is an `AXGroup` that holds an image and a text field, and the name is the
  /// value of that field. Measured on Logic 12.3.1 on 2026-09-26: the field carries `AXOpen`,
  /// `AXShowMenu` and `AXConfirm`, and the group carries no action at all. So the field is what the
  /// walk reads and what it opens, and a row that holds no such field holds no name.
  public static func names(inColumnNumbered number: Int, of panel: any AXNode) throws -> [String] {
    let column = try LocatorResolver.element(of: Locators.saveColumn(number: number), in: panel)
    return column.children.compactMap { SaveDialog.nameShown(by: $0) }
  }

  /// The field that holds the name of one row of a column, which is the element `AXOpen` acts on.
  public static func nameField(
    of name: String, inColumnNumbered number: Int, of panel: any AXNode
  ) throws -> any AXNode {
    let column = try LocatorResolver.element(of: Locators.saveColumn(number: number), in: panel)
    let rows = column.children.filter { SaveDialog.nameShown(by: $0) == name }
    guard rows.count == 1, let row = rows.first else {
      throw Refusal(
        reason: "Column \(number + 1) of the Save panel lists \(rows.count) rows called \(name).")
    }
    guard let field = SaveDialog.nameOf(row) else {
      throw Refusal(reason: "The row called \(name) in the Save panel shows no name to open.")
    }
    return field
  }

  /// The name a row of a column shows, or nothing when it shows none.
  static func nameShown(by row: any AXNode) -> String? {
    SaveDialog.nameOf(row)?.value
  }

  /// The field of a row that carries its name, which is the one that can be opened.
  private static func nameOf(_ row: any AXNode) -> (any AXNode)? {
    row.children.first { $0.actions.contains(SaveDialog.openAction) }
  }
}

extension SaveDialog {
  /// The path with every symbolic link resolved, which is the path the panel shows.
  static func resolveOnThisMac(_ path: String) throws -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  /// The names the column at this number lists, in the panel Logic shows in front.
  static func theNamesInTheColumnOfThisMac(_ number: Int) throws -> [String] {
    try SaveDialog.names(inColumnNumbered: number, of: SaveDialog.frontWindow())
  }

  /// Opens one folder of a column, through the `AXOpen` action of the field that holds its name.
  static func openTheFolderInTheLogicOfThisMac(_ number: Int, _ name: String) throws {
    let field = try SaveDialog.nameField(
      of: name, inColumnNumbered: number, of: SaveDialog.frontWindow())
    guard let live = field as? LiveAXNode else {
      throw Refusal(
        reason: "\(name) was found in a recorded tree, which nothing can open.",
        code: .internalFailure)
    }
    let answered = AXUIElementPerformAction(live.element, SaveDialog.openAction as CFString)
    guard answered == .success || SaveDialog.opensAnyway(answered.rawValue) else {
      throw Refusal(
        reason: "Logic refused to open \(name) in the Save panel, error \(answered.rawValue).",
        code: .internalFailure)
    }
  }

  /// Whether one answer from `AXOpen` says nothing about whether the folder opened.
  ///
  /// Measured on this Mac at 15:00 on 2026-09-26, Logic 12.3.1: the action answers -25205 on the
  /// name of a folder in a column, and the panel opens that folder all the same. AppleScript hides
  /// the number, so a probe through it reads the open as clean. The value of the Where popup says
  /// where the panel got to, and this one answer is not a refusal. Every other one is.
  public static func opensAnyway(_ code: Int32) -> Bool {
    code == AXError.attributeUnsupported.rawValue
  }

  /// Presses the item of the menu the Where popup opened, by its title.
  ///
  /// The menu of macOS exists only while the process that opened it holds it open, so the press of
  /// the popup and this walk run in one process.
  static func pressTheOpenMenuItemOfThisMac(_ title: String) throws {
    let popup = try LocatorResolver.element(
      of: Locators.saveWherePopup, in: SaveDialog.frontWindow())
    guard let menu = popup.children.first(where: { $0.role == "AXMenu" }) else {
      throw Refusal(reason: "The Where popup of the Save panel opened no menu.")
    }
    let found = menu.children.filter { $0.title == title }
    guard found.count == 1, let item = found.first else {
      throw Refusal(
        reason: "The Where popup of the Save panel offers \(found.count) items called \(title).")
    }
    try SaveDialog.askToPress(item, named: title)
  }

  /// What the start up disk of this Mac is called, which is what the Where popup calls its root.
  ///
  /// It is read rather than written down, because the name belongs to the Mac: a disk called
  /// something else would leave the route pressing an item the menu does not carry.
  static func theStartUpDiskOfThisMac() throws -> String {
    let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
    guard let name = values.volumeLocalizedName else {
      throw Refusal(
        reason: "This Mac does not say what its start up disk is called, so the Save panel could "
          + "not be moved to it.")
    }
    return name
  }

  /// Puts the rows of one column of this Mac in view, at a place from 0 at the top to 1 at the end.
  static func scrollTheColumnOfThisMac(_ number: Int, _ place: Double) throws {
    let bar = try LocatorResolver.element(
      of: Locators.saveColumnScrollBar(number: number), in: SaveDialog.frontWindow())
    guard let live = bar as? LiveAXNode else {
      throw Refusal(
        reason: "The scroll bar of column \(number + 1) was read from a recorded tree, which "
          + "nothing can scroll.",
        code: .internalFailure)
    }
    let answered = AXUIElementSetAttributeValue(
      live.element, kAXValueAttribute as CFString, place as CFTypeRef)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused to scroll column \(number + 1) of the Save panel to \(place), error "
          + "\(answered.rawValue).",
        code: .internalFailure)
    }
  }

  /// Which folder the panel of this Mac reached, as the Where popup shows it.
  static func theFolderTheLogicOfThisMacShows() throws -> String {
    let popup = try LocatorResolver.element(
      of: Locators.saveWherePopup, in: SaveDialog.frontWindow())
    guard let shown = popup.value else {
      throw Refusal(reason: "The Where popup of the Save panel says no folder.")
    }
    return shown
  }
}
