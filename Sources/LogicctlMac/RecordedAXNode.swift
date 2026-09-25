import Foundation

/// A tree of Logic that `inspect` wrote to a file, and the version of Logic it came from.
///
/// The reader arrives in the next commit. This one answers no version and an empty element, so
/// the scenario runs and fails on what it reads back rather than on a build.
public struct RecordedTree {
  /// The version of Logic the tree was read from, for example `12.3.1`.
  public let logicVersion: String

  /// The element the tree starts at.
  public let root: RecordedAXNode

  /// Reads a tree from a file.
  public init(contentsOf file: URL) throws {
    _ = try Data(contentsOf: file)
    logicVersion = ""
    root = RecordedAXNode()
  }
}

/// One element of a tree that was written to a file.
public struct RecordedAXNode: AXNode {
  public var role: String { "" }
  public var title: String? { nil }
  public var identifier: String? { nil }
  public var value: String? { nil }
  public var description: String? { nil }
  public var help: String? { nil }
  public var actions: [String] { [] }
  public var children: [any AXNode] { [] }
}
