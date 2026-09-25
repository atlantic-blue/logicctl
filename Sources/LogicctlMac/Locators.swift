/// Where an element sits in the tree Logic shows, written down as data.
///
/// Nothing in the Accessibility tree of Logic carries an address that lasts, so an element is
/// found by walking down from the window to it. A locator is that walk. Every walk logicctl makes
/// is in this one file: a command names a locator and carries no path of its own, and a path that
/// moves in a later Logic is changed here and nowhere else.
public struct Locator: Equatable, Sendable {
  /// What the locator is called, for example `tracks.header.muteButton`.
  public let name: String

  /// The walk down to the element. The first step names the element the walk starts at, which is
  /// the main window, and every step after it names one element under the step before it.
  public let path: [LocatorStep]

  /// The version of Logic the path was read from, for example `12.3.1`. A path holds for that
  /// version and says nothing about another build.
  public let recordedFrom: String

  public init(name: String, path: [LocatorStep], recordedFrom: String = Locators.recordedFrom) {
    self.name = name
    self.path = path
    self.recordedFrom = recordedFrom
  }
}

/// One element on the walk a locator makes.
///
/// A step reads the identifier first, then the title, then the index, which is the order the three
/// last in. An identifier Logic gives an element of its own stands in every project. A title
/// stands until the language of Logic changes. An index is the weakest of the three and is there
/// for the elements that carry neither of the others.
public struct LocatorStep: Equatable, Sendable {
  /// What kind of element this is, for example `AXButton`. Every step names one.
  public let role: String

  /// The identifier the element carries, or nil when the step names none.
  public let identifier: String?

  /// The title the element carries, or nil when the step names none.
  public let title: String?

  /// Which element of that role, counted from 0 among the elements of that role alone.
  ///
  /// The count leaves out every element of another role, because Logic puts elements beside the
  /// one a step names and takes them away again. The Control Bar is the seventh element of the
  /// window while a sheet is open and the sixth once it closes, and the first group of the window
  /// in both.
  public let index: Int?

  public init(role: String, identifier: String? = nil, title: String? = nil, index: Int? = nil) {
    self.role = role
    self.identifier = identifier
    self.title = title
    self.index = index
  }
}

/// Every locator logicctl has.
///
/// A later part adds its own locators here and leaves these. The paths were read from Logic 12.3.1
/// with `inspect`, and the trees under `Tests/Fixtures/logic-12.3.1` are what proves each one.
public enum Locators {
  /// The version of Logic every path in this file was read from.
  public static let recordedFrom = "12.3.1"

  /// The window Logic shows the tracks area in.
  ///
  /// It is the element a recorded tree starts at, because `inspect --window main` writes the front
  /// window as the root. The window carries no identifier, and its title carries the name of the
  /// project, so the role is the whole of what a path can name here.
  public static let mainWindow = Locator(
    name: "window.main",
    path: [LocatorStep(role: "AXWindow")])

  /// The group that holds the header of every track.
  public static let tracksHeader = Locator(
    name: "tracks.header",
    path: toTheTracksHeader)

  /// The mute button in the header of the first track.
  ///
  /// The button carries no identifier and no title, so the step names its role and its place. The
  /// track is the first one: the part that mutes a track by its number takes the number of the
  /// layout item from the command.
  public static let tracksHeaderMuteButton = Locator(
    name: "tracks.header.muteButton",
    path: toTheFirstTrack + [LocatorStep(role: "AXCheckBox", index: 0)])

  /// The solo button in the header of the first track.
  public static let tracksHeaderSoloButton = Locator(
    name: "tracks.header.soloButton",
    path: toTheFirstTrack + [LocatorStep(role: "AXCheckBox", index: 1)])

  /// The play button of the Control Bar.
  public static let transportPlayButton = Locator(
    name: "transport.playButton",
    path: toTheControlBar + [LocatorStep(role: "AXCheckBox", title: "Play")])

  /// The stop button of the Control Bar.
  public static let transportStopButton = Locator(
    name: "transport.stopButton",
    path: toTheControlBar + [LocatorStep(role: "AXButton", title: "Stop")])

  /// The record button of the Control Bar.
  public static let transportRecordButton = Locator(
    name: "transport.recordButton",
    path: toTheControlBar + [LocatorStep(role: "AXCheckBox", title: "Record")])

  /// Every locator this file holds. A test resolves each one in the trees it was read from.
  public static let all: [Locator] = [
    mainWindow,
    tracksHeader,
    tracksHeaderMuteButton,
    tracksHeaderSoloButton,
    transportPlayButton,
    transportStopButton,
    transportRecordButton,
  ]

  /// The walk from the window to the header of the first track.
  private static let toTheFirstTrack: [LocatorStep] =
    toTheTracksHeader + [LocatorStep(role: "AXLayoutItem", index: 0)]

  /// The walk from the window to the Control Bar, which holds the transport.
  private static let toTheControlBar: [LocatorStep] = [
    LocatorStep(role: "AXWindow"),
    LocatorStep(role: "AXGroup", index: 0),
  ]

  /// The walk from the window to the group that holds the track headers.
  private static let toTheTracksHeader: [LocatorStep] = [
    LocatorStep(role: "AXWindow"),
    LocatorStep(role: "AXGroup", index: 3),
    LocatorStep(role: "AXGroup", index: 1),
    LocatorStep(role: "AXSplitGroup", index: 0),
    LocatorStep(role: "AXSplitGroup", index: 1),
    LocatorStep(role: "AXScrollArea", index: 0),
    LocatorStep(role: "AXGroup", index: 0),
  ]
}
