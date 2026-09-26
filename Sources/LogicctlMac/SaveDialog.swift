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

  public init(
    openTheMenuItem: @escaping OpenTheMenuItem,
    showsThePanel: @escaping Read,
    write: @escaping Write,
    press: @escaping Press,
    resolve: @escaping Resolve,
    namesInColumn: @escaping ReadNames,
    openFolder: @escaping OpenFolder,
    folderShown: @escaping ReadFolder
  ) {
    self.openTheMenuItem = openTheMenuItem
    self.showsThePanel = showsThePanel
    self.write = write
    self.press = press
    self.resolve = resolve
    self.namesInColumn = namesInColumn
    self.openFolder = openFolder
    self.folderShown = folderShown
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
    for (number, folder) in destination.folders.enumerated() {
      guard try namesInColumn(number).contains(folder) else {
        closeThePanel()
        throw Refusal(
          reason: "Column \(number + 1) of the Save panel does not list \(folder). The walk to "
            + "\(path) stopped, and nothing was written.",
          code: .invalidArgument)
      }
      try openFolder(number, folder)
      let shown = try folderShown()
      guard shown == folder else {
        throw Refusal(
          reason: "The Save panel was asked for \(folder) and shows \(shown). The walk to \(path) "
            + "stopped, and nothing was written.")
      }
    }
    try write(Locators.saveNameField, destination.name)
    try press(Locators.saveButton)
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      let showing = try showsThePanel()
      return !showing
    }
  }

  /// Closes the panel, which a refusal inside the walk would leave open.
  ///
  /// What the press answers is not read. The refusal a person acts on names the folder that is not
  /// in the column, and a Cancel that Logic refused does not replace it.
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
      folderShown: SaveDialog.theFolderTheLogicOfThisMacShows)
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
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused to open \(name) in the Save panel, error \(answered.rawValue).",
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
