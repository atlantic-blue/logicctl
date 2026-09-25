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

  /// The header of one track, counted from 0 among the headers Logic shows.
  ///
  /// A track header carries no identifier and no title, so its place among the layout items is
  /// the whole of what a path can name here.
  public static func trackHeader(number: Int) -> Locator {
    Locator(
      name: "tracks.header.track\(number + 1)",
      path: toTheTracksHeader + [LocatorStep(role: "AXLayoutItem", index: number)])
  }

  /// The mute button in the header of one track.
  public static func trackMuteButton(number: Int) -> Locator {
    Locator(
      name: "tracks.header.track\(number + 1).muteButton",
      path: trackHeader(number: number).path + [LocatorStep(role: "AXCheckBox", index: 0)])
  }

  /// The solo button in the header of one track.
  public static func trackSoloButton(number: Int) -> Locator {
    Locator(
      name: "tracks.header.track\(number + 1).soloButton",
      path: trackHeader(number: number).path + [LocatorStep(role: "AXCheckBox", index: 1)])
  }

  /// The record enable button in the header of one track, which says whether the track is armed.
  public static func trackRecordEnableButton(number: Int) -> Locator {
    Locator(
      name: "tracks.header.track\(number + 1).recordEnableButton",
      path: trackHeader(number: number).path + [LocatorStep(role: "AXCheckBox", index: 2)])
  }

  /// The name field in the header of one track, which carries the name in its description.
  public static func trackNameField(number: Int) -> Locator {
    Locator(
      name: "tracks.header.track\(number + 1).nameField",
      path: trackHeader(number: number).path + [LocatorStep(role: "AXTextField", index: 0)])
  }

  /// The item of the menu bar that carries what Logic does to a track.
  ///
  /// The walk starts at the application, because the menu bar of an application sits beside its
  /// windows and not under one. So `inspect --window main`, which writes the window in front, does
  /// not reach it, and no recorded tree holds a menu bar. The live suite of phase 2 is what proves
  /// this walk against Logic itself.
  public static let trackMenu = Locator(
    name: "menu.track",
    path: toTheMenuBar + [LocatorStep(role: "AXMenuBarItem", title: "Track")])

  /// The item of the Track menu that makes one audio track.
  public static let newAudioTrack = Locator(
    name: "menu.track.newAudioTrack",
    path: toTheTrackMenu + [LocatorStep(role: "AXMenuItem", title: "New Audio Track")])

  /// The item of the Track menu that makes one software instrument track.
  public static let newSoftwareInstrumentTrack = Locator(
    name: "menu.track.newSoftwareInstrumentTrack",
    path: toTheTrackMenu
      + [LocatorStep(role: "AXMenuItem", title: "New Software Instrument Track")])

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

  /// The window Logic shows the events of one region in.
  ///
  /// It is the element a recorded Event List tree starts at, as the main window is for a tree of
  /// the tracks area. The walk names the role alone: the title of the window carries the name of
  /// the project, so no path can name it and hold for the next project.
  public static let eventListWindow = Locator(
    name: "eventList.window",
    path: [LocatorStep(role: "AXWindow")])

  /// The table of events of the Event List, which holds one row per event of the region.
  ///
  /// Nothing on the walk carries an identifier or a title, so every step names its role and its
  /// place. The table holds the rows of the region and one group of buttons, which is the header
  /// of the columns, so a reader takes the rows and leaves the group.
  public static let eventListTable = Locator(
    name: "eventList.table",
    path: toTheEventListTable)

  /// The window Logic shows the channel strips of the project in.
  ///
  /// It is the element a recorded Mixer tree starts at, as the main window is for a tree of the
  /// tracks area. The title carries the name of the project and the view the Mixer is in, for
  /// example `F-T0.logicx - Mixer: Tracks`, so no path can name it and hold for the next project.
  public static let mixerWindow = Locator(
    name: "mixer.window",
    path: [LocatorStep(role: "AXWindow")])

  /// The area of the Mixer that holds one channel strip per track, and the output and master
  /// strips after them.
  public static let mixerStrips = Locator(
    name: "mixer.strips",
    path: toTheMixerStrips)

  /// The channel strip of one track, counted from 0 among the strips the Mixer shows.
  ///
  /// A strip carries no identifier and no title, so its place among the layout items is the whole
  /// of what a path can name here. The Mixer shows the output and master strips after the strips
  /// of the tracks, so a number past the last track reaches a strip that belongs to no track. The
  /// reader compares the name of the strip with the name of the track for that reason.
  public static func mixerStrip(number: Int) -> Locator {
    Locator(
      name: "mixer.strip\(number + 1)",
      path: toTheMixerStrips + [LocatorStep(role: "AXLayoutItem", index: number)])
  }

  /// The window Logic shows when no project is open.
  ///
  /// Logic gives this window an identifier of its own, which no other window of Logic carries, so
  /// the presence of the window is how logicctl knows that no project is open.
  public static let chooserWindow = Locator(
    name: "chooser.window",
    path: [LocatorStep(role: "AXWindow", identifier: "newProjectDialog")])

  /// The name of the first template the chooser offers, which is the empty project.
  ///
  /// The tile itself carries no name a path can read, so this text is what says which template the
  /// first tile is. A Logic that puts another template first moves this name, and the walk that
  /// presses the tile is refused rather than opening a template nobody asked for.
  public static let chooserEmptyProject = Locator(
    name: "chooser.emptyProject",
    path: toTheFirstTemplate + [LocatorStep(role: "AXStaticText")])

  /// The first template tile, which is what a press selects.
  public static let chooserEmptyProjectTile = Locator(
    name: "chooser.emptyProjectTile",
    path: toTheFirstTemplate
      + [LocatorStep(role: "AXGroup", identifier: "_NS:7"), LocatorStep(role: "AXButton")])

  /// The button that opens the template the chooser has selected.
  public static let chooserChooseButton = Locator(
    name: "chooser.chooseButton",
    path: toTheChooserPanel + [LocatorStep(role: "AXButton", title: "Choose")])

  /// The sheet Logic puts on a project that has no tracks, which asks for the first track.
  ///
  /// Logic shows it on a project it has just made, and again when the last track of a project is
  /// deleted. So the sheet is how logicctl reads that the project in front has no tracks. logicctl
  /// presses no button in it: Create would make a track, and Cancel closes a project Logic made.
  public static let newTrackSheet = Locator(
    name: "newTrackSheet.sheet",
    path: [LocatorStep(role: "AXWindow"), LocatorStep(role: "AXSheet")])

  /// The window Logic opens for File, "Save As...".
  ///
  /// It is a window of its own and not a sheet on the project, and it carries an identifier that
  /// no window of Logic carries, so the presence of the window is how logicctl knows that Logic is
  /// ready to be told where the project goes.
  public static let saveWindow = Locator(
    name: "save.window",
    path: [LocatorStep(role: "AXWindow", identifier: "save-panel")])

  /// The field that holds where the project goes.
  ///
  /// Logic puts the name of the project in it. logicctl writes the whole path there instead,
  /// because a panel takes a path in that field and the alternative is driving the Where popup and
  /// the folder browser under it, neither of which names a folder a person typed.
  public static let saveNameField = Locator(
    name: "save.nameField",
    path: toTheSavePanel + [LocatorStep(role: "AXTextField", identifier: "saveAsNameTextField")])

  /// The button that writes the project where the field says.
  public static let saveButton = Locator(
    name: "save.saveButton",
    path: toTheSavePanel + [LocatorStep(role: "AXButton", identifier: "OKButton")])

  /// Every locator a recorded tree proves. A test resolves each one in the trees it was read from.
  ///
  /// The three menu locators are not here. A menu bar sits beside the windows of an application
  /// rather than under one, so no recorded tree holds it, and a walk of it can only be proved
  /// against the Logic of this Mac. The live suite of phase 2 does that.
  public static let all: [Locator] = [
    mainWindow,
    tracksHeader,
    tracksHeaderMuteButton,
    tracksHeaderSoloButton,
    transportPlayButton,
    transportStopButton,
    transportRecordButton,
    chooserWindow,
    chooserEmptyProject,
    chooserEmptyProjectTile,
    chooserChooseButton,
    newTrackSheet,
    eventListWindow,
    eventListTable,
    mixerWindow,
    mixerStrips,
    saveWindow,
    saveNameField,
    saveButton,
  ]

  /// The walk from the window Logic opens for File, "Save As...".
  private static let toTheSavePanel: [LocatorStep] = [
    LocatorStep(role: "AXWindow", identifier: "save-panel")
  ]

  /// The walk from the window of the chooser to the panel that holds the templates and the
  /// buttons.
  private static let toTheChooserPanel: [LocatorStep] = [
    LocatorStep(role: "AXWindow", identifier: "newProjectDialog"),
    LocatorStep(role: "AXSplitGroup"),
    LocatorStep(role: "AXGroup", identifier: "_NS:44"),
  ]

  /// The walk from the window of the chooser to the first template it offers.
  private static let toTheFirstTemplate: [LocatorStep] =
    toTheChooserPanel + [
      LocatorStep(role: "AXScrollArea"),
      LocatorStep(role: "AXList"),
      LocatorStep(role: "AXList"),
      LocatorStep(role: "AXGroup", index: 0),
    ]

  /// The walk from the window to the header of the first track.
  private static let toTheFirstTrack: [LocatorStep] =
    toTheTracksHeader + [LocatorStep(role: "AXLayoutItem", index: 0)]

  /// The walk from the application of Logic to its menu bar.
  private static let toTheMenuBar: [LocatorStep] = [
    LocatorStep(role: "AXApplication"),
    LocatorStep(role: "AXMenuBar"),
  ]

  /// The walk from the application of Logic to the items of its Track menu.
  private static let toTheTrackMenu: [LocatorStep] =
    toTheMenuBar + [
      LocatorStep(role: "AXMenuBarItem", title: "Track"),
      LocatorStep(role: "AXMenu"),
    ]

  /// The walk from the window of the Event List to the table of events it holds.
  private static let toTheEventListTable: [LocatorStep] = [
    LocatorStep(role: "AXWindow"),
    LocatorStep(role: "AXGroup", index: 0),
    LocatorStep(role: "AXGroup", index: 2),
    LocatorStep(role: "AXScrollArea", index: 0),
    LocatorStep(role: "AXTable", index: 0),
  ]

  /// The walk from the window of the Mixer to the area that holds the channel strips.
  private static let toTheMixerStrips: [LocatorStep] = [
    LocatorStep(role: "AXWindow"),
    LocatorStep(role: "AXGroup", index: 0),
    LocatorStep(role: "AXLayoutArea", index: 0),
  ]

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
