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

  /// The rows the answer carries under `data.notes`.
  func rows() throws -> [[String: Any]] {
    let data = try printed()["data"] as? [String: Any] ?? [:]
    return data["notes"] as? [[String: Any]] ?? []
  }
}

/// The tree of an Event List window, as `inspect` recorded it from Logic 12.3.1.
private func recordedEventList(_ tree: String) throws -> LogicTree {
  let recorded = try RecordedTree(contentsOf: recordedTrees.appending(path: tree))
  return LogicTree(logicVersion: recorded.logicVersion, root: recorded.root)
}

/// A project of one track that carries one region, which is what `--track 4 --region 1` names.
private func aProjectWithARegionOnTrack4() -> [Track] {
  [
    Track(
      index: 4,
      name: "Studio Grand",
      type: .softwareInstrument,
      regions: [Region(index: 1, name: "MIDI Region", start: "1 bar", end: "3 bars")])
  ]
}

/// Runs `logicctl midi notes --track 4 --region 1` against a Logic that shows this Event List.
///
/// The project sits nowhere, which is a project that was never saved, so there is no session to
/// write a step into and nothing of this run touches the disk.
private func midiNotes(of window: LogicTree, tracks: [Track] = aProjectWithARegionOnTrack4()) throws
  -> Answer
{
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(["midi", "notes", "--track", "4", "--region", "1"])
  let notes = try #require(typed as? Midi.Notes)
  let status = notes.answer(
    driver: FakeLogicDriver(tracks: tracks),
    of: { window },
    root: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A person reads the notes Logic shows, and nothing else that shares the table with them.
///
/// The Event List is one table of events, and a note is one kind of row in it. A region that
/// carries volume automation shows a `Fader` row at every point, in the same columns, with a
/// number in the same place that a velocity sits in. So a reader that takes every row answers
/// seven events for a region of four notes, and the count is not the damage: the numbering is.
/// `--note 2` names the second row of the answer, so `midi velocity --note 2` would move a
/// volume point, or a note nobody asked for, and the answer would say it changed a note.
///
/// The tree is the one `inspect` recorded from Logic 12.3.1 for a region of four notes with
/// region automation on it. The four notes read as Logic showed them: C3, D3, E3 and F3, at
/// velocity 100, 70, 100 and 64, each a division long. The velocity is the number Logic writes on
/// the slider, because the value under it is a scaled 32 bit number that no reader turns back into
/// a velocity.
@Test func notesReadFromTheEventListRows() throws {
  let answer = try midiNotes(of: recordedEventList("event-list-automation.json"))

  let rows = try answer.rows()
  try #require(rows.count == 4, "the region holds four notes, and the table holds three more rows")

  let first = try #require(rows.first)
  #expect(first["note"] as? Int == 1, "the number --note takes, from 1 in time order")
  #expect(first["position"] as? String == "1 1 1 1", "where Logic shows the note")
  #expect(first["pitch"] as? Int == 60, "the pitch Logic holds under C3")
  #expect(first["velocity"] as? Int == 100, "the velocity Logic writes on the slider")
  #expect(first["length"] as? String == "0 0 1 160", "how long Logic shows the note")
  #expect(first["channel"] as? Int == 1, "the MIDI channel of the note")

  #expect(rows.map { $0["note"] as? Int } == [1, 2, 3, 4], "numbered from 1, in time order")
  #expect(
    rows.map { $0["position"] as? String } == ["1 1 1 1", "1 1 4 1", "1 3 1 1", "1 3 4 1"],
    "the positions Logic shows, with nothing at 1 4 4 240 or 2 1 1 1, where the faders sit")
  #expect(rows.map { $0["pitch"] as? Int } == [60, 62, 64, 65], "the pitches Logic shows")
  #expect(
    rows.map { $0["velocity"] as? Int } == [100, 70, 100, 64],
    "the velocities Logic shows, and none of the fader values 60, 90 and 110")
  #expect(rows.allSatisfy { $0["channel"] as? Int == 1 }, "every note is on channel 1")
  #expect(answer.status == 0, "the command exits 0")
  #expect(answer.err == "", "standard error stays empty when a command worked")
}
