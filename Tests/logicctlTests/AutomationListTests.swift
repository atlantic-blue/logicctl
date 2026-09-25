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

/// One element of the tree this test holds the recorded windows under.
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

/// A Logic that is showing the windows a person works in, as `inspect` recorded each one.
///
/// Logic keeps the Tracks window open behind the Event List, so the command is given both and
/// reads the points out of the one that holds them.
private func aLogicShowing(_ windows: [any AXNode]) -> LogicTree {
  LogicTree(
    logicVersion: recordedVersion,
    root: Element(role: "AXApplication", children: windows))
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

/// Runs `logicctl automation list` against a Logic of this test.
///
/// The project sits nowhere, which is a project that was never saved, so there is no session to
/// write a step into and nothing of this run touches the disk.
private func automationList(
  _ arguments: [String],
  showing tree: LogicTree,
  tracks: [Track] = aProjectWithARegionOnTrack3()
) throws -> Answer {
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(["automation", "list"] + arguments)
  let list = try #require(typed as? Automation.List)
  let status = list.answer(
    driver: FakeLogicDriver(tracks: tracks),
    of: { tree },
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
    showing: aLogicShowing([
      try recorded("region.json"),
      try recorded("event-list-automation.json"),
    ]))

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

/// Logic is showing the Tracks window and no Event List, so there is nothing to read the points
/// from.
///
/// An empty list here would read as a region that carries no automation, and the agent would go on
/// to add points to a region that already has three.
@Test func listStopsWhenLogicShowsNoEventList() throws {
  let answer = try automationList(
    ["--track", "3", "--region", "1"],
    showing: aLogicShowing([try recorded("region.json")]))

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
    showing: aLogicShowing([
      try recorded("region.json"),
      try recorded("event-list-automation.json"),
    ]))

  #expect(answer.status == 17, "the number the design system gives region_not_found")
  #expect(try answer.error()["code"] as? String == "region_not_found")
  #expect(
    try answer.error()["details"] as? [String: Any] != nil,
    "the failure carries the numbers it was asked for")
}
