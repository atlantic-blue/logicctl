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
private final class AFakeLogic {
  private let tracks: any AXNode
  private let before: any AXNode
  private let after: any AXNode

  /// What the command asked Logic to do, in order. A press is named by the title of the menu item
  /// it pressed, because the title is the whole of what tells two items of one submenu apart.
  private(set) var did: [String] = []

  /// The regions the command selected, as Logic names each one.
  private(set) var selected: [String] = []

  /// True once both items of the Mix menu were pressed.
  private var converted = false

  init(tracks: any AXNode, before: any AXNode, after: any AXNode) {
    self.tracks = tracks
    self.before = before
    self.after = after
  }

  /// The windows Logic is showing.
  var tree: LogicTree {
    LogicTree(
      logicVersion: recordedVersion,
      root: Element(
        role: "AXApplication",
        children: [tracks, converted ? after : before]))
  }

  /// What the command drives Logic through.
  var menus: AutomationMenus {
    AutomationMenus(
      press: { locator in
        self.did.append(locator.path.last?.title ?? locator.name)
        if locator.name == Locators.convertTrackAutomationToRegionAutomation.name {
          self.converted = true
        }
      },
      select: { region in
        self.did.append("select")
        self.selected.append(region.description ?? "")
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
    root: root ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
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
