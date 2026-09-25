import LogicctlCore

/// Reads what the transport of Logic is doing, from the tree of the window it shows.
///
/// The Control Bar names its own controls, so the walk to the play button and the walk to the
/// record button each name a title rather than a place. A title is what Logic writes for the
/// language it runs in, so the reader proves what it reached before it believes it, as the track
/// reader does: the control says which one it is in its description. A row read from the wrong
/// control would put a transport in the journal of the session that Logic never showed.
///
/// The tempo is not read from the tree here. `TempoField` reads the display of the Logic that
/// runs, and a tree that was written to a file carries no display to read, so the tempo arrives as
/// a closure with that read as its value. `DialogReader` takes which window is modal the same way,
/// and a test gives its own and drives the same walk with no Logic.
public enum TransportReader {
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
          + "and the transport needs \(wanted)",
        details: .object([
          "locator": .string(locator),
          "wanted": .string(wanted),
          "found": found.map { JSONValue.string($0) } ?? .null,
        ]))
    }
  }

  /// Answers the tempo of the project, in beats per minute.
  public typealias TempoReader = () throws -> Int

  /// What the transport of Logic is doing, read from the tree of the window it shows.
  public static func transport(
    in root: any AXNode,
    tempo: TempoReader = TempoField.readTheLogicOfThisMac
  ) throws -> Transport {
    let playing = try TransportReader.isOn(
      Locators.transportRecordButton, describedAs: "Record", in: root)
    let recording = try TransportReader.isOn(
      Locators.transportRecordButton, describedAs: "Record", in: root)
    return Transport(playing: playing, recording: recording, tempo: Double(try tempo()))
  }

  /// What the value of a button of the Control Bar reads as while it is on.
  private static let on = "1"

  /// Whether one button of the Control Bar is on.
  private static func isOn(
    _ locator: Locator, describedAs wanted: String, in root: any AXNode
  ) throws -> Bool {
    let button = try LocatorResolver.element(of: locator, in: root)
    guard button.description == wanted else {
      throw Refusal(
        locator: locator.name, wanted: "the \(wanted) button", found: button.description)
    }
    return button.value == TransportReader.on
  }
}
