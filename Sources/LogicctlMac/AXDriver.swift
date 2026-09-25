import AppKit
import Foundation
import LogicctlCore

/// What logicctl reads from the Logic that runs on this Mac.
///
/// Four reads answer `status`, and each one comes from a different place. Whether Logic runs, and
/// which version it is, come from the application bundle that macOS has open. Whether Logic is in
/// front comes from the workspace. The title of the window comes from the Accessibility tree. So
/// the driver is given the tree and the front application rather than reaching for them, and the
/// pipeline, which has no Logic, drives the same code against a tree that `inspect` recorded from
/// Logic 12.3.1.
public struct AXDriver: LogicStatusReader {
  /// The tree of the Logic that runs, or nothing when no Logic runs.
  private let tree: () throws -> LogicTree?

  /// The bundle identifier of the application in front, or nothing when macOS names none.
  private let applicationInFront: () -> String?

  public init(
    tree: @escaping () throws -> LogicTree? = AXDriver.treeOfRunningLogic,
    applicationInFront: @escaping () -> String? = AXDriver.applicationInFrontOfThisMac
  ) {
    self.tree = tree
    self.applicationInFront = applicationInFront
  }

  /// What Logic is doing now.
  ///
  /// A Mac with no Logic answers `running` false and nothing else, and it does not throw. Every
  /// other read of a driver refuses there, because there is no project to answer about. This one
  /// is the question of whether there is a Logic at all, and a refusal would leave a script with
  /// an exit code instead of an answer.
  public func status() throws -> LogicStatus {
    guard let open = try tree() else {
      return LogicStatus.notRunning
    }
    return LogicStatus(
      running: true,
      frontmost: applicationInFront() == LogicTree.bundleIdentifier,
      window: open.atTheFrontWindow()?.root.title,
      version: open.logicVersion.isEmpty ? nil : open.logicVersion)
  }

  /// The tree of the Logic that runs on this Mac, or nothing when no Logic runs.
  ///
  /// `LogicTree.ofRunningLogic` refuses where there is no Logic, because a walk of nothing prints
  /// an empty tree and an empty tree reads the same as a Logic that shows nothing. `status` asks a
  /// different question, so that one refusal reads here as the answer nothing.
  public static func treeOfRunningLogic() throws -> LogicTree? {
    do {
      return try LogicTree.ofRunningLogic()
    } catch DriverRefusal.logicNotRunning {
      return nil
    }
  }

  /// What macOS says is the application in front, by bundle identifier.
  public static func applicationInFrontOfThisMac() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
  }
}
