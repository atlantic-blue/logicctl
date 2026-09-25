import Foundation
import LogicctlCore
import LogicctlMac
import Testing

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
///
/// The folder is read from the source tree, and not as a resource of this test target, because it
/// sits beside the test targets rather than inside one.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

/// The trees that hold the window Logic shows the tracks area in.
private let tracksWindows = ["empty.json", "one-track.json", "region.json"]

/// The trees of that window that hold a track.
private let windowsWithATrack = ["one-track.json", "region.json"]

/// The tree of the window Logic shows while no project is open.
private let chooserWindows = ["project-chooser.json"]

/// The trees of the window Logic shows the events of one region in. One holds a region of three
/// notes, and one holds a region of four notes with volume automation on it.
private let eventLists = ["event-list-notes.json", "event-list-automation.json"]

/// The tree of the window Logic opens for File, "Save As...".
private let savePanels = ["save-as-window.json"]

/// The tree of the window Logic shows the channel strips in. It holds one track strip, then the
/// output strip and the master strip.
private let mixers = ["mixer.json"]

/// The trees of a project that has no tracks. Logic puts the sheet that asks for a track on a
/// project it has just made, and on a project whose last track was deleted.
private let emptyProjects = ["new-project-sheet.json", "empty.json"]

/// A locator, the recorded trees it is put to, and what the element it names reads as in them.
private struct ProvedLocator {
  /// The locator under test.
  let locator: Locator

  /// The recorded trees the walk is made in.
  let trees: [String]

  /// What the element is, in words, so a failure says which control was missed.
  let names: String

  /// Whether an element is the one the locator names, read from what Logic wrote about it.
  let holds: (any AXNode) -> Bool
}

/// Every locator of `Locators.swift`, with the trees it was read from and the element it names.
private func provedLocators() -> [ProvedLocator] {
  [
    ProvedLocator(
      locator: Locators.mainWindow,
      trees: tracksWindows,
      names: "the window Logic shows the tracks area in",
      holds: { $0.role == "AXWindow" && ($0.title ?? "").hasSuffix(" - Tracks") }),
    ProvedLocator(
      locator: Locators.tracksHeader,
      trees: tracksWindows,
      names: "the group that holds the header of every track",
      holds: { $0.description == "Tracks header" }),
    ProvedLocator(
      locator: Locators.tracksHeaderMuteButton,
      trees: windowsWithATrack,
      names: "the mute button of a track header",
      holds: { $0.role == "AXCheckBox" && $0.description == "Mute" }),
    ProvedLocator(
      locator: Locators.tracksHeaderSoloButton,
      trees: windowsWithATrack,
      names: "the solo button of a track header",
      holds: { $0.role == "AXCheckBox" && $0.description == "Solo" }),
    ProvedLocator(
      locator: Locators.transportPlayButton,
      trees: tracksWindows,
      names: "the play button of the Control Bar",
      holds: { $0.role == "AXCheckBox" && $0.title == "Play" }),
    ProvedLocator(
      locator: Locators.transportStopButton,
      trees: tracksWindows,
      names: "the stop button of the Control Bar",
      holds: { $0.role == "AXButton" && $0.title == "Stop" }),
    ProvedLocator(
      locator: Locators.transportRecordButton,
      trees: tracksWindows,
      names: "the record button of the Control Bar",
      holds: { $0.role == "AXCheckBox" && $0.title == "Record" }),
    ProvedLocator(
      locator: Locators.chooserWindow,
      trees: chooserWindows,
      names: "the window Logic shows while no project is open",
      holds: { $0.role == "AXWindow" && $0.title == "Choose a Project" }),
    ProvedLocator(
      locator: Locators.chooserEmptyProject,
      trees: chooserWindows,
      names: "the name of the first template the chooser offers",
      holds: { $0.role == "AXStaticText" && $0.value == "Empty Project" }),
    ProvedLocator(
      locator: Locators.chooserEmptyProjectTile,
      trees: chooserWindows,
      names: "the first template tile, which a press selects",
      holds: { $0.role == "AXButton" && $0.actions.contains("AXPress") }),
    ProvedLocator(
      locator: Locators.chooserChooseButton,
      trees: chooserWindows,
      names: "the button that opens the template the chooser has selected",
      holds: { $0.role == "AXButton" && $0.title == "Choose" }),
    ProvedLocator(
      locator: Locators.saveWindow,
      trees: savePanels,
      names: "the window Logic opens for File, Save As",
      holds: { $0.role == "AXWindow" && $0.title == "Save" }),
    ProvedLocator(
      locator: Locators.saveNameField,
      trees: savePanels,
      names: "the field that holds where the project goes",
      holds: { $0.role == "AXTextField" && $0.identifier == "saveAsNameTextField" }),
    ProvedLocator(
      locator: Locators.saveButton,
      trees: savePanels,
      names: "the button that writes the project where the field says",
      holds: { $0.role == "AXButton" && $0.title == "Save" }),
    ProvedLocator(
      locator: Locators.eventListWindow,
      trees: eventLists,
      names: "the window Logic shows the events of one region in",
      holds: { $0.role == "AXWindow" && ($0.title ?? "").hasSuffix(" - Event List") }),
    ProvedLocator(
      locator: Locators.eventListTable,
      trees: eventLists,
      names: "the table of events of the Event List",
      holds: { table in
        table.role == "AXTable" && table.children.contains { $0.role == "AXRow" }
      }),
    ProvedLocator(
      locator: Locators.mixerWindow,
      trees: mixers,
      names: "the window Logic shows the channel strips in",
      holds: { $0.role == "AXWindow" && ($0.title ?? "").contains(" - Mixer") }),
    ProvedLocator(
      locator: Locators.mixerStrips,
      trees: mixers,
      names: "the area of the Mixer that holds one channel strip per track",
      holds: { area in
        area.role == "AXLayoutArea" && area.children.contains { $0.role == "AXLayoutItem" }
      }),
    ProvedLocator(
      locator: Locators.newTrackSheet,
      trees: emptyProjects,
      names: "the sheet Logic puts on a project that has no tracks",
      holds: { $0.role == "AXSheet" && $0.description == "New Track" }),
  ]
}

/// A locator is the only address logicctl has for anything inside Logic.
///
/// A path that lands on another element presses a control nobody named, and no read afterwards can
/// tell that it happened. The pipeline has no Logic, so the trees that `inspect` recorded from
/// Logic 12.3.1 are the only place a path can be put to Logic before a person runs the tool on
/// this Mac. Every locator is walked in the trees it was read from, and the element it reaches has
/// to be the element it names: the window of the tracks area, the group of the track headers, the
/// mute and solo buttons of a track, and the play, stop and record buttons of the transport. A
/// walk that matched nothing, or that matched more than one element, stops with a refusal and
/// fails this too. A table with nothing in it fails as well, because a run that walked no locator
/// reports success in the same words as a run that walked them all.
@Test func everyLocatorResolvesInItsFixture() throws {
  let proved = provedLocators()
  try #require(!proved.isEmpty, "no locator was put to a tree, so this run proves nothing")
  #expect(
    Set(proved.map { $0.locator.name }) == Set(Locators.all.map { $0.name }),
    "every locator of the file is put to the trees it was read from")

  for entry in proved {
    #expect(
      entry.locator.recordedFrom == Locators.recordedFrom,
      "\(entry.locator.name) says which Logic its path came from")
    try #require(
      !entry.trees.isEmpty, "\(entry.locator.name) names a tree, so that it proves something")

    for tree in entry.trees {
      let root = try treeRoot(of: tree)
      let element = try LocatorResolver.element(of: entry.locator, in: root)
      #expect(entry.holds(element), "\(entry.locator.name) finds \(entry.names) in \(tree)")
    }
  }
}

/// A person reading a refusal has to know which walk Logic refused.
///
/// The empty project holds no track, so the mute button of a track header is not there to find.
/// The command that asked for it exits 5 with `element_not_found`, and the name of the locator
/// goes out with it: that name is what a person looks up in `Locators.swift` when a later Logic
/// moves the path.
@Test func aLocatorThatMatchesNothingFailsWithItsName() throws {
  let root = try treeRoot(of: "empty.json")
  let refused = #expect(throws: LocatorResolver.Refusal.self) {
    try LocatorResolver.element(of: Locators.tracksHeaderMuteButton, in: root)
  }

  let refusal = try #require(refused)
  #expect(refusal.matched == 0, "the step found nothing")
  #expect(refusal.failure.code == .elementNotFound, "the code a caller reads")
  #expect(refusal.failure.code.exitCode == 5, "the number the process exits with")
  #expect(
    locatorNamed(in: refusal.failure) == Locators.tracksHeaderMuteButton.name,
    "the failure names the locator that found nothing")
}

/// The three ways a step names an element do not last as long as each other.
///
/// An identifier Logic gives an element of its own stands in every project. A title stands until
/// the language of Logic changes. An index is the place of the element among the elements of its
/// role, and Logic moves it as soon as it shows another control. So a step that carries more than
/// one of them is read strongest first, and this is the tree that tells the three apart: each way
/// of naming reaches a different element of the same role.
@Test func theIdentifierIsReadBeforeTheTitleAndTheTitleBeforeTheIndex() throws {
  let root = try treeRead(from: threeButtons).root

  let byIdentifier = Locator(
    name: "test.byIdentifier",
    path: [
      LocatorStep(role: "AXWindow"),
      LocatorStep(role: "AXButton", identifier: "wanted", title: "second", index: 2),
    ])
  let byTitle = Locator(
    name: "test.byTitle",
    path: [
      LocatorStep(role: "AXWindow"),
      LocatorStep(role: "AXButton", title: "second", index: 2),
    ])
  let byIndex = Locator(
    name: "test.byIndex",
    path: [LocatorStep(role: "AXWindow"), LocatorStep(role: "AXButton", index: 2)])

  #expect(try LocatorResolver.element(of: byIdentifier, in: root).title == "first")
  #expect(try LocatorResolver.element(of: byTitle, in: root).title == "second")
  #expect(try LocatorResolver.element(of: byIndex, in: root).title == "third")
}

/// Two elements answer a step, and the walk takes neither.
///
/// Logic shows several controls of one role side by side, so a step that names two of them names
/// the wrong one half the time. The walk stops instead, and the caller reads how many elements the
/// step found rather than a change to a control nobody asked for.
@Test func aStepThatMatchesTwoElementsStopsTheWalk() throws {
  let root = try treeRead(from: twoOfOneName).root
  let locator = Locator(
    name: "test.twice",
    path: [LocatorStep(role: "AXWindow"), LocatorStep(role: "AXButton", title: "twice")])

  let refused = #expect(throws: LocatorResolver.Refusal.self) {
    try LocatorResolver.element(of: locator, in: root)
  }

  let refusal = try #require(refused)
  #expect(refusal.matched == 2, "both elements answered the step")
  #expect(refusal.failure.code == .elementNotFound, "the walk stopped, so nothing was found")
  #expect(locatorNamed(in: refusal.failure) == "test.twice", "the failure names the walk")
}

/// Three buttons of one role: one with an identifier, one with a title, and one with neither.
private let threeButtons = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXWindow",
      "children": [
        { "role": "AXButton", "identifier": "wanted", "title": "first" },
        { "role": "AXButton", "title": "second" },
        { "role": "AXButton", "title": "third" }
      ]
    }
  }
  """

/// Two buttons that carry the same title.
private let twoOfOneName = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXWindow",
      "children": [
        { "role": "AXButton", "title": "twice" },
        { "role": "AXButton", "title": "twice" }
      ]
    }
  }
  """

/// The element a recorded tree starts at.
private func treeRoot(of file: String) throws -> any AXNode {
  try RecordedTree(contentsOf: fixtureFolder.appending(path: file)).root
}

/// A tree written in a test, read back the way a recorded tree is read.
private func treeRead(from text: String) throws -> RecordedTree {
  try JSONDecoder().decode(RecordedTree.self, from: Data(text.utf8))
}

/// The locator a failure names, or nil when it names none.
private func locatorNamed(in failure: Failure) -> String? {
  guard case .object(let fields)? = failure.details,
    case .string(let name)? = fields["locator"]
  else {
    return nil
  }
  return name
}
