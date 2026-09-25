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
    let header = try LocatorResolver.element(of: Locators.tracksHeader, in: root)
    let rows = header.children.filter { $0.role == TrackReader.headerRole }.count
    var tracks: [Track] = []
    for number in 0..<rows {
      tracks.append(try TrackReader.track(number: number, in: root))
    }
    return tracks
  }

  /// The role of one track header, under the group that holds them all.
  private static let headerRole = "AXLayoutItem"

  /// What the value of a button reads as while it is on.
  private static let on = "1"

  /// The first words of the help text of the name field. The description of that field is the
  /// name of the track, so the help text is what says which field it is.
  private static let nameFieldHelp = "Name field"

  /// One track, read from its header.
  private static func track(number: Int, in root: any AXNode) throws -> Track {
    let name = try TrackReader.name(ofTrackNumber: number, in: root)
    let mute = try TrackReader.isOn(
      Locators.trackMuteButton(number: number), describedAs: "Mute", in: root)
    let solo = try TrackReader.isOn(
      Locators.trackSoloButton(number: number), describedAs: "Solo", in: root)
    let arm = try TrackReader.isOn(
      Locators.trackRecordEnableButton(number: number), describedAs: "Record Enable", in: root)
    // The header of an audio track and the header of a software instrument track carry the same
    // nine controls, and neither says which kind the track is. Only a mixer strip says it, and
    // nothing here opens the mixer, so every row reads as the kind that is neither.
    return Track(index: number + 1, name: name, type: .other, mute: mute, solo: solo, arm: arm)
  }

  /// The name Logic shows in the header of one track.
  private static func name(ofTrackNumber number: Int, in root: any AXNode) throws -> String {
    let locator = Locators.trackNameField(number: number)
    let field = try LocatorResolver.element(of: locator, in: root)
    guard (field.help ?? "").hasPrefix(TrackReader.nameFieldHelp) else {
      throw Refusal(
        locator: locator.name, wanted: "the name field of the track header", found: field.help)
    }
    guard let name = field.value else {
      throw Refusal(
        locator: locator.name, wanted: "a name field that carries the name of the track",
        found: nil)
    }
    return name
  }

  /// Whether one button of a track header is on.
  private static func isOn(
    _ locator: Locator, describedAs wanted: String, in root: any AXNode
  ) throws -> Bool {
    let button = try LocatorResolver.element(of: locator, in: root)
    guard button.description == wanted else {
      throw Refusal(
        locator: locator.name, wanted: "the \(wanted) button", found: button.description)
    }
    return button.value == TrackReader.on
  }
}
