import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// The version of Logic every recorded tree came from.
private let recordedVersion = "12.3.1"

/// Where the recorded trees sit. They are read from the source tree, because the folder sits
/// beside the test targets rather than inside one.
private let recordedTrees = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// What one run of the command wrote, on each channel, and the number it exited with.
private struct Answer {
  let out: String
  let err: String
  let status: Int32

  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }

  func points() throws -> [[String: Any]] {
    try data()["points"] as? [[String: Any]] ?? []
  }

  func error() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }
}

/// One element of the tree this test holds two recorded windows under.
private struct Element: AXNode {
  var role: String
  var title: String?
  var identifier: String?
  var value: String?
  var valueDescription: String?
  var description: String?
  var help: String?
  var actions: [String] = []
  var children: [any AXNode] = []
}

/// One item of a menu of the fake Logic, with what Accessibility answers for `AXEnabled` on it.
///
/// Logic carries that answer on every item of its menu bar. An item it answers `false` on takes
/// no press, so the state of the item is part of what a press of it means.
private struct AMenuItem: AXNode {
  let role = "AXMenuItem"
  let title: String?
  let identifier: String? = nil
  let value: String? = nil
  let valueDescription: String? = nil
  let description: String? = nil
  let help: String? = nil
  let actions = ["AXPress"]
  let children: [any AXNode] = []

  /// What Logic answers for `AXEnabled` on this item.
  let enabled: Bool
}

/// One item of the Mix menu that opens a submenu, holding the one item of that submenu.
private func aSubmenu(_ title: String, holding item: any AXNode) -> Element {
  Element(
    role: "AXMenuItem", title: title,
    children: [Element(role: "AXMenu", children: [item])])
}

/// A clock and a sleep the test moves itself, so a wait of any length costs the suite no time.
private final class Time {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// One recorded window, read from the tree `inspect` wrote.
private func recorded(_ tree: String) throws -> any AXNode {
  try RecordedTree(contentsOf: recordedTrees.appending(path: tree)).root
}

/// A Logic that shows the Tracks window and the Event List of one region, and gains the automation
/// points once both items of the Mix menu are pressed.
///
/// The Event List answers the tree Logic recorded before the points were made until the second
/// press, and the tree it recorded of the same region with three points in it afterwards. So the
/// points can only reach the answer through the two presses, and a command that read the Event
/// List before pressing, or after only the first press, finds no point at all.
///
/// Logic draws in the Event List the region that is selected, and it keeps drawing what it drew
/// until the selection changes. So a scenario says what the list waits for. The default is the
/// second press, and a scenario of the redraw waits for the region to be taken again after it.
private final class AFakeLogic {
  /// The title of the item that makes the points at the borders of the selected region.
  static let createTitle = "Create 2 Automation Points at Region Borders"

  /// The title of the item that moves those points into the region.
  static let convertTitle = "Convert Visible Track Automation to Region Automation"

  private let tracks: any AXNode
  private let before: any AXNode
  private let after: any AXNode

  /// What the command asked Logic to do, in order. A press is named by the title of the menu item
  /// it pressed, because the title is the whole of what tells two items of one submenu apart.
  private(set) var did: [String] = []

  /// The regions the command selected, as Logic names each one.
  private(set) var selected: [String] = []

  /// The window that held the focus at each press, in the order the presses went in.
  private(set) var focusedAtEachPress: [String] = []

  /// How many times the command raised the Tracks window.
  private(set) var raises = 0

  /// The window Logic holds the focus on.
  private var focused: String

  /// True once both items of the Mix menu were pressed.
  private var converted = false

  /// The items Logic answers `AXEnabled` false on, whichever window holds the focus.
  private let notOffered: Set<String>

  /// How many walks of the menu bar answer false on an item before Logic offers it.
  private let offeredAfterWalks: [String: Int]

  /// How many times the walk resolved each item.
  private var walks: [String: Int] = [:]

  /// Whether the raise gives the Tracks window the focus.
  private let theRaiseTakesTheFocus: Bool

  /// A clock the fake moves itself, so a wait of any length costs the suite no time.
  private let time = Time()

  /// How the Tracks window is selected, or nothing when the scenario only records which region
  /// the command named.
  private let selection: AutomationMenus.RegionSelection?

  /// What the Event List waits for after the second press, beside the press itself.
  private let theEventListShowsThePoints: () -> Bool

  /// The regions this Logic holds selected, as it describes each one.
  ///
  /// A scenario that gives a selection of its own drives the items of its own window. A scenario
  /// that drives a window `inspect` recorded holds no such item, so its selection is the one this
  /// fake answers with.
  private var heldRegions: Set<String> = []

  init(
    tracks: any AXNode, before: any AXNode, after: any AXNode,
    selection: AutomationMenus.RegionSelection? = nil,
    theEventListShowsThePoints: @escaping () -> Bool = { true },
    theEventListHasTheFocus: Bool = false,
    itDoesNotOffer notOffered: Set<String> = [],
    itIsOfferedAfterWalks offeredAfterWalks: [String: Int] = [:],
    theRaiseTakesTheFocus: Bool = true
  ) {
    self.tracks = tracks
    self.before = before
    self.after = after
    self.selection = selection
    self.theEventListShowsThePoints = theEventListShowsThePoints
    self.notOffered = notOffered
    self.offeredAfterWalks = offeredAfterWalks
    self.theRaiseTakesTheFocus = theRaiseTakesTheFocus
    self.focused = theEventListHasTheFocus ? (before.title ?? "") : (tracks.title ?? "")
  }

  /// How many times the walk of the menu bar resolved one item.
  func walksOf(_ item: String) -> Int {
    walks[item] ?? 0
  }

  /// The clock every wait of the command reads. The fake moves it itself, so a wait of any length
  /// costs the suite no time.
  var clock: Wait.Clock {
    time.read
  }

  /// The sleep every wait of the command takes between two reads, which moves that same clock.
  var sleeper: Wait.Sleeper {
    time.sleep
  }

  /// The selection the command drives when it takes the region again.
  ///
  /// It is the selection of the scenario when it gave one, so the writes of the command land on
  /// the items the first select wrote on, and one scenario counts them in one place. The selection
  /// of the running Logic answers nothing on a recorded node, so a scenario that gave none drives
  /// the one below.
  var selectionForTheCommand: AutomationMenus.RegionSelection {
    selection
      ?? AutomationMenus.RegionSelection(
        holds: { item in self.heldRegions.contains(item.description ?? "") },
        write: { item in self.toggle(item.description ?? "") },
        same: { one, other in one.description == other.description })
  }

  /// One write of `AXSelected` on a region of a recorded window, which toggles that region.
  private func toggle(_ region: String) {
    if heldRegions.contains(region) {
      heldRegions.remove(region)
    } else {
      heldRegions.insert(region)
    }
  }

  /// The title of the window the tracks sit in, which is the window a press has to land in.
  var tracksWindowTitle: String {
    tracks.title ?? ""
  }

  /// The windows Logic is showing, and the menu bar it keeps beside them.
  var tree: LogicTree {
    LogicTree(
      logicVersion: recordedVersion,
      root: Element(
        role: "AXApplication",
        children: [tracks, theEventList, theMenuBar]))
  }

  /// The Event List window Logic is showing: the region with its points once both presses landed
  /// and the list redrew, and the region with its notes alone until then.
  private var theEventList: any AXNode {
    converted && theEventListShowsThePoints() ? after : before
  }

  /// The menu bar of Logic, with the two items of the Mix menu this command presses.
  ///
  /// Measured on this Mac on 2026-09-27: Logic answers `AXEnabled` false on the convert item
  /// while the Event List window holds the focus, and true once the Tracks window holds it with
  /// a region selected. The create item answered true in both, and a press of it from the Event
  /// List still made nothing, so the state of the item is not the whole of what a press needs.
  ///
  /// The state of each item is decided here, while the menu bar is built, which is what Logic
  /// does while the menu is walked. An item carries the answer of its own walk, so a command
  /// holding an element from an earlier walk reads what that walk said and nothing later.
  private var theMenuBar: any AXNode {
    let create = AMenuItem(title: AFakeLogic.createTitle, enabled: offers(AFakeLogic.createTitle))
    let convert = AMenuItem(
      title: AFakeLogic.convertTitle,
      enabled: offers(AFakeLogic.convertTitle) && focused == tracksWindowTitle)
    return Element(
      role: "AXMenuBar",
      children: [
        Element(
          role: "AXMenuBarItem", title: "Mix",
          children: [
            Element(
              role: "AXMenu",
              children: [
                aSubmenu("Create Track Automation", holding: create),
                aSubmenu("Convert Automation", holding: convert),
              ])
          ])
      ])
  }

  /// Whether Logic offers one item at the walk it is being resolved in.
  ///
  /// A scenario names the items Logic never offers, and the items it offers only from a later
  /// walk. Measured on this Mac on 2026-09-27: straight after the create item was pressed, the
  /// convert item answered false, and a walk from the application one second later, with
  /// nothing else done and nothing else moved, answered true.
  private func offers(_ title: String) -> Bool {
    !notOffered.contains(title) && walksOf(title) > (offeredAfterWalks[title] ?? 0)
  }

  /// The application of Logic, walked again from the top.
  ///
  /// Each walk resolves the two items again, and that is where their state is decided, so a
  /// walk is what moves an item Logic is on its way to offering.
  private func theApplicationWalkedAgain() -> any AXNode {
    for title in [AFakeLogic.createTitle, AFakeLogic.convertTitle] {
      walks[title] = (walks[title] ?? 0) + 1
    }
    return tree.root
  }

  /// What the command drives Logic through.
  var menus: AutomationMenus {
    AutomationMenus(
      press: { locator in
        try AutomationMenus.pressTheItem(
          locator, of: { self.theApplicationWalkedAgain() },
          offered: { item in (item as? AMenuItem)?.enabled ?? false },
          act: { item in
            self.did.append(item.title ?? locator.name)
            self.focusedAtEachPress.append(self.focused)
            if locator.name == Locators.convertTrackAutomationToRegionAutomation.name {
              self.converted = true
            }
          },
          clock: self.time.read,
          sleeper: self.time.sleep)
      },
      select: { region in
        self.did.append("select")
        self.selected.append(region.description ?? "")
        if let selection = self.selection {
          try selection.makeTheOnlySelection(region, under: self.tracks)
        } else {
          self.heldRegions = [region.description ?? ""]
        }
      },
      raiseTheTracksWindow: {
        self.raises += 1
        let window = AutomationMenus.TracksWindow(
          raise: {
            if self.theRaiseTakesTheFocus {
              self.focused = self.tracksWindowTitle
            }
          },
          hasTheFocus: { self.focused == self.tracksWindowTitle })
        try window.reach(clock: self.time.read, sleeper: self.time.sleep)
      })
  }
}

/// The project the Tracks window was recorded from: three tracks, with one region on the third.
///
/// The names are the ones Logic shows in the recorded window, so the state of this test and the
/// window it drives describe one project and not two.
private func aProjectWithARegionOnTrack3() -> [Track] {
  [
    Track(index: 1, name: "Deluxe Classic", type: .softwareInstrument),
    Track(index: 2, name: "Deluxe Classic", type: .softwareInstrument),
    Track(
      index: 3,
      name: "Studio Grand",
      type: .softwareInstrument,
      regions: [Region(index: 1, name: "MIDI Region", start: "1 bar", end: "2 bars")]),
  ]
}

/// Runs `logicctl automation add` against a Logic of this test.
private func automationAdd(
  _ arguments: [String],
  logic: AFakeLogic,
  tracks: [Track] = aProjectWithARegionOnTrack3(),
  path: String? = nil,
  root: URL? = nil
) throws -> Answer {
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(["automation", "add"] + arguments)
  let add = try #require(typed as? Automation.Add)
  let status = add.answer(
    driver: FakeLogicDriver(tracks: tracks, path: path),
    of: { logic.tree },
    confirmed: add.guarded.confirm,
    menus: logic.menus,
    selection: logic.selectionForTheCommand,
    root: root ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
    clock: logic.clock,
    sleeper: logic.sleeper,
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A person asks for automation points at the borders of a region, and reads every point Logic
/// made.
///
/// The menu item a person presses by hand reads "Create 2 Automation Points at Region Borders",
/// and the region ends up holding three: one at each border and one where the fader already sat.
/// The probe of Logic 12.3.1 watched exactly that happen. So the number in the title of the menu
/// item is what was asked for, and it is not what the region holds afterwards.
///
/// That gap is the whole value of this command. An agent that read "2 points" goes on to edit
/// point 1 and point 2 with `automation set`, and the third point stays where Logic put it, at a
/// value nobody chose, shaping the volume of the region for the rest of the session. Nothing later
/// shows the mistake: the region holds three points whichever number the answer printed, and only
/// this answer says whether logicctl knew about the third one.
///
/// Both windows are the trees `inspect` recorded from Logic 12.3.1. The Event List before the
/// presses is the same region with no automation in it, so every point in the answer came through
/// the two items of the Mix menu.
@Test func addPrintsEveryPointLogicMade() throws {
  let logic = AFakeLogic(
    tracks: try recorded("region.json"),
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"))

  try #require(
    AutomationMenus.points(in: try recorded("event-list-notes.json")).isEmpty,
    "the region carries no automation before the command runs")

  let answer = try automationAdd(["--track", "3", "--region", "1"], logic: logic)

  let points = try answer.points()
  #expect(
    points.count == 3,
    "Logic was asked for 2 points and made 3, and the answer carries every one of them")
  #expect(points.map { $0["point"] as? Int } == [1, 2, 3], "numbered from 1, in time order")
  #expect(
    points.map { $0["position"] as? String } == ["1 1 1 1", "1 4 4 240", "2 1 1 1"],
    "each point sits where the Event List shows it")
  #expect(
    points.map { $0["value"] as? Int } == [60, 90, 110],
    "each point carries the value Logic shows on its row, on the fader scale")
  #expect(
    points.allSatisfy { $0["parameter"] as? String == "Volume" },
    "volume is the parameter these points move")

  #expect(try answer.data()["track"] as? Int == 3, "the track the command took")
  #expect(try answer.data()["region"] as? Int == 1, "the region the command took")

  #expect(
    logic.selected == ["MIDI Region"],
    "the region the two numbers name is selected, and nothing else is")
  #expect(
    logic.did == [
      "select",
      "Create 2 Automation Points at Region Borders",
      "Convert Visible Track Automation to Region Automation",
    ],
    "the region is selected, the points are made, and then they move into the region")
  #expect(answer.status == 0, "the command exits 0")
  #expect(answer.err == "", "standard error stays empty when a command worked")
}

/// A region the Tracks window does not show is not a region this command can select.
///
/// Logic makes the points at the borders of whatever region is selected. So a command that pressed
/// the menu item without selecting first would write points into somebody else's region, and the
/// answer would read as though it worked.
@Test func addStopsWhenTheTracksWindowDoesNotShowTheRegion() throws {
  let logic = AFakeLogic(
    tracks: try recorded("one-track.json"),
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"))

  let answer = try automationAdd(["--track", "3", "--region", "1"], logic: logic)

  #expect(answer.status == 5, "the number the design system gives element_not_found")
  #expect(try answer.error()["code"] as? String == "element_not_found")
  #expect(logic.did.isEmpty, "no item of the Mix menu was pressed")
  #expect(try answer.printed()["data"] is NSNull, "a failure carries no data")
}

/// A person opens a project they wrote themselves, and an agent asks logicctl to add points to it.
///
/// The work in that project is theirs, so logicctl does not change it on its own word. The agent
/// reads `confirm_required` and exit 7, no item of the Mix menu is pressed, and the region is as
/// the person left it. The person then says `--confirm`, and the same command goes through.
@Test func addingPointsToAProjectLogicctlDidNotMakeNeedsConfirm() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-automation-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let logic = AFakeLogic(
    tracks: try recorded("region.json"),
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"))

  let answer = try automationAdd(
    ["--track", "3", "--region", "1"],
    logic: logic,
    path: root.appending(path: "the-work-of-a-person.logicx").path,
    root: root)

  #expect(answer.status == 7, "the number the design system gives confirm_required")
  #expect(try answer.error()["code"] as? String == "confirm_required")
  #expect(logic.did.isEmpty, "nothing was selected and no item of the Mix menu was pressed")
}

/// A person adds automation to a region that sits on a track after the fourth row.
///
/// Logic writes a description on some of the areas under `Tracks contents` and none on the rest.
/// With seven tracks it describes four of them. An area with no description is still the row of a
/// track, and the number inside a description does not follow the row it sits on. So the place of
/// an area is the only thing that says which track it belongs to.
///
/// A person imports a MIDI file of seven tracks. The import puts a region on each of the last
/// three. The person sees those regions on the screen and asks for automation points on one of
/// them. Today the command answers that the Tracks window does not show that region, so the
/// person can add automation to the first four tracks alone, and the answer sends them to look
/// for a region that is there.
@Test func automationFindsARegionOnATrackAfterTheFourth() throws {
  let window = aTracksWindowOfSevenTracks()

  let onTheSixth = try #require(
    AutomationMenus.regionItem(number: 1, ofTrack: 6, in: window),
    "the sixth track is the sixth area, and that area carries no description")
  #expect(onTheSixth.description == "Sixth", "the region of the sixth row and of no other")

  #expect(
    AutomationMenus.regionItem(number: 1, ofTrack: 5, in: window)?.description == "Fifth",
    "the first area with no description is a track and not the room")
  #expect(
    AutomationMenus.regionItem(number: 1, ofTrack: 7, in: window)?.description == "Seventh",
    "and the last track keeps its own region")
  #expect(
    AutomationMenus.regionItem(number: 1, ofTrack: 8, in: window) == nil,
    "eight areas give seven tracks, because the last area is the room under the last track")

  let logic = AFakeLogic(
    tracks: window,
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"))

  let answer = try automationAdd(
    ["--track", "6", "--region", "1"],
    logic: logic,
    tracks: aProjectOfSevenImportedTracks())

  #expect(answer.status == 0, "the command goes through on a track after the fourth")
  #expect(logic.selected == ["Sixth"], "the region of track 6 is the one selected")
  #expect(
    logic.did == [
      "select",
      "Create 2 Automation Points at Region Borders",
      "Convert Visible Track Automation to Region Automation",
    ],
    "the region is selected, the points are made, and then they move into the region")
  #expect(try answer.data()["track"] as? Int == 6, "the track the command took")
  #expect(try answer.points().count == 3, "and the region carries every point Logic made")
}

/// One layout area of the Tracks window, with the description Logic gave it and what it carries.
private func anArea(_ description: String? = nil, holding regions: [any AXNode] = []) -> Element {
  Element(role: RegionReader.trackRole, description: description, children: regions)
}

/// One region of a track, as the Tracks window carries it.
private func aRegionItem(_ name: String, from start: String, to end: String) -> Element {
  Element(
    role: RegionReader.regionRole,
    description: name,
    help: "Region starts at \(start)  and ends at \(end) , MIDI region. ")
}

/// The Tracks window of seven tracks, described the way Logic 12.3.1 describes it after a MIDI
/// import.
///
/// Step 21 measured it on 2026-09-27. The group holds eight layout areas in the order of the rows
/// from the top. The first four carry a description whose number does not follow its row. The last
/// four carry none. The eighth is the room under the last track. Children of other roles stand
/// between some of the areas. Rows 5, 6 and 7 carry one region each.
private func aTracksWindowOfSevenTracks() -> any AXNode {
  Element(
    role: "AXWindow",
    title: "F-T13 - Tracks",
    children: [
      Element(
        role: "AXGroup",
        description: RegionReader.contentsGroup,
        children: [
          anArea("Track 1 \u{201C}Deluxe Classic\u{201D}"),
          Element(role: "AXButton", description: "Mute"),
          anArea("Track 3 \u{201C}Studio Grand\u{201D}"),
          Element(role: RegionReader.regionRole),
          anArea("Track 5 \u{201C}Studio Grand\u{201D}"),
          anArea("Track 7 \u{201C}Epic Cloud Formation\u{201D}"),
          anArea(holding: [aRegionItem("Fifth", from: "1 bar", to: "2 bars")]),
          Element(role: "AXButton", description: "Solo"),
          anArea(holding: [aRegionItem("Sixth", from: "3 bars", to: "4 bars")]),
          anArea(holding: [aRegionItem("Seventh", from: "58 bars", to: "59 bars")]),
          anArea(),
        ])
    ])
}

/// The project that window was written from: a MIDI import of seven tracks that put one region on
/// each of the last three.
///
/// The names and the borders are the ones the window carries, so the state of this test and the
/// window it drives describe one project and not two.
private func aProjectOfSevenImportedTracks() -> [Track] {
  let imported = [
    5: Region(index: 1, name: "Fifth", start: "1 bar", end: "2 bars"),
    6: Region(index: 1, name: "Sixth", start: "3 bars", end: "4 bars"),
    7: Region(index: 1, name: "Seventh", start: "58 bars", end: "59 bars"),
  ]
  return (1...7).map { index in
    var track = Track(index: index, name: "Studio Grand", type: .softwareInstrument)
    if let region = imported[index] {
      track.regions = [region]
    }
    return track
  }
}

/// A person adds automation to one region while Logic holds two other regions selected.
///
/// `midi import` leaves every region it made selected, and Logic makes the automation points at
/// the borders of every region that is selected. So a command that pressed the menu item as it
/// found Logic writes points into three regions, prints the points of the one the person named,
/// and reads as though it changed that one alone. The two other regions then carry a volume shape
/// nobody asked for, and nothing later in the session says where it came from.
///
/// A write of `AXSelected` on a region item does not take the value it is given. It toggles that
/// item. So a walk that wrote `true` on every region would let go of the ones Logic already holds,
/// and the items of this window answer the same way the Mac answered on 2026-09-27.
///
/// The second half is the Logic that does not take the selection. The command stops there and
/// presses nothing, because a press now makes the points at the borders of somebody else's
/// region.
@Test func automationSelectsTheNamedRegionAlone() throws {
  let shown = aTracksWindowOfFourRegions(holding: [6, 7])
  let logic = AFakeLogic(
    tracks: shown.window,
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"),
    selection: aSelectionThatAnswersLikeLogic())

  let answer = try automationAdd(
    ["--track", "3", "--region", "1"], logic: logic, tracks: aProjectOfFourRegions())

  #expect(answer.status == 0, "the command goes through")
  #expect(
    shown.regions.filter({ $0.value.held }).keys.sorted() == [3],
    "Logic holds the region of track 3, and it holds no other region")
  #expect(
    shown.regions[3]?.writes == 3,
    "the named region is written once to select it, and twice more to make Logic draw it again")
  #expect(
    shown.regions[6]?.writes == 1 && shown.regions[7]?.writes == 1,
    "each region Logic held is written once, which lets it go")
  #expect(
    shown.regions[5]?.writes == 0,
    "a region that is already as it should be is not written, because a write would select it")
  #expect(
    logic.did == [
      "select",
      "Create 2 Automation Points at Region Borders",
      "Convert Visible Track Automation to Region Automation",
    ],
    "the selection comes before the two items of the Mix menu")
  #expect(try answer.points().count == 3, "and the answer carries every point Logic made")

  let deaf = aTracksWindowOfFourRegions(holding: [6, 7], answering: false)
  let stubborn = AFakeLogic(
    tracks: deaf.window,
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"),
    selection: aSelectionThatAnswersLikeLogic())

  let refused = try automationAdd(
    ["--track", "3", "--region", "1"], logic: stubborn, tracks: aProjectOfFourRegions())

  #expect(refused.status == 70, "the number the design system gives internal")
  #expect(try refused.error()["code"] as? String == "internal")

  let message = try refused.error()["message"] as? String ?? ""
  #expect(
    message.contains("Sixth, Seventh"),
    "the answer names every region Logic still holds, so a person knows what to let go of")

  let details = try refused.error()["details"] as? [String: Any] ?? [:]
  #expect(
    details["selected"] as? [String] == ["Sixth", "Seventh"],
    "and the details carry them in the order the window answers them")
  #expect(stubborn.did == ["select"], "no item of the Mix menu was pressed")
  #expect(try refused.printed()["data"] is NSNull, "a failure carries no data")
}

/// One region item of a fake Tracks window, with the selection Logic holds on it and the number
/// of writes it took.
///
/// A write of `AXSelected` on a region item of Logic 12.3.1 does not take the value it is given.
/// It toggles the item. So this item toggles too, and a walk that writes on a region Logic
/// already holds lets that region go.
private final class ARegionItem: AXNode {
  let role = RegionReader.regionRole
  let title: String? = nil
  let identifier: String? = nil
  let value: String? = nil
  let valueDescription: String? = nil
  let description: String?
  let help: String?
  let actions: [String] = []
  let children: [any AXNode] = []

  /// Whether Logic holds this region selected.
  private(set) var held: Bool

  /// How many times `AXSelected` was written on this item.
  private(set) var writes = 0

  /// Whether the item answers a write at all. A Logic that takes no notice of the write is what
  /// the second half of the scenario drives.
  private let answers: Bool

  init(_ name: String, held: Bool, answers: Bool) {
    self.description = name
    self.help = "Region starts at 1 bar  and ends at 2 bars , MIDI region. "
    self.held = held
    self.answers = answers
  }

  /// One write of `AXSelected`, as Logic answers it.
  func write() {
    writes += 1
    if answers {
      held.toggle()
    }
  }
}

/// A Tracks window of seven tracks with one region on tracks 3, 5, 6 and 7, and the regions Logic
/// holds selected.
///
/// The group holds one layout area per track in the order of the rows from the top, and one more
/// after them, which is the room under the last track. `answering` says whether a write of
/// `AXSelected` changes the item.
private func aTracksWindowOfFourRegions(
  holding held: Set<Int>, answering: Bool = true
) -> (window: any AXNode, regions: [Int: ARegionItem]) {
  var regions: [Int: ARegionItem] = [:]
  for (track, name) in aRegionNamePerTrack {
    regions[track] = ARegionItem(name, held: held.contains(track), answers: answering)
  }
  let areas: [any AXNode] = (1...8).map { place in
    anArea(holding: regions[place].map { [$0 as any AXNode] } ?? [])
  }
  let window = Element(
    role: "AXWindow",
    title: "F-T13 - Tracks",
    children: [
      Element(role: "AXGroup", description: RegionReader.contentsGroup, children: areas)
    ])
  return (window as any AXNode, regions)
}

/// The name Logic shows on the one region of each track that carries one.
private let aRegionNamePerTrack = [3: "Third", 5: "Fifth", 6: "Sixth", 7: "Seventh"]

/// The selection of a window of this test. It reads and writes the items of that window, and it
/// tells two items apart by which object they are.
private func aSelectionThatAnswersLikeLogic() -> AutomationMenus.RegionSelection {
  AutomationMenus.RegionSelection(
    holds: { item in (item as? ARegionItem)?.held == true },
    write: { item in
      guard let region = item as? ARegionItem else {
        return
      }
      region.write()
    },
    same: { one, other in
      guard let left = one as? ARegionItem, let right = other as? ARegionItem else {
        return false
      }
      return left === right
    })
}

/// The project that window was written from: seven tracks, with one region on tracks 3, 5, 6 and
/// 7.
///
/// The names are the ones the window carries, so the state of this test and the window it drives
/// describe one project and not two.
private func aProjectOfFourRegions() -> [Track] {
  (1...7).map { index in
    var track = Track(index: index, name: "Studio Grand", type: .softwareInstrument)
    if let name = aRegionNamePerTrack[index] {
      track.regions = [Region(index: 1, name: name, start: "1 bar", end: "2 bars")]
    }
    return track
  }
}

/// A person adds automation while Logic shows the Event List in front, and Logic makes the points.
///
/// Measured on this Mac at 02:08 on 2026-09-27, on a copy of F-T13 with one region selected. With
/// the Event List window focused, a press of each of the two items of the Mix menu made nothing:
/// the Undo History of Logic gained no row and the region held no point. With the Tracks window
/// raised and focused, the same two presses made both actions and the region then held three
/// volume points. Logic also answers `AXEnabled` false on the convert item while the Event List
/// holds the focus.
///
/// So the window a press lands in is part of the press, and `automation add` raised no window.
/// The two runs on this Mac recorded the create and never the convert, the command exited 0, and
/// the region held nothing. A person reads three points from a region that has none, and every
/// later `automation set --point 1` then edits a point that is not there. Nothing later in the
/// session says where that went wrong, because the answer already said the points were made.
///
/// The four parts are the four ways that ends. The command reaches the window before it presses.
/// It waits for an item Logic is on its way to offering, and it walks to that item again for
/// every read, because Logic decides the state of an item while the menu is walked and an
/// element held from an earlier walk keeps the answer of that walk. An item Logic never offers
/// stops the command at that item, by name. A window that never takes the focus stops it with
/// the time it gave Logic.
@Test func automationPressesOnlyAnEnabledItemInTheTracksWindow() throws {
  let logic = AFakeLogic(
    tracks: try recorded("region.json"),
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"),
    theEventListHasTheFocus: true)

  let answer = try automationAdd(["--track", "3", "--region", "1"], logic: logic)

  #expect(answer.status == 0, "the command goes through from a Logic showing the Event List")
  #expect(logic.raises == 1, "the Tracks window is raised once")
  #expect(
    logic.focusedAtEachPress == [logic.tracksWindowTitle, logic.tracksWindowTitle],
    "both items are pressed while the Tracks window holds the focus, which is where they work")
  #expect(
    logic.did == [
      "select",
      AFakeLogic.createTitle,
      AFakeLogic.convertTitle,
    ],
    "the region is selected, the points are made, and then they move into the region")
  #expect(try answer.points().count == 3, "and the answer carries every point Logic made")

  // Logic offers the convert item a moment after the create, and only to a walk made after it.
  let late = AFakeLogic(
    tracks: try recorded("region.json"),
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"),
    itIsOfferedAfterWalks: [AFakeLogic.convertTitle: 2])

  let waitedForTheItem = try automationAdd(["--track", "3", "--region", "1"], logic: late)

  #expect(waitedForTheItem.status == 0, "the command waits for the item and then presses it")
  #expect(
    late.walksOf(AFakeLogic.convertTitle) == 3,
    "it walked to the item three times: two walks answered false, and the third answered true")
  #expect(
    late.did == [
      "select",
      AFakeLogic.createTitle,
      AFakeLogic.convertTitle,
    ],
    "both items are pressed, so the points move into the region")
  #expect(
    try waitedForTheItem.points().count == 3,
    "and the answer carries every point Logic made")

  // Logic will not offer the first item. The command says which item, and stops there.
  let refusing = AFakeLogic(
    tracks: try recorded("region.json"),
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"),
    itDoesNotOffer: [AFakeLogic.createTitle])

  let refused = try automationAdd(["--track", "3", "--region", "1"], logic: refusing)

  #expect(refused.status == 5, "the number the design system gives element_not_found")
  #expect(try refused.error()["code"] as? String == "element_not_found")
  #expect(
    try (refused.error()["message"] as? String ?? "").contains(AFakeLogic.createTitle),
    "the sentence names the item Logic would take no press of")
  let named = try refused.error()["details"] as? [String: Any]
  #expect(
    named?["item"] as? String == AFakeLogic.createTitle,
    "and the details carry that item, so an agent reads which press never happened")
  #expect(
    named?["waitedMs"] as? Int == 5000,
    "with the time Logic had to offer it, which is the limit of a wait that names none")
  #expect(
    refusing.walksOf(AFakeLogic.createTitle) > 1,
    "the walk to the item was made again and again, and not once")
  #expect(
    refusing.did == ["select"],
    "the item is not pressed, and nor is the item after it")
  #expect(try refused.printed()["data"] is NSNull, "a failure carries no data")

  // Logic never gives the Tracks window the focus. Nothing is selected and nothing is pressed.
  let deaf = AFakeLogic(
    tracks: try recorded("region.json"),
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"),
    theEventListHasTheFocus: true,
    theRaiseTakesTheFocus: false)

  let waited = try automationAdd(["--track", "3", "--region", "1"], logic: deaf)

  #expect(waited.status == 6, "the number the design system gives timeout")
  #expect(try waited.error()["code"] as? String == "timeout")
  let gave = try waited.error()["details"] as? [String: Any]
  #expect(
    gave?["waitedMs"] as? Int == 5000,
    "the wait says how long it gave Logic, and five seconds is the limit of a wait that names none")
  #expect(deaf.did.isEmpty, "no region was selected and no item of the Mix menu was pressed")
}

/// A person adds automation points, and reads the points Logic made rather than a sentence that
/// says it made none.
///
/// Measured on this Mac on 2026-09-27, on a fresh copy after `midi import`, with both items of the
/// Mix menu pressed. The Event List draws the region that is selected. It kept the notes of the
/// region for more than 30 seconds after the convert, and `automation list` read no point in it. A
/// wait alone does not redraw it. A write of `AXSelected` on the region item, and a second write
/// half a second later, drew the points at once. The region held four Volume points at value 90.
///
/// So today the command presses both items, reads the Event List once, finds the notes, and
/// answers `element_not_found`. Its sentence says Logic made no point. The region holds the points
/// by then, so the answer and the project disagree. A person reads that nothing happened and runs
/// the command again, and the region gains a second set of points at values nobody chose. An agent
/// reads a failure and stops.
///
/// The three parts are the three ways that ends. The command lets the region go, takes it again,
/// and then reads the points. The same Logic answers no point to a command that does not take the
/// region again. A list that never draws a point costs the command its wait and no more, and the
/// command says so with `timeout` rather than with an element that is missing.
@Test func automationSelectsTheRegionAgainBeforeItReadsThePoints() throws {
  let shown = aTracksWindowOfFourRegions(holding: [6, 7])
  let named = try #require(shown.regions[3], "the region of track 3 is the one the person names")
  let logic = AFakeLogic(
    tracks: shown.window,
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"),
    selection: aSelectionThatAnswersLikeLogic(),
    theEventListShowsThePoints: { named.writes == 3 && named.held })

  let answer = try automationAdd(
    ["--track", "3", "--region", "1"], logic: logic, tracks: aProjectOfFourRegions())

  #expect(answer.status == 0, "the command goes through")
  #expect(try answer.points().count == 3, "and it answers every point Logic made")
  #expect(
    try answer.points().map { $0["value"] as? Int } == [60, 90, 110],
    "each point carries the value the Event List shows on its row")
  #expect(
    named.writes == 3,
    "the region is written once to select it, and twice more to let it go and take it again")
  #expect(
    shown.regions.filter({ $0.value.held }).keys.sorted() == [3],
    "and the region the person named is the only region Logic holds at the end")

  // The same Logic, driven through the two presses and no second selection. Its Event List holds
  // no automation row, so the points above reached the answer through that selection and through
  // nothing else.
  let quiet = aTracksWindowOfFourRegions(holding: [6, 7])
  let alone = try #require(quiet.regions[3])
  let unrefreshed = AFakeLogic(
    tracks: quiet.window,
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"),
    selection: aSelectionThatAnswersLikeLogic(),
    theEventListShowsThePoints: { alone.writes == 3 && alone.held })
  let itsRegion = try #require(
    AutomationMenus.regionItem(number: 1, ofTrack: 3, in: quiet.window))

  try unrefreshed.menus.addPoints(atTheBordersOf: itsRegion)

  let list = try #require(EventList.window(of: unrefreshed.tree), "Logic shows the Event List")
  #expect(
    try AutomationMenus.points(in: list).isEmpty,
    "both items were pressed, and the list still draws the notes of the region alone")

  // A Logic that never draws a point. The command gives it the limit of a wait and then says how
  // long it gave it, on a clock this test moves itself.
  let silent = AFakeLogic(
    tracks: try recorded("region.json"),
    before: try recorded("event-list-notes.json"),
    after: try recorded("event-list-automation.json"),
    theEventListShowsThePoints: { false })

  let waited = try automationAdd(["--track", "3", "--region", "1"], logic: silent)

  #expect(waited.status == 6, "the number the design system gives timeout")
  #expect(try waited.error()["code"] as? String == "timeout")
  let gave = try waited.error()["details"] as? [String: Any] ?? [:]
  #expect(gave["track"] as? Int == 3, "the details carry the track the person named")
  #expect(gave["region"] as? Int == 1, "and the region on it, so an agent reads which region")
  #expect(
    gave["waitedMs"] as? Int == 5000,
    "with the time it gave Logic, which is the limit of a wait that names none")
  #expect(try waited.printed()["data"] is NSNull, "a failure carries no data")
}
