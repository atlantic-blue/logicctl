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
/// A step reads the identifier first, then the title, then the description, then the index, which
/// is the order the four last in. An identifier Logic gives an element of its own stands in every
/// project. A title stands until the language of Logic changes. A description says what the element
/// is for, and it stands while the element does. An index is the weakest of the four and is there
/// for the elements that carry none of the others.
public struct LocatorStep: Equatable, Sendable {
  /// What kind of element this is, for example `AXButton`. Every step names one.
  public let role: String

  /// The identifier the element carries, or nil when the step names none.
  public let identifier: String?

  /// The title the element carries, or nil when the step names none.
  public let title: String?

  /// What the element is for, in the words Accessibility carries, or nil when the step names none.
  ///
  /// The panes of the window of Logic carry one each, and a pane carries no identifier and no
  /// title, so this is the only lasting way to name one.
  public let description: String?

  /// Which element of that role, counted from 0 among the elements of that role alone.
  ///
  /// The count leaves out every element of another role, because Logic puts elements beside the
  /// one a step names and takes them away again. The Control Bar is the seventh element of the
  /// window while a sheet is open and the sixth once it closes, and the first group of the window
  /// in both.
  public let index: Int?

  public init(
    role: String, identifier: String? = nil, title: String? = nil, description: String? = nil,
    index: Int? = nil
  ) {
    self.role = role
    self.identifier = identifier
    self.title = title
    self.description = description
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

  /// The item of the menu bar that carries what Logic does to the mix, and to automation with it.
  ///
  /// The walk starts at the application, as the walk to the Track menu does, because the menu bar
  /// of an application sits beside its windows and not under one. So no recorded tree holds it,
  /// and the live suite of phase 4 is what proves this walk against Logic itself.
  public static let mixMenu = Locator(
    name: "menu.mix",
    path: toTheMenuBar + [LocatorStep(role: "AXMenuBarItem", title: "Mix")])

  /// The item of the Mix menu that opens what Logic can make as track automation.
  public static let createTrackAutomationMenu = Locator(
    name: "menu.mix.createTrackAutomation",
    path: toTheMixMenu + [LocatorStep(role: "AXMenuItem", title: "Create Track Automation")])

  /// The item that makes one automation point at each border of the selected region.
  ///
  /// The title is matched whole and not as a beginning. The same submenu carries "Create 2
  /// Automation Points each for Volume, Pan, Sends" and "Create 2 Automation Points for Visible
  /// Parameter", and both of those read as this one for the first 24 characters. Either would
  /// change more of the project than a person asked for, and no later read of the region would
  /// say which item was pressed.
  public static let createAutomationPointsAtRegionBorders = Locator(
    name: "menu.mix.createAutomationPointsAtRegionBorders",
    path: toTheCreateTrackAutomationMenu
      + [
        LocatorStep(role: "AXMenuItem", title: "Create 2 Automation Points at Region Borders")
      ])

  /// The item of the Mix menu that opens what Logic can convert automation into.
  public static let convertAutomationMenu = Locator(
    name: "menu.mix.convertAutomation",
    path: toTheMixMenu + [LocatorStep(role: "AXMenuItem", title: "Convert Automation")])

  /// The item that moves the automation of the track into the region it sits over.
  ///
  /// The title is matched whole here too. The same submenu carries "Convert All Track Automation
  /// to Region Automation", which moves the automation of the whole track rather than what is
  /// visible over the one region.
  public static let convertTrackAutomationToRegionAutomation = Locator(
    name: "menu.mix.convertTrackAutomationToRegionAutomation",
    path: toTheConvertAutomationMenu
      + [
        LocatorStep(
          role: "AXMenuItem", title: "Convert Visible Track Automation to Region Automation")
      ])

  /// The item of the menu bar that carries the windows Logic can open.
  ///
  /// The walk starts at the application, as the walks to the Track menu and the Mix menu do,
  /// because the menu bar of an application sits beside its windows and not under one. So no
  /// recorded tree holds it, and the live acceptance is what proves this walk against Logic
  /// itself.
  public static let windowMenu = Locator(
    name: "menu.window",
    path: toTheMenuBar + [LocatorStep(role: "AXMenuBarItem", title: "Window")])

  /// The item of the Window menu that opens the Mixer in a window of its own.
  ///
  /// Measured on this Mac on 2026-09-26 against Logic 12.3.1: the item is titled `Open Mixer` and
  /// Logic offers it while a project is open. The state reader presses it to read the kind of each
  /// track, which is in the channel strip and nowhere else.
  public static let openMixer = Locator(
    name: "menu.window.openMixer",
    path: toTheWindowMenu + [LocatorStep(role: "AXMenuItem", title: "Open Mixer")])

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
  /// deleted. So the sheet is how logicctl reads that the project in front has no tracks.
  public static let newTrackSheet = Locator(
    name: "newTrackSheet.sheet",
    path: toTheNewTrackSheet)

  /// The button of the sheet that makes the first track of the project.
  ///
  /// Logic refuses Save while this sheet is open, so a project under it cannot be kept, and the
  /// other button of the sheet closes the project Logic has just made. The step names the title and
  /// not the identifier: the identifier of this button reads `_NS:618`, and Logic gives it another
  /// number on another launch.
  public static let newTrackCreateButton = Locator(
    name: "newTrackSheet.createButton",
    path: toTheNewTrackSheet
      + [LocatorStep(role: "AXGroup"), LocatorStep(role: "AXButton", title: "Create")])

  /// The window Logic opens for File, "Save As...".
  ///
  /// It is a window of its own and not a sheet on the project, and it carries an identifier that
  /// no window of Logic carries, so the presence of the window is how logicctl knows that Logic is
  /// ready to be told where the project goes.
  public static let saveWindow = Locator(
    name: "save.window",
    path: [LocatorStep(role: "AXWindow", identifier: "save-panel")])

  /// The field that holds the name of the project.
  ///
  /// A value written here is read as a name and never as a path: Logic turns every slash of it into
  /// a colon. So logicctl writes the name of the project on its own, and the folder comes from the
  /// walk of the column browser beside it.
  public static let saveNameField = Locator(
    name: "save.nameField",
    path: toTheSavePanel + [LocatorStep(role: "AXTextField", identifier: "saveAsNameTextField")])

  /// The button that writes the project where the field says.
  public static let saveButton = Locator(
    name: "save.saveButton",
    path: toTheSavePanel + [LocatorStep(role: "AXButton", identifier: "OKButton")])

  /// The button that closes the Save panel and writes nothing.
  ///
  /// The route presses it when a folder of the path is not in the column, so a refusal leaves no
  /// panel open waiting for an answer that nothing is going to give it.
  public static let saveCancelButton = Locator(
    name: "save.cancelButton",
    path: toTheSavePanel + [LocatorStep(role: "AXButton", identifier: "CancelButton")])

  /// The popup that says which folder the Save panel is in.
  ///
  /// Measured on Logic 12.3.1 on 2026-09-26: `AXOpen` on the name of a folder in a column moves the
  /// value of this popup to that folder. So it is how the route reads back where the walk got to.
  public static let saveWherePopup = Locator(
    name: "save.wherePopup",
    path: toTheSavePanel + [LocatorStep(role: "AXPopUpButton", identifier: "where popup")])

  /// The browser of the Save panel, which lists the folders of this Mac one column at a time.
  ///
  /// The leftmost column lists the root of the start up disk, and each column to the right lists
  /// what the row selected in the column before it holds. So the walk to a folder is one column per
  /// part of the path, and the panel needs no field for a path.
  public static let saveColumnView = Locator(
    name: "save.columnView",
    path: toTheSaveColumnView)

  /// One column of that browser, counted from 0. Column 0 lists the root of the start up disk.
  ///
  /// A column carries no identifier and no title, so its place among the scroll areas of the
  /// browser is the whole of what a path can name here. The scroll bar of the browser carries
  /// another role, so it is not counted.
  public static func saveColumn(number: Int) -> Locator {
    let column = [
      LocatorStep(role: "AXScrollArea"),
      LocatorStep(role: "AXScrollArea", index: number),
      LocatorStep(role: "AXList"),
    ]
    return Locator(name: "save.column\(number + 1)", path: toTheSaveColumnView + column)
  }

  /// The scroll bar of one column of that browser, which puts the rows of it in view.
  ///
  /// A column scrolls its own rows, and `AXOpen` reaches a row only while that row is in view.
  /// Measured on Logic 12.3.1 on 2026-09-26 at 15:30: the folder at row 14 of the 22 in the home
  /// folder did not open until this bar was set to (14 - 1) / (22 - 1). The bar carries no
  /// identifier either, and it is the one element of its role inside the column.
  public static func saveColumnScrollBar(number: Int) -> Locator {
    let bar = [
      LocatorStep(role: "AXScrollArea"),
      LocatorStep(role: "AXScrollArea", index: number),
      LocatorStep(role: "AXScrollBar"),
    ]
    return Locator(name: "save.column\(number + 1).scrollBar", path: toTheSaveColumnView + bar)
  }

  /// The window Logic opens for File, Import, "MIDI File...".
  ///
  /// It is a window of its own and not a sheet on the project, and it carries the identifier
  /// `open-panel`, which the window Logic opens to save does not. So the presence of the window is
  /// how logicctl knows that Logic is ready to be told which file to import.
  public static let importWindow = Locator(
    name: "import.window",
    path: [LocatorStep(role: "AXWindow", identifier: "open-panel")])

  /// The popup that says which folder the panel is in.
  ///
  /// The panel of Logic 12.3.1 carries no field for a path, so this popup is how the route moves
  /// the panel to the start up disk, and its value is how the route reads which folder the panel
  /// reached after each open.
  public static let importWherePopup = Locator(
    name: "import.wherePopup",
    path: toTheImportPanel + [LocatorStep(role: "AXPopUpButton", identifier: "where popup")])

  /// The button that imports the file the panel has selected. Logic titles it Import.
  public static let importButton = Locator(
    name: "import.importButton",
    path: toTheImportPanel + [LocatorStep(role: "AXButton", identifier: "OKButton")])

  /// The button that closes the panel and imports nothing.
  ///
  /// logicctl never presses it. It is here because a command that failed inside the panel leaves
  /// the panel open, and a person reading the failure needs the name of the control that closes
  /// it.
  public static let importCancelButton = Locator(
    name: "import.cancelButton",
    path: toTheImportPanel + [LocatorStep(role: "AXButton", identifier: "CancelButton")])

  /// Every locator a recorded tree proves. A test resolves each one in the trees it was read from.
  ///
  /// The menu locators are not here. A menu bar sits beside the windows of an application rather
  /// than under one, so no recorded tree holds it, and a walk of it can only be proved against the
  /// Logic of this Mac. The live suite of phase 2 does that for the Track menu, and the live
  /// acceptance of phase 4 does it for the Mix menu.
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
    newTrackCreateButton,
    eventListWindow,
    eventListTable,
    mixerWindow,
    mixerStrips,
    saveWindow,
    saveNameField,
    saveButton,
    saveCancelButton,
    saveWherePopup,
    saveColumnView,
    importWindow,
    importWherePopup,
    importButton,
    importCancelButton,
  ]

  /// The walk from the project window to the sheet that asks for the first track.
  private static let toTheNewTrackSheet: [LocatorStep] = [
    LocatorStep(role: "AXWindow"), LocatorStep(role: "AXSheet"),
  ]

  /// The walk from the window Logic opens for File, "Save As...".
  private static let toTheSavePanel: [LocatorStep] = [
    LocatorStep(role: "AXWindow", identifier: "save-panel")
  ]

  /// The walk from that window to the browser that lists the folders in columns.
  ///
  /// The browser sits under the splitter that holds the sidebar on its left, so the walk goes
  /// through two split groups to reach it.
  private static let toTheSaveColumnView: [LocatorStep] = [
    LocatorStep(role: "AXWindow", identifier: "save-panel"),
    LocatorStep(role: "AXSplitGroup"),
    LocatorStep(role: "AXSplitGroup"),
    LocatorStep(role: "AXBrowser", identifier: "ColumnView"),
  ]

  /// The walk from the window Logic opens for File, Import, "MIDI File...".
  private static let toTheImportPanel: [LocatorStep] = [
    LocatorStep(role: "AXWindow", identifier: "open-panel")
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

  /// The walk from the application of Logic to the items of its Mix menu.
  private static let toTheMixMenu: [LocatorStep] =
    toTheMenuBar + [
      LocatorStep(role: "AXMenuBarItem", title: "Mix"),
      LocatorStep(role: "AXMenu"),
    ]

  /// The walk from the application of Logic to the items of the Create Track Automation submenu.
  private static let toTheCreateTrackAutomationMenu: [LocatorStep] =
    toTheMixMenu + [
      LocatorStep(role: "AXMenuItem", title: "Create Track Automation"),
      LocatorStep(role: "AXMenu"),
    ]

  /// The walk from the application of Logic to the items of the Convert Automation submenu.
  private static let toTheConvertAutomationMenu: [LocatorStep] =
    toTheMixMenu + [
      LocatorStep(role: "AXMenuItem", title: "Convert Automation"),
      LocatorStep(role: "AXMenu"),
    ]

  /// The walk from the application of Logic to the items of its Window menu.
  private static let toTheWindowMenu: [LocatorStep] =
    toTheMenuBar + [
      LocatorStep(role: "AXMenuBarItem", title: "Window"),
      LocatorStep(role: "AXMenu"),
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
  ///
  /// The group is named by what Logic calls it, because its place moves with the panes a person has
  /// open. Every pane is a group of the window, so the Library takes a place of its own while it is
  /// open. A project Logic has just made shows no Library, and the tracks are the third group there
  /// and the fourth group of a project that shows one.
  private static let toTheTracksHeader: [LocatorStep] = [
    LocatorStep(role: "AXWindow"),
    LocatorStep(role: "AXGroup", description: "Tracks"),
    LocatorStep(role: "AXGroup", index: 1),
    LocatorStep(role: "AXSplitGroup", index: 0),
    LocatorStep(role: "AXSplitGroup", index: 1),
    LocatorStep(role: "AXScrollArea", index: 0),
    LocatorStep(role: "AXGroup", index: 0),
  ]
}
