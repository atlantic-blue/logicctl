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

  /// Asks Logic for File, "Save As...".
  public let openTheMenuItem: OpenTheMenuItem

  /// Reads whether Logic shows the panel.
  public let showsThePanel: Read

  /// Writes into a field of the panel.
  public let write: Write

  /// Presses a button of the panel.
  public let press: Press

  public init(
    openTheMenuItem: @escaping OpenTheMenuItem,
    showsThePanel: @escaping Read,
    write: @escaping Write,
    press: @escaping Press
  ) {
    self.openTheMenuItem = openTheMenuItem
    self.showsThePanel = showsThePanel
    self.write = write
    self.press = press
  }
}

extension SaveDialog {
  /// Writes the open project to one path, and answers once Logic has closed the panel.
  ///
  /// The path goes into the name field whole. A panel of macOS takes a path in that field, and the
  /// alternative is driving the Where popup and the folder browser under it, which name the
  /// folders of this Mac and not the folder a person typed.
  public func save(
    toPath path: String,
    limitMs: Int = Wait.defaultLimitMs,
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds
  ) throws {
    try openTheMenuItem()
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      try showsThePanel()
    }
    try write(Locators.saveNameField, path)
    try press(Locators.saveButton)
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      let showing = try showsThePanel()
      return !showing
    }
  }
}

extension SaveDialog {
  /// The Logic of this Mac, asked through its menu bar and driven through the Accessibility tree.
  public static func live() -> SaveDialog {
    SaveDialog(
      openTheMenuItem: SaveDialog.askTheLogicOfThisMacToSaveAs,
      showsThePanel: SaveDialog.theLogicOfThisMacShowsThePanel,
      write: SaveDialog.writeIntoTheLogicOfThisMac,
      press: SaveDialog.pressInTheLogicOfThisMac)
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
  private static func frontWindow() throws -> any AXNode {
    guard let front = try AXDriver.treeOfRunningLogic()?.atTheFrontWindow() else {
      throw Refusal(reason: "Logic shows no window, so nothing in it could be reached.")
    }
    return front.root
  }
}
