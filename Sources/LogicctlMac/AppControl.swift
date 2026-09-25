import AppKit
import ApplicationServices
import Foundation
import LogicctlCore

/// The Logic that macOS has open, read without opening a project.
///
/// `launch` asks two things of the Logic it started: which process it is, and whether it has drawn
/// its window yet. The two travel together because the process id of a Logic that shows no window
/// is the process id of a Logic nothing can be asked of, and a command that answered there would
/// hand its caller a Logic the next command cannot read.
public struct RunningLogic: Equatable, Sendable {
  /// The process id of Logic.
  public let processID: Int32

  /// True once Logic shows a window.
  public let showsAWindow: Bool

  public init(processID: Int32, showsAWindow: Bool) {
    self.processID = processID
    self.showsAWindow = showsAWindow
  }
}

/// Starts Logic on this Mac, and reads back whether it is there yet.
///
/// Both operations are closures the caller gives. The pipeline has no Logic and no window server,
/// so a test drives the same command with a Logic of its own and macOS opens nothing.
public struct AppControl {
  /// Why this Mac gave no Logic. The reason reaches the answer of the command, so a person reads
  /// what macOS refused without going to look for a log.
  public struct Refusal: Error, Equatable, Sendable {
    /// One short reason, in the words of the Mac that refused.
    public let reason: String

    public init(reason: String) {
      self.reason = reason
    }
  }

  /// Asks macOS to start Logic. It answers nothing, because the window comes later and the caller
  /// reads for it.
  public typealias Start = () throws -> Void

  /// The Logic that runs now, or nothing when none runs.
  public typealias Read = () throws -> RunningLogic?

  /// Starts Logic.
  public let start: Start

  /// Reads the Logic that runs.
  public let read: Read

  /// Asks Logic to close. Logic refuses while the project has unsaved changes.
  public let close: Ask

  /// Ends Logic and everything it has not written to disk.
  public let end: Ask

  /// Writes the project where it already sits.
  public let save: Ask

  public init(
    start: @escaping Start,
    read: @escaping Read,
    close: @escaping Ask = AppControl.noWay(to: "close Logic"),
    end: @escaping Ask = AppControl.noWay(to: "end Logic"),
    save: @escaping Ask = AppControl.noWay(to: "save the project")
  ) {
    self.start = start
    self.read = read
    self.close = close
    self.end = end
    self.save = save
  }
}

extension AppControl {
  /// The Logic of this Mac, started and read through macOS.
  public static func live() -> AppControl {
    AppControl(
      start: AppControl.startTheLogicOfThisMac,
      read: AppControl.readTheLogicOfThisMac,
      close: AppControl.askTheLogicOfThisMacToClose,
      end: AppControl.endTheLogicOfThisMac,
      save: AppControl.askTheLogicOfThisMacToSave)
  }

  /// Asks macOS to start Logic, and refuses when macOS will not.
  ///
  /// A Logic that already runs is brought to the front rather than started a second time, which is
  /// what `launch` wants: one command, one Logic, whatever was open when it ran.
  public static func startTheLogicOfThisMac() throws {
    let installed = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: LogicTree.bundleIdentifier)
    guard let bundle = installed else {
      let named = LogicTree.bundleIdentifier
      throw Refusal(reason: "no application on this Mac carries the bundle identifier \(named)")
    }
    guard NSWorkspace.shared.open(bundle) else {
      throw Refusal(reason: "macOS refused to start \(bundle.path)")
    }
  }

  /// The Logic that runs on this Mac, or nothing when none runs.
  ///
  /// The process id comes from the application macOS has open, and the window comes from the
  /// Accessibility tree, which is the same read `status` answers the window with. A Logic that
  /// grants nothing reads as a Logic with no window, so the wait ends with `timeout` rather than
  /// with an answer a later command cannot use.
  public static func readTheLogicOfThisMac() throws -> RunningLogic? {
    let open = NSRunningApplication.runningApplications(
      withBundleIdentifier: LogicTree.bundleIdentifier)
    guard let logic = open.first else {
      return nil
    }
    let tree = try AXDriver.treeOfRunningLogic()
    return RunningLogic(
      processID: logic.processIdentifier, showsAWindow: tree?.atTheFrontWindow() != nil)
  }
}

extension AppControl {
  /// Asks macOS or Logic to do one thing. It answers nothing, because what came of it is read
  /// back afterwards.
  public typealias Ask = () throws -> Void

  /// What a control that carries no way to close Logic refuses with.
  ///
  /// The two closes and the save are given by the caller, so a control built for another command
  /// answers here rather than closing something nobody asked it to close.
  public static func noWay(to thing: String) -> Ask {
    { throw Refusal(reason: "This control carries no way to \(thing).") }
  }

  /// Asks Logic to close, which Logic can refuse.
  ///
  /// A project with unsaved changes holds the request and asks the person what to do, so Logic is
  /// still running when the read after it says so. That refusal is the whole of `quit`.
  public static func askTheLogicOfThisMacToClose() throws {
    guard let logic = AppControl.theLogicOfThisMac() else {
      throw DriverRefusal.logicNotRunning
    }
    guard logic.terminate() else {
      throw Refusal(reason: "macOS refused to close Logic.")
    }
  }

  /// Ends Logic, whatever it has open. Every change since the last save goes with it.
  ///
  /// This asks no question and takes no answer, which is why the command that reaches it needs
  /// `--confirm` from the person who typed it.
  public static func endTheLogicOfThisMac() throws {
    guard let logic = AppControl.theLogicOfThisMac() else {
      throw DriverRefusal.logicNotRunning
    }
    guard logic.forceTerminate() else {
      throw Refusal(reason: "macOS refused to end Logic.")
    }
  }

  /// Presses File, Save in the menu bar of Logic, which writes the project where it already sits.
  ///
  /// Save As opens a panel and needs a path. Save writes in place and opens nothing, so a project
  /// that has a path is on disk when this answers. A project that has none would bring the panel
  /// up instead, and the command stops before it reaches here for exactly that reason.
  public static func askTheLogicOfThisMacToSave() throws {
    guard let logic = try AXDriver.treeOfRunningLogic() else {
      throw DriverRefusal.logicNotRunning
    }
    let item = try AppControl.saveMenuItem(in: logic.root)
    guard let live = item as? LiveAXNode else {
      throw Refusal(reason: "\(AppControl.saveItemTitle) was found in a tree nothing can press.")
    }
    let answered = AXUIElementPerformAction(live.element, kAXPressAction as CFString)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused the press of \(AppControl.saveItemTitle), "
          + "error \(answered.rawValue).")
    }
  }

  /// The menu that holds the item, as Logic titles it.
  public static let saveMenuTitle = "File"

  /// The item that writes the project where it already sits, as Logic titles it.
  public static let saveItemTitle = "Save"

  /// The menu item File, Save of one tree.
  ///
  /// The menu bar of an application is not part of any window, so this walk starts at the
  /// application rather than at a locator: a locator walks a window, and a recorded tree of a
  /// window cannot hold this one. The walk takes the item whose title is exactly `Save`, so
  /// `Save As...` and `Save a Copy As...`, which both start with the same word, are not it.
  public static func saveMenuItem(in application: any AXNode) throws -> any AXNode {
    guard let bar = application.children.first(where: { $0.role == "AXMenuBar" }) else {
      throw Refusal(reason: "Logic shows no menu bar, so \(saveItemTitle) could not be pressed.")
    }
    let file = bar.children.first { $0.role == "AXMenuBarItem" && $0.title == saveMenuTitle }
    guard let menu = file?.children.first(where: { $0.role == "AXMenu" }) else {
      throw Refusal(
        reason: "Logic shows no \(saveMenuTitle) menu, so \(saveItemTitle) is not there.")
    }
    let found = menu.children.filter { $0.title == saveItemTitle }
    guard found.count == 1, let item = found.first else {
      throw Refusal(
        reason: "the \(saveMenuTitle) menu of Logic carries \(found.count) items called "
          + saveItemTitle + ".")
    }
    return item
  }

  /// The Logic that macOS has open, or nothing when none runs.
  static func theLogicOfThisMac() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: LogicTree.bundleIdentifier)
      .first
  }
}
