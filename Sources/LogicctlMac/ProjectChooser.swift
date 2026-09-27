import ApplicationServices
import Foundation
import LogicctlCore

/// What Logic shows in front, read from the window itself.
///
/// Logic has three shapes before a project of a person is being worked on, and a command that told
/// them apart by the title of the window would read a different answer in every language and in
/// every project. So each one is read from an element the window carries.
public enum ProjectWindow: Equatable, Sendable {
  /// The window "Choose a Project". Logic shows it while no project is open.
  case chooser

  /// A project with no tracks. Logic puts the "New Track" sheet on one, both on a project it has
  /// just made and on a project whose last track was deleted. It is a place on the way to a project
  /// and not a place to stop: Logic refuses Save while that sheet is open.
  case emptyProject

  /// A project with tracks in it.
  case project
}

/// Gets Logic from whatever it shows to a project that holds its first track.
///
/// Both operations are closures the caller gives, as they are for `AppControl`. The pipeline has
/// no Logic and no window server, so a test drives the same route with a Logic of its own and
/// macOS opens nothing.
public struct ProjectChooser {
  /// Why the chooser could not be answered. The reason reaches the answer of the command, so a
  /// person reads what Logic refused without going to look for a log.
  public struct Refusal: Error, Equatable, Sendable {
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

  /// What Logic shows in front, or nothing when Logic shows no window at all.
  public typealias Read = () throws -> ProjectWindow?

  /// Presses the one element a locator names.
  public typealias Press = (Locator) throws -> Void

  /// Reads what Logic shows.
  public let read: Read

  /// Presses one element of what Logic shows.
  public let press: Press

  public init(read: @escaping Read, press: @escaping Press) {
    self.read = read
    self.press = press
  }
}

extension ProjectChooser {
  /// Takes Logic to a project that holds its first track, and answers once it is there.
  ///
  /// Logic shows the chooser while no project is open, so the route takes the empty project
  /// template and opens it. Logic then makes the project and puts the sheet that asks for the first
  /// track on it. That sheet has to be answered: while it is open the File menu reads Save false
  /// and Save As false, so a project left under it cannot be kept at all. The route presses Create,
  /// which takes the defaults of the sheet and makes one software instrument track. It never
  /// presses Cancel, because Cancel closes the project Logic has just made and Logic then removes
  /// the folder it wrote for it.
  ///
  /// A Logic that is already showing a project with tracks is left as it is, so the command answers
  /// the same way whether it made the project or found it.
  public func reachAProjectWithTracks(
    limitMs: Int = Wait.defaultLimitMs,
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds
  ) throws {
    if try read() == ProjectWindow.chooser {
      try press(Locators.chooserEmptyProjectTile)
      try press(Locators.chooserChooseButton)
    }
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      let shown = try read()
      return shown == ProjectWindow.emptyProject || shown == ProjectWindow.project
    }
    guard try read() == ProjectWindow.emptyProject else {
      return
    }
    try press(Locators.newTrackCreateButton)
    do {
      try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
        try read() == ProjectWindow.project
      }
    } catch let ranOut as Wait.RanOut {
      throw Refusal(
        reason: "the New Track sheet was still open \(ranOut.waitedMs)ms after Create was pressed, "
          + "so the project holds no track and Logic refuses to save it",
        code: .timeout)
    }
  }
}

extension ProjectChooser {
  /// The Logic of this Mac, read through the Accessibility tree and pressed through it.
  public static func live() -> ProjectChooser {
    ProjectChooser(
      read: ProjectChooser.whatTheLogicOfThisMacShows,
      press: ProjectChooser.pressInTheLogicOfThisMac)
  }

  /// What the Logic of this Mac shows in front, or nothing when it shows no window.
  public static func whatTheLogicOfThisMacShows() throws -> ProjectWindow? {
    guard let front = try AXDriver.treeOfRunningLogic()?.atTheFrontWindow() else {
      return nil
    }
    return ProjectChooser.window(showing: front.root)
  }

  /// Which of the three windows one element is, read from what it holds.
  ///
  /// The chooser is read first. It carries an identifier of its own and no project window carries
  /// it, so a window that answers that walk is the chooser whatever else it holds.
  public static func window(showing root: any AXNode) -> ProjectWindow {
    if resolves(Locators.chooserWindow, in: root) {
      return .chooser
    }
    if resolves(Locators.newTrackSheet, in: root) {
      return .emptyProject
    }
    return .project
  }

  /// True when the walk of one locator finds its element in this tree.
  private static func resolves(_ locator: Locator, in root: any AXNode) -> Bool {
    (try? LocatorResolver.element(of: locator, in: root)) != nil
  }

  /// Presses the element one locator names, in the window the Logic of this Mac shows in front.
  ///
  /// A press through Accessibility is not a mouse event, so it does not go through the input gate.
  /// The gate exists because a posted click lands wherever the pointer is, and this asks the one
  /// element the walk found to act on itself.
  public static func pressInTheLogicOfThisMac(_ locator: Locator) throws {
    guard let front = try AXDriver.treeOfRunningLogic()?.atTheFrontWindow() else {
      throw Refusal(reason: "Logic shows no window, so \(locator.name) could not be pressed.")
    }
    let element = try LocatorResolver.element(of: locator, in: front.root)
    guard let live = element as? LiveAXNode else {
      throw Refusal(
        reason: "\(locator.name) was found in a recorded tree, which nothing can press.",
        code: .internalFailure)
    }
    let answered = AXUIElementPerformAction(live.element, kAXPressAction as CFString)
    guard answered == .success else {
      let said = "Logic refused the press of \(locator.name), error \(answered.rawValue)."
      throw Refusal(reason: said, code: .internalFailure)
    }
  }
}
