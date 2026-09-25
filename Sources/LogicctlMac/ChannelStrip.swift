import LogicctlCore

/// Reads the plugins of one channel strip, from the tree of the Mixer window of Logic.
///
/// A channel strip carries no identifier and no title, so the strip of a track is found by its
/// place among the strips the Mixer shows. That place is the weakest of the three ways to name an
/// element, and here it is weaker still: the Mixer shows the output and the master strip after the
/// strips of the tracks, so a number past the last track reaches a strip that carries plugins of
/// its own. So the reader compares the name of the strip with the name of the track before it reads
/// anything, and a strip that disagrees is refused rather than printed as a track's.
///
/// Logic answers the children of a strip from the bottom of the strip upwards, and slot order runs
/// the other way: the instrument first, then down the channel strip. That is the order Logic writes
/// the plugin chunks of a saved project in, and the journal matches those chunks against this list
/// by position. So the reader takes the children in reverse.
public enum ChannelStrip {
  /// What the title of a Mixer window carries. The rest of the title is the name of the project and
  /// the view the Mixer is in, so this is the whole of what a Mixer of any project has in common.
  public static let windowTitle = " - Mixer"

  /// The description of the check box that every occupied slot holds, and nothing else in the strip
  /// holds. The strip carries one other group, the automation group, and it holds a check box and a
  /// button named `list` in the same shape as a plugin. This is what tells the two apart.
  private static let bypassDescription = "bypass"

  /// The description of the field that carries the name of the strip.
  private static let nameDescription = "name"

  /// Why the reader refused the strip a walk reached.
  ///
  /// The name of the locator goes out with the failure, because that is the whole address a caller
  /// has. A path that moves in a later Logic is found by that name in `Locators.swift`.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// The name of the locator the walk was following.
    public let locator: String

    /// The name of the track the strip had to belong to.
    public let wanted: String

    /// The name the strip carried, or nil when it carried none.
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
        message: "the locator \(locator) reached the strip "
          + "\(found ?? "Logic did not name") and track \(wanted) needs its own strip",
        details: .object([
          "locator": .string(locator),
          "wanted": .string(wanted),
          "found": found.map { JSONValue.string($0) } ?? .null,
        ]))
    }
  }

  /// The window of the tree that is showing the Mixer, or nothing when no window is.
  ///
  /// The walk cannot name the window by its whole title, because that carries the name of the
  /// project. Logic puts the view of the Mixer after the word, for example `Mixer: Tracks`, so the
  /// word with the separator in front of it is what a Mixer window of any project is known by.
  public static func window(of tree: LogicTree) -> (any AXNode)? {
    windows(under: tree.root).first { ($0.title ?? "").contains(windowTitle) }
  }

  /// The plugins of the channel strip of one track, in slot order, counted from 1.
  ///
  /// The track is named by its number, from 1, and by the name Logic shows for it. A strip with no
  /// plugin answers an empty list, which is a state and not a failure.
  public static func plugins(
    ofTrackNumber number: Int, named track: String, in window: any AXNode
  ) throws -> [Plugin] {
    let locator = Locators.mixerStrip(number: number - 1)
    let strip = try LocatorResolver.element(of: locator, in: window)
    let name = ChannelStrip.name(of: strip)
    guard name == track else {
      throw Refusal(locator: locator.name, wanted: track, found: name)
    }
    return ChannelStrip.plugins(of: strip)
  }

  /// The plugins one strip holds, in slot order.
  ///
  /// The reader arrives in the next commit. It answers no plugin until then, so the scenario fails
  /// on the rows it reads back rather than on the build.
  static func plugins(of strip: any AXNode) -> [Plugin] {
    []
  }

  /// The name Logic shows on a strip, or nil when the strip carries no name field.
  private static func name(of strip: any AXNode) -> String? {
    strip.children.first { $0.description == nameDescription }?.value
  }

  /// Every window the tree carries, a level at a time, so the windows of the application come
  /// before anything a window holds.
  private static func windows(under node: any AXNode) -> [any AXNode] {
    var level: [any AXNode] = [node]
    var found: [any AXNode] = []
    while !level.isEmpty {
      found += level.filter { $0.role == "AXWindow" }
      level = level.flatMap { $0.children }
    }
    return found
  }
}
