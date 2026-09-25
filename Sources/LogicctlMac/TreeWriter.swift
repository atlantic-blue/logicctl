import AppKit
import Foundation
import LogicctlCore

/// The tree of Logic that a walk starts at, and the version of Logic it belongs to.
///
/// The two travel together because a tree is only good for the version it was read from: an element
/// found by a path through 12.3.1 says nothing about another build, and a file that does not name
/// its version cannot answer that question later.
public struct LogicTree {
  /// What the bundle of Logic Pro is called, which is how this Mac is asked whether Logic runs.
  public static let bundleIdentifier = "com.apple.logic10"

  /// The version of Logic the tree was read from, for example `12.3.1`.
  public let logicVersion: String

  /// The element the walk starts at.
  public let root: any AXNode

  public init(logicVersion: String, root: any AXNode) {
    self.logicVersion = logicVersion
    self.root = root
  }

  /// The tree of the Logic that runs on this Mac, and the version that Logic reports.
  ///
  /// It refuses with `logic_not_running` when no Logic runs, because a walk of nothing would print
  /// an empty tree, and an empty tree reads the same as a Logic that shows nothing.
  public static func ofRunningLogic() throws -> LogicTree {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    guard let logic = running.first else {
      throw DriverRefusal.logicNotRunning
    }
    return LogicTree(
      logicVersion: version(ofApplicationAt: logic.bundleURL),
      root: LiveAXNode.application(logic.processIdentifier))
  }

  /// The version an application bundle reports, or an empty text when it reports none. A tree that
  /// names no version is refused where it is used, by the fixtures that read it back.
  static func version(ofApplicationAt bundle: URL?) -> String {
    guard let bundle, let read = Bundle(url: bundle) else {
      return ""
    }
    return read.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }

  /// The same tree, starting at the window of Logic instead of the application, or nothing when
  /// Logic shows no window.
  ///
  /// It answers the first window the tree carries, which is the window in front. Step 6 of Setup
  /// puts the main window in `Locators.swift` and every later read goes through that name.
  public func atTheFrontWindow() -> LogicTree? {
    guard let window = LogicTree.firstWindow(under: root) else {
      return nil
    }
    return LogicTree(logicVersion: logicVersion, root: window)
  }

  /// The first element with the role of a window, looked for a level at a time so the windows of
  /// the application come before anything a window holds.
  private static func firstWindow(under node: any AXNode) -> (any AXNode)? {
    var level: [any AXNode] = [node]
    while !level.isEmpty {
      if let window = level.first(where: { $0.role == "AXWindow" }) {
        return window
      }
      level = level.flatMap { $0.children }
    }
    return nil
  }
}

/// Writes a tree of Logic in the form `RecordedTree` reads back.
///
/// The writer arrives in the next commit. This one writes the version and one bare element, so the
/// scenario runs and fails on what it reads back rather than on a build.
public enum TreeWriter {
  /// One element and everything under it, cut at `depth`.
  public static func json(of node: any AXNode, depth: Int) -> JSONValue {
    .object(["role": .string(node.role)])
  }

  /// The whole file: the version of Logic, and the element the tree starts at.
  public static func json(of tree: LogicTree, depth: Int) -> JSONValue {
    .object([
      "logicVersion": .string(tree.logicVersion),
      "root": json(of: tree.root, depth: depth),
    ])
  }

  /// How many elements sit at each level, the root first.
  public static func counts(of node: any AXNode, depth: Int) -> [Int] {
    []
  }

  /// Writes the tree where `--out` names, in the form a recorded tree reads back.
  public static func write(_ tree: LogicTree, depth: Int, to file: URL) throws {
    let text = CanonicalJSON.text(of: json(of: tree, depth: depth), indent: 2) + "\n"
    try Data(text.utf8).write(to: file, options: .atomic)
  }
}
