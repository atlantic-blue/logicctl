import Foundation

/// A tree of Logic that `inspect` wrote to a file, and the version of Logic it came from.
///
/// The file is one JSON object: `logicVersion`, and `root`, the element the tree starts at. The
/// version sits beside the tree because a locator holds good for the version it was read from,
/// and a file that does not say which version it came from cannot answer that later.
public struct RecordedTree: Decodable, Equatable {
  /// The version of Logic the tree was read from, for example `12.3.1`.
  public let logicVersion: String

  /// The element the tree starts at.
  public let root: RecordedAXNode

  /// Reads a tree from a file that `inspect` wrote.
  public init(contentsOf file: URL) throws {
    self = try JSONDecoder().decode(RecordedTree.self, from: Data(contentsOf: file))
  }
}

/// One element of a tree that was written to a file.
///
/// A key the file leaves out reads as nothing, which is how a tree says that Logic carried no
/// title, no identifier or no help for an element.
public struct RecordedAXNode: AXNode, Decodable, Equatable {
  public let role: String
  public let title: String?
  public let identifier: String?
  public let value: String?
  public let valueDescription: String?
  public let description: String?
  public let help: String?
  public let orientation: String?
  public let actions: [String]

  /// The children as the file wrote them. `children` answers the same elements through the
  /// protocol, and this one keeps their type, so a test compares a whole tree with one `==`.
  public let recordedChildren: [RecordedAXNode]

  public var children: [any AXNode] {
    recordedChildren
  }

  private enum CodingKeys: String, CodingKey {
    case role
    case title
    case identifier
    case value
    case valueDescription
    case description
    case help
    case orientation
    case actions
    case recordedChildren = "children"
  }

  public init(from decoder: any Decoder) throws {
    let read = try decoder.container(keyedBy: CodingKeys.self)
    role = try read.decode(String.self, forKey: .role)
    title = try read.decodeIfPresent(String.self, forKey: .title)
    identifier = try read.decodeIfPresent(String.self, forKey: .identifier)
    value = try read.decodeIfPresent(String.self, forKey: .value)
    valueDescription = try read.decodeIfPresent(String.self, forKey: .valueDescription)
    description = try read.decodeIfPresent(String.self, forKey: .description)
    help = try read.decodeIfPresent(String.self, forKey: .help)
    orientation = try read.decodeIfPresent(String.self, forKey: .orientation)
    actions = try read.decodeIfPresent([String].self, forKey: .actions) ?? []
    recordedChildren =
      try read.decodeIfPresent([RecordedAXNode].self, forKey: .recordedChildren) ?? []
  }
}
