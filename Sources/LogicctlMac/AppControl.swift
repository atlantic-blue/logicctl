import AppKit
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

  public init(start: @escaping Start, read: @escaping Read) {
    self.start = start
    self.read = read
  }
}

extension AppControl {
  /// The Logic of this Mac, started and read through macOS.
  public static func live() -> AppControl {
    AppControl(start: AppControl.startTheLogicOfThisMac, read: AppControl.readTheLogicOfThisMac)
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
