import LogicctlCore

/// Reads the tracks of the project Logic has open, from the tree of the window it shows.
///
/// Logic gives a track header no identifier and no title, so every read here is a walk to a place
/// among the layout items, and a place is the weakest of the three ways to name an element. So the
/// reader proves what it reached before it believes it: a check box says what it is in its
/// description, and the name field says so in its help text. A row read from the wrong control
/// would put a number in the journal that Logic never showed.
public enum TrackReader {
  /// Why the reader refused the element a walk reached.
  ///
  /// The name of the locator goes out with the failure, because that is the whole address a caller
  /// has. A path that moves in a later Logic is found by that name in `Locators.swift`.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// The name of the locator the walk was following.
    public let locator: String

    /// What the element at the end of the walk had to be.
    public let wanted: String

    /// What Logic said the element was, or nil when it said nothing.
    public let found: String?

    public init(locator: String, wanted: String, found: String?) {
      self.locator = locator
      self.wanted = wanted
      self.found = found
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(
        code: .elementNotFound,
        message: "the locator \(locator) reached \(found ?? "an element Logic did not name") "
          + "and the track row needs \(wanted)",
        details: .object([
          "locator": .string(locator),
          "wanted": .string(wanted),
          "found": found.map { JSONValue.string($0) } ?? .null,
        ]))
    }
  }

  /// The tracks of the project, in the order Logic shows them, counted from 1.
  ///
  /// A project with no track answers an empty list. Logic puts a sheet on a project that has no
  /// track, and the header behind it holds no row, which is the same answer read from the tree.
  public static func tracks(in root: any AXNode) throws -> [Track] {
    throw Refusal(
      locator: Locators.tracksHeader.name, wanted: "a reader of the track headers", found: nil)
  }
}
