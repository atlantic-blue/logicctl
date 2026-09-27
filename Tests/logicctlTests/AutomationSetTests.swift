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

/// One recorded window, read from the tree `inspect` wrote.
private func recorded(_ tree: String) throws -> any AXNode {
  try RecordedTree(contentsOf: recordedTrees.appending(path: tree)).root
}

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

  /// What the answer carries under `data`, or an empty object when it carries none.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }

  /// The rows the answer carries under `data.points`.
  func points() throws -> [[String: Any]] {
    try data()["points"] as? [[String: Any]] ?? []
  }

  /// The failure the answer carries, or an empty object when it carries none.
  func failure() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }
}

/// One element of the tree a test drives, which keeps what is written to it and answers it again.
///
/// It is a class, so the command holds the elements the fake changes: a selection written at a row,
/// and a step of a slider, land on the element the command read, the way they land in Logic. A tree
/// of values would answer the same numbers however often it was written to, and a command that
/// changed nothing would read as a command that worked.
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

  /// True while Logic holds this row or this region item selected. No tree carries a selection,
  /// command reads this through the closures of `EventList.Actions` or of `RegionSelection`, and
  /// never through `AXNode`.
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

/// A Logic that shows the Tracks window and the Event List of one region, and moves what it is
/// asked to move.
///
/// The windows are the trees `inspect` recorded from Logic 12.3.1, read once. A write at a row
/// holds that row. A step of a slider changes the number Logic shows on it, which is where the
/// reader of the points takes a value from, and leaves the scaled number under it, which no reader
/// turns back into a value.
private final class AFakeLogic {
  /// The windows Logic is showing.
  let windows: [Element]

  /// The rows of the table of events, in the order the table answers them.
  let rows: [Element]

  /// Every region item of the Tracks window, in the order Accessibility answers them.
  let regions: [Element]

  /// How far each step moved a slider, in the order the steps went out.
  private(set) var steps: [Int] = []

  /// What Logic was asked to do, in order, with a repeat of the same thing read as one.
  private(set) var did: [String] = []

  /// The table of events. A read of it is a read of the Event List.
  private let table: Element

  /// The region item each track carries, against the number of that track.
  private let ofTrack: [Int: Element]

  /// None of the windows this fake was given is an Event List, so it holds no row to drive.
  struct ShowsNoEventList: Error {}

  /// None of the windows this fake was given is a Tracks window, so it holds no region to select.
  struct ShowsNoTracksWindow: Error {}

  init(showing windows: [any AXNode]) throws {
    self.windows = windows.map { Element(of: $0) }
    guard
      let events = self.windows.first(where: {
        ($0.title ?? "").hasSuffix(EventList.windowTitle)
      })
    else {
      throw ShowsNoEventList()
    }
    guard
      let found = try LocatorResolver.element(of: Locators.eventListTable, in: events) as? Element
    else {
      throw ShowsNoEventList()
    }
    table = found
    rows = found.children.compactMap { $0 as? Element }.filter { $0.role == "AXRow" }
    guard let group = self.windows.compactMap({ AFakeLogic.contents(of: $0) }).first else {
      throw ShowsNoTracksWindow()
    }
    regions = AFakeLogic.regionItems(under: group)
    ofTrack = AFakeLogic.regionsOfTheTracks(under: group)
    table.forget()
    table.read = { [weak self] in self?.record("read the Event List") }
  }

  /// The windows Logic is showing, in the order they were given. The Tracks window comes first,
  /// walk looking for the region items never reaches the Event List, and a read of that table is a
  /// read a command made.
  var tree: LogicTree {
    LogicTree(
      logicVersion: recordedVersion,
      root: Element(role: "AXApplication", children: windows))
  }

  /// How Logic selects a region: a write of `AXSelected` toggles the item it lands on.
  var selection: AutomationMenus.RegionSelection {
    AutomationMenus.RegionSelection(
      holds: { ($0 as? Element)?.held ?? false },
      write: { item in
        guard let region = item as? Element else {
          return
        }
        region.held = !region.held
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
  fileprivate static func contents(of node: Element) -> Element? {
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

  /// Where the rows Logic holds selected sit in the table, from 1.
  var heldRows: [Int] {
    rows.enumerated().filter { $0.element.held }.map { $0.offset + 1 }
  }

  /// The number in the value column of every row of the table, in the order of the table. A note
  /// row carries its velocity in that column, and a fader row carries the value of its point.
  var column: [Int] {
    rows.map { row in
      guard let slider = EventList.velocitySlider(of: row) else {
        return -1
      }
      return number(of: slider)
    }
  }

  /// What the command drives Logic through.
  var actions: EventList.Actions {
    EventList.Actions(
      select: { row, holding in
        (row as? Element)?.held = holding
      },
      selected: { row in
        (row as? Element)?.held ?? false
      },
      stepper: { slider in
        SliderStepper(
          read: { self.number(of: slider) },
          write: { asked in
            self.move(slider, by: asked > self.number(of: slider) ? 1 : -1)
          },
          act: { step in
            self.move(
              slider,
              by: step == .up ? SliderStepper.stepOfAnAction : -SliderStepper.stepOfAnAction)
          })
      })
  }

  /// The number Logic shows on one slider.
  private func number(of slider: any AXNode) -> Int {
    Int(slider.valueDescription ?? "") ?? -1
  }

  /// Moves one slider by one step, and records how far it went.
  private func move(_ slider: any AXNode, by step: Int) {
    guard let element = slider as? Element else {
      return
    }
    element.valueDescription = String(number(of: element) + step)
    steps.append(step)
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

/// A Logic showing the Tracks window and the Event List of the region on track 3.
private func aLogicShowingTheRegionAndItsEvents() throws -> AFakeLogic {
  try AFakeLogic(showing: [
    try recorded("region.json"),
    try recorded("event-list-automation.json"),
  ])
}

/// Runs one whole command line, the way a person types it, against a Logic that shows these
/// windows.
///
/// The project sits nowhere, which is a project that was never saved, so there is no session to
/// write a step into and nothing of this run touches the disk.
private func automationSet(_ arguments: [String], against logic: AFakeLogic) throws -> Answer {
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(arguments)
  let command = try #require(typed as? Automation.Set)
  let status = command.answer(
    driver: FakeLogicDriver(tracks: aProjectWithARegionOnTrack3()),
    of: { logic.tree },
    confirmed: false,
    events: logic.actions,
    selection: logic.selection,
    root: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A value belongs to one automation point, and every other event of the region keeps the number it
/// had.
///
/// Logic applies an edit to every row it holds selected, and the probe watched one edit of a single
/// automation point move a second point and all four note velocities by the same amount, because
/// they were all still selected. So the damage this command can do is silent: the answer reads as
/// though one point changed, and the region carries six changes that nobody asked for and that no
/// later read attributes to this command.
///
/// The region of the recorded tree carries three volume points at 60, 90 and 110, and four notes at
/// velocity 100, 70, 100 and 64 which sit in the same column of the same table, between the first
/// point and the second. Point 1 goes to 100. What this proves is what the other six rows read
/// afterwards: 90 and 110 for the two points, 100, 70, 100 and 64 for the notes, with every
/// position, every parameter, every pitch and every length as it was. The answer carries the points
/// as they read after the change, so a Logic that took the step and stopped at 80 could not report
/// 100.
///
/// The second half is the point that is not there. Point 9 of a region of three points stops the
/// command with `point_not_found`, and the count of the points goes out with it, so a person asks
/// again without opening Logic to look. Nothing is selected and no slider moves.
@Test func setChangesOnlyItsPoint() throws {
  let logic = try aLogicShowingTheRegionAndItsEvents()
  let events = try #require(EventList.window(of: logic.tree))
  let before = try EventList.notes(in: events)
  try #require(
    try AutomationMenus.points(in: events).map(\.value) == [60, 90, 110],
    "the three volume points Logic recorded")
  try #require(
    logic.column == [60, 100, 70, 100, 64, 90, 110],
    "the four note velocities share the column the values sit in")

  let answer = try automationSet(
    ["automation", "set", "--track", "3", "--region", "1", "--point", "1", "--value", "100"],
    against: logic)

  let points = try answer.points()
  #expect(
    points.map { $0["value"] as? Int } == [100, 90, 110],
    "point 1 carries 100, and the other two carry the values they carried")
  #expect(points.map { $0["point"] as? Int } == [1, 2, 3], "numbered from 1, in time order")
  #expect(
    points.map { $0["position"] as? String } == ["1 1 1 1", "1 4 4 240", "2 1 1 1"],
    "every point sits where it sat")
  #expect(
    points.allSatisfy { $0["parameter"] as? String == "Volume" },
    "volume is the parameter of every point of this region")
  #expect(try answer.data()["track"] as? Int == 3, "the track the region sits on")
  #expect(try answer.data()["region"] as? Int == 1, "the region the point sits in")
  #expect(
    try answer.data().keys.sorted() == ["points", "region", "track"],
    "the answer carries the points of the region after the change, and no other field")
  #expect(answer.status == 0, "the command exits 0")
  #expect(answer.err == "", "standard error stays empty when a command worked")

  let after = try EventList.notes(in: try #require(EventList.window(of: logic.tree)))
  #expect(
    after.map(\.velocity) == [100, 70, 100, 64], "every note carries the velocity it carried")
  #expect(after.map(\.pitch) == before.map(\.pitch), "every pitch is the one it was")
  #expect(after.map(\.position) == before.map(\.position), "every note starts where it did")
  #expect(after.map(\.length) == before.map(\.length), "every note is as long as it was")
  #expect(after.map(\.channel) == before.map(\.channel), "every note is on the channel it was")
  #expect(
    logic.column == [100, 100, 70, 100, 64, 90, 110],
    "one number of the column changed, and it is the one the command was given")
  #expect(
    logic.heldRows == [1],
    "Logic holds the row of point 1, which is the first row of the table, and holds no other row")
  #expect(
    logic.steps == [10, 10, 10, 10],
    "60 reaches 100 in four steps of the slider, which moves 10 at a time")

  let untouched = try aLogicShowingTheRegionAndItsEvents()
  let refused = try automationSet(
    ["automation", "set", "--track", "3", "--region", "1", "--point", "9", "--value", "100"],
    against: untouched)

  let failure = try refused.failure()
  #expect(refused.status == 19, "the number the design system gives point_not_found")
  #expect(
    failure["code"] as? String == "point_not_found", "a point that is not there is refused as one")
  #expect(
    failure["message"] as? String == "Region 1 on track 3 has 3 points",
    "the sentence names the region and how many points it holds")
  let details = failure["details"] as? [String: Any] ?? [:]
  #expect(details["point"] as? Int == 9, "the number that was asked for")
  #expect(details["points"] as? Int == 3, "the count of the points the region holds")
  #expect(
    details.keys.sorted() == ["point", "points"],
    "the two numbers are the whole of what the refusal carries")
  #expect(try refused.printed()["data"] is NSNull, "a failure carries no data")
  #expect(
    refused.err.hasPrefix("logicctl: point_not_found: "),
    "the one line of standard error reads logicctl: <code>: <message>")
  #expect(untouched.heldRows == [], "no row was held selected")
  #expect(untouched.steps == [], "no slider moved")
  #expect(
    untouched.column == [60, 100, 70, 100, 64, 90, 110],
    "every value and every velocity is the one Logic recorded")
}

/// An agent changes the value of one automation point, and the point it moves is in that region.
///
/// The Event List shows the region Logic holds selected. Measured on Logic 12.3.1 on 2026-09-27:
/// after a take, Logic held the regions of two tracks selected, and a read of a third region
/// answered the events of one of those two. This command goes further than a read: it counts the
/// fader rows of the list to find `--point 1`, holds that row and moves its slider. So a list of
/// wrong region means a volume point of another part of the song changes, and the answer prints the
/// points of that other region as though they were the ones a person asked about.
///
/// So the region the command names is the only region Logic holds before any row is read.
@Test func setChangesThePointOfTheNamedRegion() throws {
  let logic = try AFakeLogic(showing: [
    try theTracksWindowOfThreeRegions(),
    try recorded("event-list-automation.json"),
  ])
  logic.hold(theRegionsOfTracks: [4, 5])
  try #require(
    logic.heldRegions == ["the region of track 4", "the region of track 5"],
    "Logic holds the regions of two other tracks, as it does after a take")

  let answer = try automationSet(
    ["automation", "set", "--track", "3", "--region", "1", "--point", "1", "--value", "100"],
    against: logic)

  #expect(
    logic.heldRegions == ["the region of track 3"],
    "the region the command named is the only region Logic holds")
  #expect(
    logic.did == ["select the region", "read the Event List"],
    "the region is selected before a row is read, so the point belongs to the named region")
  #expect(
    try answer.points().map { $0["value"] as? Int } == [100, 90, 110],
    "point 1 of the named region carries 100, and the other two are as Logic recorded them")
  #expect(answer.status == 0, "the command exits 0")
}
