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

  /// The rows the answer carries under `data.tracks`.
  func rows() throws -> [[String: Any]] {
    let data = try printed()["data"] as? [String: Any] ?? [:]
    return data["tracks"] as? [[String: Any]] ?? []
  }
}

/// The tracks of one recorded tree, read the way the driver over the real Logic reads them.
private func tracksRecorded(in tree: String) throws -> [Track] {
  let recorded = try RecordedTree(contentsOf: recordedTrees.appending(path: tree))
  return try TrackReader.tracks(in: recorded.root)
}

/// Runs `logicctl tracks list` against a Logic that holds these tracks.
///
/// The project sits nowhere, which is a project that was never saved, so there is no session to
/// write a step into and nothing of this run touches the disk.
private func tracksList(of tracks: [Track]) -> Answer {
  var out = ""
  var err = ""
  let status = Tracks.List.answer(
    driver: FakeLogicDriver(tracks: tracks),
    root: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A person or an agent asks for the tracks of a project that has none.
///
/// The answer is a state and not a failure. Logic shows an empty tracks area, so the list is
/// empty, the envelope carries no error, and the command exits 0. That number is the whole point:
/// an agent reads the one field, sees no track and adds one, where an exit code of 5 would stop a
/// script on a condition that nothing is wrong with. The tracks come from the tree that `inspect`
/// recorded from Logic 12.3.1 for a project with no track, so the empty list is what Logic showed
/// and not a list this test wrote.
@Test func tracksListOfAnEmptyProjectIsEmpty() throws {
  let recorded = try tracksRecorded(in: "empty.json")

  let answer = tracksList(of: recorded)

  #expect(try answer.rows().isEmpty, "the project holds no track, so the list is empty")
  #expect(try answer.printed()["error"] is NSNull, "an empty project is no failure")
  #expect(answer.status == 0, "the command exits 0")
  #expect(answer.err == "", "standard error stays empty when a command worked")
}

/// A person or an agent asks for the tracks of a project that holds one.
///
/// The row carries the six fields the caller picks a track by: the number to give `--index`, the
/// name Logic shows in the header, the type, and whether the track is muted, soloed and armed. The
/// values are the ones Logic showed in the tree that was recorded from it: one track called Deluxe
/// Classic, with all three buttons off. The type reads `other`, because the header of an audio
/// track and the header of a software instrument track carry the same nine controls and neither
/// says which kind the track is.
@Test func tracksListOfOneTrackPrintsItsRow() throws {
  let recorded = try tracksRecorded(in: "one-track.json")

  let answer = tracksList(of: recorded)

  let rows = try answer.rows()
  try #require(rows.count == 1, "the project holds one track, so the list holds one row")
  let row = try #require(rows.first)
  #expect(row["index"] as? Int == 1, "the number a person gives --index, counted from 1")
  #expect(row["name"] as? String == "Deluxe Classic", "the name Logic shows in the header")
  #expect(row["type"] as? String == "other", "the header says nothing about the kind of track")
  #expect(row["mute"] as? Bool == false, "the mute button of the header is off")
  #expect(row["solo"] as? Bool == false, "the solo button of the header is off")
  #expect(row["arm"] as? Bool == false, "the record enable button of the header is off")
  #expect(answer.status == 0, "the command exits 0")
}

/// A project that holds three tracks reads as three rows, numbered from 1 in the order Logic shows
/// them.
///
/// The number is what every other `tracks` command takes as `--index`, so a list that numbered the
/// rows differently would send a later command to another track.
@Test func tracksListNumbersEveryRowInTheOrderLogicShowsThem() throws {
  let recorded = try tracksRecorded(in: "region.json")

  let answer = tracksList(of: recorded)

  let rows = try answer.rows()
  try #require(rows.count == 3, "the project holds three tracks")
  #expect(rows.map { $0["index"] as? Int } == [1, 2, 3], "the rows are numbered from 1, in order")
  #expect(
    rows.map { $0["name"] as? String } == ["Deluxe Classic", "Deluxe Classic", "Studio Grand"],
    "the names are the ones Logic shows, in the order it shows them")
}

/// What Logic writes in the description of the Record Enable button of a track it does not record.
private let theIdleRecordEnable = "Record Enable"

/// What Logic writes there while it records that track. Measured on this Mac at 16:30 on
/// 2026-09-26 against Logic 12.3.1, on a copy of the project F-T13: the button of the recording
/// track described itself as its name, a comma, a space and the state.
private let theRecordingRecordEnable = "Record Enable, recording"

/// A description that starts with the name of the button as plain text and names another control.
private let anotherControl = "Recorder"

/// What the value of a button of a track header reads as while the button is on.
private let theButtonOn = "1"

/// The names of the three tracks of the recorded project, in the order Logic shows them.
private let theThreeTracks = ["Deluxe Classic", "Deluxe Classic", "Studio Grand"]

/// The window of a project of three tracks, where one track describes its Record Enable button
/// with the text this test gives and carries the value of a button that is on.
///
/// No recorded tree holds a track that records. `inspect` wrote the Record Enable button of every
/// fixture with the value `0` and the description of an idle button, because a person cannot record
/// a take and run `inspect` in the same moment. So the recorded tree of the project is read, and
/// the one button is written as the running Logic wrote it.
private func aRecordedProject(
  whereTrack track: Int, describesItsRecordEnableAs description: String
) throws -> any AXNode {
  let file = recordedTrees.appending(path: "region.json")
  let read = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
  var reached = 0
  func written(_ node: Any) -> Any {
    guard var element = node as? [String: Any] else { return node }
    if element["description"] as? String == theIdleRecordEnable {
      reached += 1
      if reached == track {
        element["description"] = description
        element["value"] = theButtonOn
      }
    }
    if let children = element["children"] as? [Any] {
      element["children"] = children.map(written)
    }
    return element
  }
  let tree = try JSONSerialization.data(withJSONObject: written(read))
  return try JSONDecoder().decode(RecordedTree.self, from: tree).root
}

/// Logic records a track, and a person reads the project back while it records.
///
/// `transport record` pressed the Record button of the Control Bar on this Mac at 16:30 on
/// 2026-09-26, Logic recorded, and the command failed with `element_not_found`. The read after the
/// press reached `tracks.header.track2.recordEnableButton`, and Logic described that button
/// `Record Enable, recording`. While Logic records a track, the button of that track carries its
/// name, a comma, a space and the state. The reader wanted the name alone. So every command that
/// records worked and then failed, and no session kept the state it left Logic in.
///
/// The reader now reads that button, and the row of the recording track answers `arm: true`. A
/// description that starts with the name of the button and goes on as one word, such as
/// `Recorder`, still fails with `element_not_found`: the button carries no identifier and no
/// title, so the description is the whole of what says the walk reached the right control, and a
/// row read from the wrong one would put a number in the journal that Logic never showed.
@Test func theReaderFindsRecordEnableWhileLogicRecords() throws {
  let recording = try aRecordedProject(
    whereTrack: 2, describesItsRecordEnableAs: theRecordingRecordEnable)

  let tracks = try TrackReader.tracks(in: recording)

  #expect(tracks.map(\.arm) == [false, true, false], "the track Logic records is the armed one")
  #expect(tracks.map(\.name) == theThreeTracks, "the tracks Logic shows, in its own order")
  #expect(tracks.map(\.mute) == [false, false, false], "the mute buttons are off, as they were")
  #expect(tracks.map(\.solo) == [false, false, false], "and so are the solo buttons")

  let answer = tracksList(of: tracks)

  let rows = try answer.rows()
  try #require(rows.count == 3, "the three tracks of the recorded project")
  #expect(rows.map { $0["arm"] as? Bool } == [false, true, false], "the row a person reads")
  #expect(answer.status == 0, "the command exits 0")

  let wrongControl = try aRecordedProject(
    whereTrack: 1, describesItsRecordEnableAs: anotherControl)

  let refused = #expect(throws: TrackReader.Refusal.self) {
    try TrackReader.tracks(in: wrongControl)
  }

  let other = try #require(refused)
  #expect(other.found == anotherControl, "what Logic said the control at the end of the walk was")
  #expect(other.failure.code == .elementNotFound, "the code a caller reads")
  #expect(other.failure.code.exitCode == 5, "the number the process exits with")
  #expect(
    other.locator == Locators.trackRecordEnableButton(number: 0).name,
    "the failure names the walk that reached the wrong control")
}
