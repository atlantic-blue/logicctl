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
/// One walk writes the tree of the Logic that runs and the tree a test holds, because both answer
/// through `AXNode`. So the file a person records on this Mac is the file every later step reads in
/// a pipeline with no Logic, and there is no second form for the two to drift apart in.
public enum TreeWriter {
  /// One element and everything under it, cut at `depth`. A depth of 1 is the element on its own,
  /// and a depth of 2 is the element and the elements one level under it.
  ///
  /// A key the element does not carry is left out, and so is an empty list, because a missing key
  /// reads back as nothing and a file a person opens is shorter for it. `description` and `help`
  /// are written although the tree a person reads does not name them: a plugin slot of Logic is
  /// found by its description and by nothing else, and a region carries its borders in its help, so
  /// a file without the two cannot serve the steps that look for either.
  public static func json(of node: any AXNode, depth: Int) -> JSONValue {
    var written: [String: JSONValue] = ["role": .string(node.role)]
    let text = [
      "title": node.title,
      "identifier": node.identifier,
      "value": node.value,
      "valueDescription": node.valueDescription,
      "description": node.description,
      "help": node.help,
    ]
    for (key, carried) in text {
      guard let carried else {
        continue
      }
      written[key] = .string(carried)
    }
    if !node.actions.isEmpty {
      written["actions"] = .array(node.actions.map(JSONValue.string))
    }
    let children = depth > 1 ? node.children : []
    if !children.isEmpty {
      written["children"] = .array(children.map { json(of: $0, depth: depth - 1) })
    }
    return .object(written)
  }

  /// The whole file: the version of Logic, and the element the tree starts at.
  public static func json(of tree: LogicTree, depth: Int) -> JSONValue {
    .object([
      "logicVersion": .string(tree.logicVersion),
      "root": json(of: tree.root, depth: depth),
    ])
  }

  /// How many elements sit at each level, the root first. It stops at `depth`, and at the level
  /// where the tree runs out.
  public static func counts(of node: any AXNode, depth: Int) -> [Int] {
    var counted: [Int] = []
    var level: [any AXNode] = [node]
    while !level.isEmpty, counted.count < depth {
      counted.append(level.count)
      level = level.flatMap { $0.children }
    }
    return counted
  }

  /// Writes the tree where `--out` names, in the form a recorded tree reads back.
  public static func write(_ tree: LogicTree, depth: Int, to file: URL) throws {
    let text = CanonicalJSON.text(of: json(of: tree, depth: depth), indent: 2) + "\n"
    try Data(text.utf8).write(to: file, options: .atomic)
  }
}
