import ApplicationServices
import Foundation
import LogicctlCore

/// The real path of a file, as the Import panel of Logic walks it.
///
/// The panel carries no field for a path, so the route cannot hand Logic a path in one write. It
/// moves the panel to the start up disk and opens one folder at a time, which is why the folders
/// are kept apart from the name here.
public struct ImportPath: Equatable, Sendable {
  /// The path with every symbolic link resolved, which is the path the panel shows.
  public let resolved: String

  /// The folders of the resolved path, from the start up disk down, without the file.
  public let folders: [String]

  /// The name of the file, which is the row the route selects.
  public let name: String

  public init(resolved: String, folders: [String], name: String) {
    self.resolved = resolved
    self.folders = folders
    self.name = name
  }
}

/// What logicctl reads about the file before it asks Logic for anything.
///
/// The reads are closures the caller gives, as they are for `SaveDialog`, so a test drives the
/// whole of this with no Mac and nothing on the disk of the pipeline.
public struct ImportFile {
  /// Why the file cannot be imported. This comes before Logic, so it carries `invalid_argument`
  /// and the command writes no step.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// One short reason, which names the path or the folder it stopped at.
    public let reason: String

    /// The code a caller reads and exits with.
    public let code: ErrorCode

    public init(reason: String, code: ErrorCode = .invalidArgument) {
      self.reason = reason
      self.code = code
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(code: code, message: reason, details: .object(["field": .string("--file")]))
    }
  }

  /// The path with every symbolic link resolved.
  public typealias Resolve = (String) throws -> String

  /// Whether a folder is hidden, which is the `isHidden` resource value of it.
  public typealias Hidden = (String) throws -> Bool

  /// The bytes of the file.
  public typealias Read = (String) throws -> Data

  /// Resolves a path.
  public let resolve: Resolve

  /// Reads whether a folder is hidden.
  public let hidden: Hidden

  /// Reads the bytes of the file.
  public let read: Read

  public init(resolve: @escaping Resolve, hidden: @escaping Hidden, read: @escaping Read) {
    self.resolve = resolve
    self.hidden = hidden
    self.read = read
  }

  /// What logicctl knows about the file before Logic is asked anything.
  public struct Facts: Equatable, Sendable {
    /// Where the file is, as the panel walks it.
    public let path: ImportPath

    /// The hash of the bytes, in hexadecimal. It is the same hash `midi write-file` prints for
    /// the same bytes, so an agent that wrote a file recognises it here.
    public let sha256: String

    public init(path: ImportPath, sha256: String) {
      self.path = path
      self.sha256 = sha256
    }
  }
}

extension ImportFile {
  /// Reads the path and the bytes, and refuses a path the panel cannot walk.
  ///
  /// The panel of macOS lists visible folders alone, so a file under a hidden folder cannot be
  /// reached by opening one row at a time. `/tmp` resolves to `/private/tmp`, and `/private` is
  /// hidden, so a file left in `/tmp` fails here. The message names the folder, because the fix is
  /// to move the file rather than to change the command.
  ///
  /// Every refusal happens before Logic is asked anything, so the project does not change and the
  /// session gains no step.
  public func facts(of typed: String) throws -> Facts {
    let resolved = try resolve(typed)
    let parts = ImportFile.parts(of: resolved)
    guard let name = parts.last, !name.isEmpty else {
      throw Refusal(reason: "--file must name a file, and \(typed) names a folder.")
    }
    let folders = Array(parts.dropLast())
    for folder in ImportFile.foldersOnTheWay(to: folders) {
      guard try hidden(folder) == false else {
        throw Refusal(
          reason: "\(folder) is a hidden folder, and the Import panel of Logic lists visible "
            + "folders alone. Move the file to a visible folder and run the command again.")
      }
    }
    let bytes = try read(resolved)
    return Facts(
      path: ImportPath(resolved: resolved, folders: folders, name: name),
      sha256: ImportFile.sha256(of: bytes))
  }

  /// The parts of a path, with the empty ones left out, so `/Users/a/notes.mid` reads as three.
  static func parts(of path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  }

  /// Every folder on the way down, as a path, so a refusal names `/private` and not `private`.
  static func foldersOnTheWay(to folders: [String]) -> [String] {
    var walked: [String] = []
    var here = ""
    for folder in folders {
      here += "/" + folder
      walked.append(here)
    }
    return walked
  }

  /// The hash of some bytes, in hexadecimal.
  static func sha256(of bytes: Data) -> String {
    MidiFile.sha256(of: [UInt8](bytes))
  }
}

extension ImportFile {
  /// The disk of this Mac, read through Foundation.
  public static func live() -> ImportFile {
    ImportFile(
      resolve: ImportFile.resolveOnThisMac,
      hidden: ImportFile.isHiddenOnThisMac,
      read: ImportFile.readFromThisMac)
  }

  /// The path with every symbolic link resolved, which is the path the panel of Logic shows.
  static func resolveOnThisMac(_ path: String) throws -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  /// Whether one folder is hidden, from the resource value the file system carries.
  ///
  /// A folder that cannot be read is not hidden as far as this answers: the walk of the panel
  /// fails at that folder and says which one, which is a better answer than a guess here.
  static func isHiddenOnThisMac(_ path: String) throws -> Bool {
    let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isHiddenKey])
    return values?.isHidden ?? false
  }

  /// The bytes of the file, or a refusal naming what the disk said.
  static func readFromThisMac(_ path: String) throws -> Data {
    do {
      return try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw Refusal(
        reason: "--file must name a file that can be read: \(error.localizedDescription)")
    }
  }

  /// The name of the start up disk, which is what the Where popup calls the volume of `/`.
  ///
  /// It is read rather than written down, because the name belongs to the Mac: a disk called
  /// something else would leave the route pressing a menu item that is not there.
  public static func startUpDiskOfThisMac() throws -> String {
    let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
    guard let name = values.volumeLocalizedName else {
      throw Refusal(
        reason: "This Mac does not say what its start up disk is called, so the Import panel "
          + "cannot be moved to it.", code: .elementNotFound)
    }
    return name
  }
}

/// Imports one MIDI file, through the panel Logic opens for File, Import, "MIDI File...".
///
/// Every operation is a closure the caller gives, as they are for `SaveDialog`. The pipeline has
/// no Logic and no window server, so a test drives the same route with a Logic of its own and
/// macOS opens nothing.
///
/// The panel of Logic 12.3.1 carries no field for a path. So the route moves the panel to the
/// start up disk through the Where popup, and then opens one folder of the path at a time. It
/// reads the popup after each open, because an open that landed somewhere else would leave the
/// route selecting a file of that name in another folder.
///
/// Logic is brought to the front before the walk. Measured on Logic 12.3.1 on 2026-09-25: with
/// Logic behind another application, the file row selects and the Import button stays disabled, so
/// a press of it does nothing and the command would report an import that never happened. The
/// button reads enabled after the application is made frontmost and the panel is raised. The route
/// reads that state after the selection rather than trusting it.
///
/// The panel is the expected answer to the menu item, so nothing reads it as a dialog to stop on.
/// The dialog Logic opens after the import is read by the run of the command, which stops with
/// `dialog_open`.
public struct ImportDialog {
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

  /// Asks Logic for File, Import, "MIDI File...". It answers nothing, because the panel comes
  /// later and the route reads for it.
  public typealias OpenTheMenuItem = () throws -> Void

  /// True while Logic shows the Import panel.
  public typealias Read = () throws -> Bool

  /// Presses the one element a locator names.
  public typealias Press = (Locator) throws -> Void

  /// Brings Logic to the front and raises the panel.
  public typealias BringToFront = () throws -> Void

  /// Whether the one element a locator names is enabled.
  public typealias ReadEnabled = (Locator) throws -> Bool

  /// Presses the item of the open menu whose title is this.
  public typealias PressItem = (String) throws -> Void

  /// Opens the folder of this name in the file list, through the `AXOpen` action of its row.
  public typealias OpenFolder = (String) throws -> Void

  /// The folder the panel is in, as the Where popup shows it.
  public typealias ReadFolder = () throws -> String

  /// The name of the start up disk of this Mac.
  public typealias ReadDisk = () throws -> String

  /// Asks Logic for the menu item.
  public let openTheMenuItem: OpenTheMenuItem

  /// Reads whether Logic shows the panel.
  public let showsThePanel: Read

  /// Presses a control of the panel.
  public let press: Press

  /// Brings Logic to the front and raises the panel.
  public let bringToFront: BringToFront

  /// Reads whether a control of the panel is enabled.
  public let enabled: ReadEnabled

  /// Presses an item of the menu the Where popup opens.
  public let pressItem: PressItem

  /// Opens one folder of the file list.
  public let openFolder: OpenFolder

  /// Reads which folder the panel is in.
  public let folderShown: ReadFolder

  /// Reads what the start up disk is called.
  public let startUpDisk: ReadDisk

  /// Puts the selection of the file list on the one file, and reads it back.
  public let selection: SelectionGuard

  public init(
    openTheMenuItem: @escaping OpenTheMenuItem,
    showsThePanel: @escaping Read,
    press: @escaping Press,
    bringToFront: @escaping BringToFront,
    enabled: @escaping ReadEnabled,
    pressItem: @escaping PressItem,
    openFolder: @escaping OpenFolder,
    folderShown: @escaping ReadFolder,
    startUpDisk: @escaping ReadDisk,
    selection: SelectionGuard
  ) {
    self.openTheMenuItem = openTheMenuItem
    self.showsThePanel = showsThePanel
    self.press = press
    self.bringToFront = bringToFront
    self.enabled = enabled
    self.pressItem = pressItem
    self.openFolder = openFolder
    self.folderShown = folderShown
    self.startUpDisk = startUpDisk
    self.selection = selection
  }
}

extension ImportDialog {
  /// Walks the panel to one file and presses Import.
  ///
  /// It answers once the press is taken. What the press did to the project is read afterwards, by
  /// the command, because a press that Logic accepted and did nothing with is the failure this
  /// whole route exists to catch.
  public func importTheFile(
    at path: ImportPath,
    limitMs: Int = Wait.defaultLimitMs,
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds
  ) throws {
    try openTheMenuItem()
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      try showsThePanel()
    }
    try bringToFront()
    try press(Locators.importWherePopup)
    let disk = try startUpDisk()
    try pressItem(disk)
    for folder in path.folders {
      try openFolder(folder)
      let shown = try folderShown()
      guard shown == folder else {
        throw Refusal(
          reason: "The Import panel was asked for \(folder) and shows \(shown), so the walk to "
            + "\(path.resolved) stopped and nothing was imported.")
      }
    }
    try selection.selectOnly(path.name)
    guard try enabled(Locators.importButton) else {
      throw Refusal(
        reason: "\(path.name) is selected in the Import panel and its OKButton is disabled, so "
          + "Logic would take no press. Bring Logic to the front and run the command again.")
    }
    try press(Locators.importButton)
  }
}

extension ImportDialog {
  /// What the menu item of Logic is called, under Import, under the File menu.
  ///
  /// The ellipsis is one character and not three full stops. A menu of macOS carries the one
  /// character, so a search for three would find nothing.
  public static let menuItemTitle = "MIDI File\u{2026}"

  /// The item of the File menu that the MIDI file item sits under.
  public static let submenuTitle = "Import"

  /// The menu that the submenu sits under.
  public static let menuTitle = "File"
}

extension ImportDialog {
  /// The Logic of this Mac, asked through its menu bar and driven through the Accessibility tree.
  ///
  /// Nothing in the pipeline runs this. It is proved by the live suite of phase 3, against the
  /// Logic of the Mac that logicctl drives.
  public static func live() -> ImportDialog {
    ImportDialog(
      openTheMenuItem: ImportDialog.askTheLogicOfThisMacToImportAMidiFile,
      showsThePanel: ImportDialog.theLogicOfThisMacShowsThePanel,
      press: ImportDialog.pressInTheLogicOfThisMac,
      bringToFront: ImportDialog.bringTheLogicOfThisMacToTheFront,
      enabled: ImportDialog.isEnabledInTheLogicOfThisMac,
      pressItem: ImportDialog.pressTheOpenMenuItemOfThisMac,
      openFolder: ImportDialog.openTheFolderInTheLogicOfThisMac,
      folderShown: ImportDialog.theFolderTheLogicOfThisMacShows,
      startUpDisk: ImportFile.startUpDiskOfThisMac,
      selection: ImportDialog.theFileListOfThisMac())
  }

  /// Asks the Logic of this Mac for File, Import, "MIDI File...".
  static func askTheLogicOfThisMacToImportAMidiFile() throws {
    guard let logic = try AXDriver.treeOfRunningLogic() else {
      throw DriverRefusal.logicNotRunning
    }
    let item = try ImportDialog.menuItem(in: logic.root)
    try ImportDialog.askToPress(item, named: menuItemTitle)
  }

  /// The menu item File, Import, "MIDI File..." of one tree.
  ///
  /// The menu bar of an application is not part of any window, so this walk starts at the
  /// application and is not a locator of `Locators.swift`: a recorded tree of a window cannot hold
  /// it. The walk goes one level deeper than the walk to "Save As...", because Import is a submenu
  /// and the MIDI file item sits inside it.
  public static func menuItem(in application: any AXNode) throws -> any AXNode {
    guard let bar = application.children.first(where: { $0.role == "AXMenuBar" }) else {
      throw Refusal(reason: "Logic shows no menu bar, so \(menuItemTitle) could not be pressed.")
    }
    let file = bar.children.first { $0.role == "AXMenuBarItem" && $0.title == menuTitle }
    guard let menu = file?.children.first(where: { $0.role == "AXMenu" }) else {
      throw Refusal(reason: "Logic shows no \(menuTitle) menu, so \(submenuTitle) is not there.")
    }
    let submenu = menu.children.first { $0.title == submenuTitle }
    guard let items = submenu?.children.first(where: { $0.role == "AXMenu" }) else {
      throw Refusal(
        reason: "The \(menuTitle) menu of Logic shows no \(submenuTitle) submenu, so "
          + menuItemTitle + " is not there.")
    }
    let found = items.children.filter { $0.title == menuItemTitle }
    guard found.count == 1, let item = found.first else {
      let says = "the \(submenuTitle) submenu of Logic carries \(found.count) items called "
      throw Refusal(reason: says + menuItemTitle + ".")
    }
    return item
  }

  /// True while the Logic of this Mac shows the Import panel.
  static func theLogicOfThisMacShowsThePanel() throws -> Bool {
    guard let front = try AXDriver.treeOfRunningLogic()?.atTheFrontWindow() else {
      return false
    }
    return (try? LocatorResolver.element(of: Locators.importWindow, in: front.root)) != nil
  }

  /// Presses the element one locator names, in the panel Logic shows in front.
  static func pressInTheLogicOfThisMac(_ locator: Locator) throws {
    let element = try LocatorResolver.element(of: locator, in: ImportDialog.frontWindow())
    try ImportDialog.askToPress(element, named: locator.name)
  }

  /// Presses the item of the menu the Where popup opened, by its title.
  ///
  /// The menu exists only while the process that opened it holds it open, which the plugin menu of
  /// phase 4 is already known for, so the press of the popup and this walk run in one process.
  static func pressTheOpenMenuItemOfThisMac(_ title: String) throws {
    let popup = try LocatorResolver.element(
      of: Locators.importWherePopup, in: ImportDialog.frontWindow())
    guard let menu = popup.children.first(where: { $0.role == "AXMenu" }) else {
      throw Refusal(reason: "The Where popup of the Import panel opened no menu.")
    }
    let found = menu.children.filter { $0.title == title }
    guard found.count == 1, let item = found.first else {
      throw Refusal(
        reason: "The Where popup of the Import panel offers \(found.count) items called \(title).")
    }
    try ImportDialog.askToPress(item, named: title)
  }

  /// Opens one folder of the file list, through the `AXOpen` action of the name of its row.
  static func openTheFolderInTheLogicOfThisMac(_ name: String) throws {
    let row = try ImportDialog.nameOfTheRow(called: name)
    guard let live = row as? LiveAXNode else {
      throw Refusal(
        reason: "\(name) was found in a recorded tree, which nothing can open.",
        code: .internalFailure)
    }
    let answered = AXUIElementPerformAction(live.element, ImportDialog.openAction as CFString)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused to open \(name) in the Import panel, error \(answered.rawValue).",
        code: .internalFailure)
    }
  }

  /// Which folder the panel of this Mac is in, as the Where popup shows it.
  static func theFolderTheLogicOfThisMacShows() throws -> String {
    let popup = try LocatorResolver.element(
      of: Locators.importWherePopup, in: ImportDialog.frontWindow())
    guard let shown = popup.value else {
      throw Refusal(reason: "The Where popup of the Import panel says no folder.")
    }
    return shown
  }

  /// The file list of the panel of this Mac, as a guard that selects one row and reads it back.
  static func theFileListOfThisMac() -> SelectionGuard {
    SelectionGuard(
      select: { names in
        for name in names {
          try ImportDialog.selectInTheLogicOfThisMac(name)
        }
      },
      selection: ImportDialog.theSelectionOfTheFileListOfThisMac)
  }

  /// Selects one row of the file list, by the name it shows.
  static func selectInTheLogicOfThisMac(_ name: String) throws {
    let row = try ImportDialog.rowOfTheFileList(called: name)
    guard let live = row as? LiveAXNode else {
      throw Refusal(
        reason: "\(name) was found in a recorded tree, which nothing can select.",
        code: .internalFailure)
    }
    let answered = AXUIElementSetAttributeValue(
      live.element, kAXSelectedAttribute as CFString, true as CFTypeRef)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused to select \(name) in the Import panel, error \(answered.rawValue).",
        code: .internalFailure)
    }
  }

  /// The names of the rows the file list of this Mac reports as selected.
  static func theSelectionOfTheFileListOfThisMac() throws -> [String] {
    let outline = try ImportDialog.fileList()
    guard let live = outline as? LiveAXNode else {
      throw Refusal(
        reason: "The file list was found in a recorded tree, which holds no selection.",
        code: .internalFailure)
    }
    var held: CFTypeRef?
    let answered = AXUIElementCopyAttributeValue(
      live.element, kAXSelectedRowsAttribute as CFString, &held)
    guard answered == .success, let rows = held as? [AXUIElement] else {
      throw Refusal(reason: "The file list of the Import panel reported no selection.")
    }
    return rows.compactMap { ImportDialog.nameShown(by: LiveAXNode($0)) }
  }

  /// The row of the file list that shows one name.
  static func rowOfTheFileList(called name: String) throws -> any AXNode {
    let rows = try ImportDialog.fileList().children.filter { $0.role == "AXRow" }
    let found = rows.filter { ImportDialog.nameShown(by: $0) == name }
    guard found.count == 1, let row = found.first else {
      throw Refusal(
        reason: "The Import panel shows \(found.count) rows called \(name) in this folder.")
    }
    return row
  }

  /// The name field of the row that shows one name, which is the element `AXOpen` acts on.
  static func nameOfTheRow(called name: String) throws -> any AXNode {
    let row = try ImportDialog.rowOfTheFileList(called: name)
    guard let field = ImportDialog.nameField(of: row) else {
      throw Refusal(reason: "The row called \(name) in the Import panel shows no name field.")
    }
    return field
  }

  /// The name a row of the file list shows, or nothing when it shows none.
  static func nameShown(by row: any AXNode) -> String? {
    ImportDialog.nameField(of: row)?.value
  }

  /// The field of a row that carries its name, which is the first one that can be opened.
  private static func nameField(of row: any AXNode) -> (any AXNode)? {
    var level: [any AXNode] = row.children
    while !level.isEmpty {
      if let field = level.first(where: { $0.actions.contains(ImportDialog.openAction) }) {
        return field
      }
      level = level.flatMap { $0.children }
    }
    return nil
  }

  /// The outline of the panel that lists the folders and the files of the folder it is in.
  private static func fileList() throws -> any AXNode {
    let front = try ImportDialog.frontWindow()
    guard let outline = ImportDialog.outline(under: front) else {
      throw Refusal(reason: "The Import panel shows no file list.")
    }
    return outline
  }

  /// The first outline the panel carries, looked for a level at a time.
  private static func outline(under node: any AXNode) -> (any AXNode)? {
    var level: [any AXNode] = [node]
    while !level.isEmpty {
      if let found = level.first(where: { $0.identifier == ImportDialog.fileListIdentifier }) {
        return found
      }
      level = level.flatMap { $0.children }
    }
    return nil
  }

  /// The window the Logic of this Mac shows in front, which is the panel once it opens.
  ///
  /// This reader waits on a panel, and Logic puts a panel in front of the project window, so the
  /// window in front is the one to read here and the project window is not.
  private static func frontWindow() throws -> any AXNode {
    guard let front = try AXDriver.treeOfRunningLogic()?.atTheFrontWindow() else {
      throw Refusal(reason: "Logic shows no window, so nothing in it could be reached.")
    }
    return front.root
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

  /// The action a row of the file list carries to move the panel into that folder.
  static let openAction = "AXOpen"

  /// What the panel calls the outline that lists the folders and the files.
  static let fileListIdentifier = "ListView"
}

extension ImportDialog {
  /// Brings Logic to the front and raises the Import panel.
  ///
  /// Logic behind another application takes the selection of a file row and leaves the Import
  /// button disabled, so the press that follows would do nothing at all. This is the one thing
  /// the route does to the Mac that a person sees, and it is what makes the press land.
  static func bringTheLogicOfThisMacToTheFront() throws {
    guard let logic = try AXDriver.treeOfRunningLogic() else {
      throw DriverRefusal.logicNotRunning
    }
    guard let application = logic.root as? LiveAXNode else {
      throw Refusal(
        reason: "Logic was read from a recorded tree, which nothing can bring to the front.",
        code: .internalFailure)
    }
    let answered = AXUIElementSetAttributeValue(
      application.element, kAXFrontmostAttribute as CFString, true as CFTypeRef)
    guard answered == .success else {
      throw Refusal(
        reason: "macOS refused to bring Logic to the front, error \(answered.rawValue).",
        code: .internalFailure)
    }
    let panel = try LocatorResolver.element(
      of: Locators.importWindow, in: ImportDialog.frontWindow())
    guard let window = panel as? LiveAXNode else {
      throw Refusal(
        reason: "The Import panel was read from a recorded tree, which nothing can raise.",
        code: .internalFailure)
    }
    let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    guard raised == .success else {
      throw Refusal(
        reason: "Logic refused to raise the Import panel, error \(raised.rawValue).",
        code: .internalFailure)
    }
  }

  /// Whether the one element a locator names is enabled, in the panel Logic shows in front.
  static func isEnabledInTheLogicOfThisMac(_ locator: Locator) throws -> Bool {
    let element = try LocatorResolver.element(of: locator, in: ImportDialog.frontWindow())
    guard let live = element as? LiveAXNode else {
      throw Refusal(
        reason: "\(locator.name) was found in a recorded tree, which says nothing about Logic.",
        code: .internalFailure)
    }
    var held: CFTypeRef?
    let answered = AXUIElementCopyAttributeValue(
      live.element, kAXEnabledAttribute as CFString, &held)
    guard answered == .success else {
      return false
    }
    return held as? Bool ?? false
  }
}
