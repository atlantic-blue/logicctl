import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// The version of Logic every recorded tree came from.
private let recordedVersion = "12.3.1"

/// Where the recorded trees sit. They are read from the source tree, because the folder sits beside
/// the test targets rather than inside one.
private let recordedTrees = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// What one run of the command wrote, on each channel, and the number it exited with.
private struct Answer {
  let out: String
  let err: String
  let status: Int32

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// What the answer carries under `data`.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }

  /// The rows the answer carries under `data.points`.
  func points() throws -> [[String: Any]] {
    try data()["points"] as? [[String: Any]] ?? []
  }

  /// The error the answer carries, or an empty object when it carried none.
  func error() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }
}

/// One element of a tree a test drives, which keeps what is written to it and answers it again.
///
/// It is a class, so a selection written at a region item lands on the element the command read,
/// the way it lands in Logic. It also counts every read of the elements under it, which is how a
/// test says whether a command asked Logic what a window holds.
private final class Element: AXNode {
  var role: String
  var title: String? = nil
  var identifier: String? = nil
  var value: String? = nil
  var valueDescription: String? = nil
  var description: String? = nil
  var help: String? = nil
  var actions: [String] = []

  var children: [any AXNode] {
    reads += 1
    read?()
    return kept
  }

  /// How many times anything read the elements under this one.
  private(set) var reads = 0

  /// What a test is told each time the elements under this one are read.
  var read: (() -> Void)? = nil

  /// True while Logic holds this region item selected. No tree carries a selection, so the command
  /// reads it through the closures of `RegionSelection` and never through `AXNode`.
  var held = false

  private let kept: [any AXNode]

  init(of node: any AXNode) {
    role = node.role
    title = node.title
    identifier = node.identifier
    value = node.value
    valueDescription = node.valueDescription
    description = node.description
    help = node.help
    actions = node.actions
    kept = node.children.map { Element(of: $0) }
  }

  init(role: String, children: [any AXNode]) {
    self.role = role
    kept = children
  }

  /// Forgets the reads made while the fake was built.
  func forget() {
    reads = 0
  }
}

/// One recorded window, read from the tree `inspect` wrote.
private func recorded(_ tree: String) throws -> any AXNode {
  try RecordedTree(contentsOf: recordedTrees.appending(path: tree)).root
}

/// The Tracks window of a project whose tracks 3, 4 and 5 each carry a region.
///
/// `mixer-and-event-list-in-front.json` is a whole application, and its Tracks window is the one
/// recorded tree that holds a region item on more than one track. Only that window is taken, so the
/// Event List of this test is the one its points were read from.
private func theTracksWindowOfThreeRegions() throws -> any AXNode {
  let application = try recorded("mixer-and-event-list-in-front.json")
  guard
    let window = application.children.first(where: { ($0.title ?? "").hasSuffix(" - Tracks") })
  else {
    throw AFakeLogic.ShowsNoTracksWindow()
  }
  return window
}

/// A Logic that shows the Tracks window of a project, and the Event List of one region when it has
/// one open.
private final class AFakeLogic {
  /// None of the windows this fake was given is a Tracks window, so it holds no region to select.
  struct ShowsNoTracksWindow: Error {}

  /// The Tracks window, as Logic answers it.
  let tracks: Element

  /// Every region item of the Tracks window, in the order Accessibility answers them.
  let regions: [Element]

  /// What Logic was asked to do, in order, with a repeat of the same thing read as one.
  private(set) var did: [String] = []

  /// The Event List window, or nothing when Logic is showing none.
  private let events: Element?

  /// The table of events. A read of it is a read of the Event List.
  private let table: Element?

  /// The region item each track carries, against the number of that track.
  private let ofTrack: [Int: Element]

  /// Whether a write of `AXSelected` lets a region go.
  ///
  /// Logic toggles the item, so a write on a region it holds lets that region go. A Logic that
  /// keeps it is what a readback holding a region nobody named comes from.
  private let theWriteLetsARegionGo: Bool

  init(
    tracks: any AXNode, events: (any AXNode)? = nil, theWriteLetsARegionGo: Bool = true
  ) throws {
    self.tracks = Element(of: tracks)
    self.events = events.map { Element(of: $0) }
    self.theWriteLetsARegionGo = theWriteLetsARegionGo
    if let window = self.events {
      table = try LocatorResolver.element(of: Locators.eventListTable, in: window) as? Element
    } else {
      table = nil
    }
    guard let group = AFakeLogic.contents(of: self.tracks) else {
      throw ShowsNoTracksWindow()
    }
    regions = AFakeLogic.regionItems(under: group)
    ofTrack = AFakeLogic.regionsOfTheTracks(under: group)
    table?.forget()
    table?.read = { [weak self] in self?.record("read the Event List") }
  }

  /// The windows Logic is showing.
  ///
  /// The Tracks window comes first. A walk looking for the region items stops at the first group it
  /// finds, so it never reaches the Event List, and a read of that table is a read a command made.
  var tree: LogicTree {
    var showing: [any AXNode] = [tracks]
    if let events {
      showing.append(events)
    }
    return LogicTree(
      logicVersion: recordedVersion,
      root: Element(role: "AXApplication", children: showing))
  }

  /// How many times anything read the table of the Event List.
  var readsOfTheEventListTable: Int {
    table?.reads ?? 0
  }

  /// How Logic selects a region: a write of `AXSelected` toggles the item it lands on.
  var selection: AutomationMenus.RegionSelection {
    AutomationMenus.RegionSelection(
      holds: { ($0 as? Element)?.held ?? false },
      write: { item in
        guard let region = item as? Element else {
          return
        }
        if region.held {
          region.held = !self.theWriteLetsARegionGo
        } else {
          region.held = true
        }
        self.record("select the region")
      },
      same: { one, other in
        guard let left = one as? Element, let right = other as? Element else {
          return false
        }
        return left === right
      })
  }

  /// Says Logic holds the regions of these tracks selected, and no other region.
  func hold(theRegionsOfTracks tracks: [Int]) {
    for region in regions {
      region.held = false
    }
    for track in tracks {
      ofTrack[track]?.held = true
    }
  }

  /// The regions Logic holds selected, named by the track each one sits on.
  var heldRegions: [String] {
    regions.filter { $0.held }.map { region in
      guard let track = ofTrack.first(where: { $0.value === region })?.key else {
        return "a region on no track of its own"
      }
      return "the region of track \(track)"
    }
  }

  /// Keeps what Logic was asked to do. A repeat of the same thing is read as one, because a walk
  /// of a window reads what it holds more than once and the order is what a test asks about.
  private func record(_ what: String) {
    guard did.last != what else {
      return
    }
    did.append(what)
  }

  /// The group the Tracks window holds the tracks and their regions in.
  private static func contents(of node: Element) -> Element? {
    if node.description == RegionReader.contentsGroup {
      return node
    }
    for child in node.children.compactMap({ $0 as? Element }) {
      if let found = contents(of: child) {
        return found
      }
    }
    return nil
  }

  /// Every region item under one element, at any depth. A region holds no region, so the walk stops
  /// at the first one it finds on a branch.
  private static func regionItems(under node: Element) -> [Element] {
    node.children.compactMap { $0 as? Element }.flatMap { child -> [Element] in
      child.role == RegionReader.regionRole ? [child] : regionItems(under: child)
    }
  }

  /// The region item each track carries, against the number of that track.
  ///
  /// A track is the area at its own place under the group, with or without a description, which is
  /// how the Tracks window of Logic 12.3.1 answers the tracks of a project.
  private static func regionsOfTheTracks(under group: Element) -> [Int: Element] {
    let areas = group.children.compactMap { $0 as? Element }
      .filter { $0.role == RegionReader.trackRole }
    var found: [Int: Element] = [:]
    for (place, area) in areas.enumerated() {
      let items = area.children.compactMap { $0 as? Element }
        .filter { $0.role == RegionReader.regionRole }
      if let first = items.first {
        found[place + 1] = first
      }
    }
    return found
  }
}

/// The project the Tracks window was recorded from: three tracks, with one region on the third.
///
/// The names are the ones Logic shows in the recorded window, so the state of this test and the
/// windows it reads describe one project and not two.
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

/// A Logic showing the Tracks window of the recorded region and the Event List of that region.
private func aLogicShowingTheRegionAndItsEvents() throws -> AFakeLogic {
  try AFakeLogic(
    tracks: try recorded("region.json"), events: try recorded("event-list-automation.json"))
}

/// Runs `logicctl automation list` against a Logic of this test.
///
/// The project sits nowhere, which is a project that was never saved, so there is no session to
/// write a step into and nothing of this run touches the disk.
private func automationList(
  _ arguments: [String],
  against logic: AFakeLogic,
  tracks: [Track] = aProjectWithARegionOnTrack3()
) throws -> Answer {
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(["automation", "list"] + arguments)
  let list = try #require(typed as? Automation.List)
  let status = list.answer(
    driver: FakeLogicDriver(tracks: tracks),
    of: { logic.tree },
    selection: logic.selection,
    root: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// An agent reads the volume points of a region, and gets a number for each one that names it.
///
/// The number is the whole of what this answer is for. `automation set --point <n>` takes it, and
/// nothing else in Logic names a point: Logic draws an automation lane as one button with no
/// element per point, and it writes no number of its own on any row. So the number a point carries
/// here is the number the next command sends its edit to.
///
/// The Event List holds the fader rows and the note rows of the region in one table, in the same
/// columns, with a value where a velocity sits. The region this tree was recorded from holds three
/// points and four notes, and the notes sit between the first point and the second. So a reader
/// that counted every row would give point 2 to the note at 1 1 1 1, and an agent asking for
/// `--point 2` would move a note it never read about, while the point at 1 4 4 240 stayed where
/// Logic put it. Nothing later shows that: the region holds what it holds whichever rows were
/// counted, and this answer is the only place the mistake is visible.
///
/// The windows are the trees `inspect` recorded from Logic 12.3.1. The three points read as Logic
/// showed them, at 60, 90 and 110 on the fader scale, where 90 is 0 dB.
@Test func listReadsVolumeFromFaderRows() throws {
  let answer = try automationList(
    ["--track", "3", "--region", "1"],
    against: try aLogicShowingTheRegionAndItsEvents())

  let points = try answer.points()
  try #require(
    points.count == 3,
    "the region holds three automation points, and the table holds four more rows")

  let first = try #require(points.first)
  #expect(first["point"] as? Int == 1, "the number --point takes, from 1 in time order")
  #expect(first["position"] as? String == "1 1 1 1", "where Logic shows the point")
  #expect(first["parameter"] as? String == "Volume", "the parameter the point moves")
  #expect(first["value"] as? Int == 60, "the value Logic shows on the row, on the fader scale")

  #expect(points.map { $0["point"] as? Int } == [1, 2, 3], "numbered from 1, in time order")
  #expect(
    points.map { $0["position"] as? String } == ["1 1 1 1", "1 4 4 240", "2 1 1 1"],
    "the positions Logic shows, and none of 1 1 4 1, 1 3 1 1 or 1 3 4 1, where the notes sit")
  #expect(
    points.map { $0["value"] as? Int } == [60, 90, 110],
    "the values Logic shows, and none of the velocities 100, 70 and 64")
  #expect(
    points.allSatisfy { $0["parameter"] as? String == "Volume" },
    "volume is the parameter of every point of this region")

  #expect(try answer.data()["track"] as? Int == 3, "the track the command took")
  #expect(try answer.data()["region"] as? Int == 1, "the region the command took")
  #expect(answer.status == 0, "the command exits 0")
  #expect(answer.err == "", "standard error stays empty when a command worked")
}

/// An agent reads the points of one region, and gets the points of that region.
///
/// The Event List shows the region Logic holds selected. Measured on Logic 12.3.1 on 2026-09-27:
/// after a take, Logic held the regions of two tracks selected, and a read of a third region
/// answered the events of one of those two under a heading naming the third. The points of an
/// automation lane are numbered by where they sit among the fader rows of the list, so an answer
/// taken from the wrong region gives `automation set --point 2` a point of another part of a song.
///
/// So the region the command names is the only region Logic holds before the list is read.
@Test func listReadsThePointsOfTheNamedRegion() throws {
  let logic = try AFakeLogic(
    tracks: try theTracksWindowOfThreeRegions(),
    events: try recorded("event-list-automation.json"))
  logic.hold(theRegionsOfTracks: [4, 5])
  try #require(
    logic.heldRegions == ["the region of track 4", "the region of track 5"],
    "Logic holds the regions of two other tracks, as it does after a take")

  let answer = try automationList(["--track", "3", "--region", "1"], against: logic)

  #expect(
    logic.heldRegions == ["the region of track 3"],
    "the region the command named is the only region Logic holds")
  #expect(
    logic.did == ["select the region", "read the Event List"],
    "the selection lands before the read: a list read first shows the region of a moment ago"
  )
  #expect(try answer.points().count == 3, "the three points of the named region")
  #expect(answer.status == 0, "the command exits 0")
}

/// Logic is showing the Tracks window and no Event List, so there is nothing to read the points
/// from.
///
/// An empty list here would read as a region that carries no automation, and the agent would go on
/// to add points to a region that already has three.
@Test func listStopsWhenLogicShowsNoEventList() throws {
  let answer = try automationList(
    ["--track", "3", "--region", "1"],
    against: try AFakeLogic(tracks: try recorded("region.json")))

  #expect(answer.status == 5, "the number the design system gives element_not_found")
  #expect(try answer.error()["code"] as? String == "element_not_found")
  #expect(try answer.printed()["data"] is NSNull, "a failure carries no data")
}

/// The track is there and it carries no region with that number.
///
/// The answer says how many regions the track has, so a person or an agent asks again without
/// opening Logic to look.
@Test func listStopsWhenTheTrackHasNoSuchRegion() throws {
  let answer = try automationList(
    ["--track", "3", "--region", "2"],
    against: try aLogicShowingTheRegionAndItsEvents())

  #expect(answer.status == 17, "the number the design system gives region_not_found")
  #expect(try answer.error()["code"] as? String == "region_not_found")
  #expect(
    try answer.error()["details"] as? [String: Any] != nil,
    "the failure carries the numbers it was asked for")
}
