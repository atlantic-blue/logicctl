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

  /// The failure the answer carries, or an empty object when it carried none.
  func failure() throws -> [String: Any] {
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
/// Event List of this test is the one its notes were read from.
private func theRecordedTracksWindow() throws -> any AXNode {
  let application = try recorded("mixer-and-event-list-in-front.json")
  guard
    let window = application.children.first(where: { ($0.title ?? "").hasSuffix(" - Tracks") })
  else {
    throw AFakeLogic.ShowsNoTracksWindow()
  }
  return window
}

/// A Logic that shows the Tracks window of a project and the Event List of one region.
private final class AFakeLogic {
  /// None of the windows this fake was given is a Tracks window, so it holds no region to select.
  struct ShowsNoTracksWindow: Error {}

  /// None of the windows this fake was given is an Event List, so it holds no table to read.
  struct ShowsNoEventList: Error {}

  /// The Tracks window, as Logic answers it.
  let tracks: Element

  /// The Event List window, as Logic answers it.
  let events: Element

  /// Every region item of the Tracks window, in the order Accessibility answers them.
  let regions: [Element]

  /// What Logic was asked to do, in order, with a repeat of the same thing read as one.
  private(set) var did: [String] = []

  /// The table of events. A read of it is a read of the Event List.
  private let table: Element

  /// The region item each track carries, against the number of that track.
  private let ofTrack: [Int: Element]

  /// Whether a write of `AXSelected` lets a region go.
  ///
  /// Logic toggles the item, so a write on a region it holds lets that region go. A Logic that
  /// keeps it is what a readback holding a region nobody named comes from.
  private let theWriteLetsARegionGo: Bool

  init(tracks: any AXNode, events: any AXNode, theWriteLetsARegionGo: Bool = true) throws {
    self.tracks = Element(of: tracks)
    self.events = Element(of: events)
    self.theWriteLetsARegionGo = theWriteLetsARegionGo
    guard
      let found = try LocatorResolver.element(of: Locators.eventListTable, in: self.events)
        as? Element
    else {
      throw ShowsNoEventList()
    }
    table = found
    guard let group = AFakeLogic.contents(of: self.tracks) else {
      throw ShowsNoTracksWindow()
    }
    regions = AFakeLogic.regionItems(under: group)
    ofTrack = AFakeLogic.regionsOfTheTracks(under: group)
    table.forget()
    table.read = { [weak self] in self?.record("read the Event List") }
  }

  /// The windows Logic is showing.
  ///
  /// The Tracks window comes first. A walk looking for the region items stops at the first group it
  /// finds, so it never reaches the Event List, and a read of that table is a read a command made.
  var tree: LogicTree {
    LogicTree(
      logicVersion: recordedVersion,
      root: Element(role: "AXApplication", children: [tracks, events]))
  }

  /// How many times anything read the table of the Event List.
  var readsOfTheEventListTable: Int {
    table.reads
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

/// A Logic showing the Tracks window and the Event List of a region of four notes.
private func aLogicShowingTheTracksAndTheEventList(theWriteLetsARegionGo: Bool = true) throws
  -> AFakeLogic
{
  try AFakeLogic(
    tracks: try theRecordedTracksWindow(),
    events: try recorded("event-list-automation.json"),
    theWriteLetsARegionGo: theWriteLetsARegionGo)
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

/// Runs `logicctl midi notes` against a Logic that shows these windows.
///
/// The project sits nowhere, which is a project that was never saved, so there is no session to
/// write a step into and nothing of this run touches the disk.
private func midiNotes(
  _ arguments: [String],
  against logic: AFakeLogic,
  tracks: [Track] = aProjectWithARegionOnTrack4()
) throws -> Answer {
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(["midi", "notes"] + arguments)
  let notes = try #require(typed as? Midi.Notes)
  let status = notes.answer(
    driver: FakeLogicDriver(tracks: tracks),
    of: { logic.tree },
    selection: logic.selection,
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
  let answer = try midiNotes(
    ["--track", "4", "--region", "1"],
    against: try aLogicShowingTheTracksAndTheEventList())

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

/// An agent asks for the notes of one region, and gets the notes of that region.
///
/// The Event List shows the region Logic holds selected, and it follows the selection as soon as it
/// changes. Measured on Logic 12.3.1 on 2026-09-27: after a take, Logic held the regions of tracks
/// 4 and 5 selected and the Event List showed a region of track 4.
/// `midi notes --track 3 --region 2` answered the notes of the region of track 4, under a heading
/// that said track 3 and region 2. Selecting the named region moved the list onto it at once.
///
/// So the wrong answer here is not an error, it is four notes of another part of the song with the
/// right numbers written above them. Nothing later in a session shows that: the notes are real
/// notes, and an agent reading them goes on to `midi velocity --note 2` against a region nobody
/// named. The command makes the named region the only region Logic holds, and it does that before
/// it reads, because a list read first is a list of the region Logic happened to be showing.
///
/// The second half is the Logic that keeps a region. A write of `AXSelected` toggles the item, so
/// the selection is read back, and a readback holding a region nobody named stops the command with
/// `selection_mismatch`. The Event List is not read at all: an answer taken from a list of two
/// regions would be worse than no answer.
@Test func eventListReadsSelectTheNamedRegionFirst() throws {
  let logic = try aLogicShowingTheTracksAndTheEventList()
  logic.hold(theRegionsOfTracks: [5])
  try #require(
    logic.heldRegions == ["the region of track 5"],
    "Logic holds the region of another track, as it does after a take")

  let answer = try midiNotes(["--track", "4", "--region", "1"], against: logic)

  #expect(
    logic.heldRegions == ["the region of track 5"],
    "the region Logic held is back, because a command gives the selection back when it ends")
  #expect(
    logic.did == ["select the region", "read the Event List", "select the region"],
    "the named region is selected before the read, so the list shows it, and the region the "
      + "person had goes back afterwards"
  )
  #expect(
    logic.readsOfTheEventListTable > 0, "the notes were read from the table of the Event List")

  let rows = try answer.rows()
  #expect(rows.count == 4, "the four notes of the named region")
  #expect(rows.map { $0["pitch"] as? Int } == [60, 62, 64, 65], "the pitches Logic shows")
  #expect(answer.status == 0, "the command exits 0")
  #expect(answer.err == "", "standard error stays empty when a command worked")

  let keeping = try aLogicShowingTheTracksAndTheEventList(theWriteLetsARegionGo: false)
  keeping.hold(theRegionsOfTracks: [5])

  let refused = try midiNotes(["--track", "4", "--region", "1"], against: keeping)

  let failure = try refused.failure()
  #expect(refused.status == 20, "the number the design system gives selection_mismatch")
  #expect(
    failure["code"] as? String == "selection_mismatch",
    "Logic holds a region nobody named, so there is no one region to read")
  #expect(
    keeping.readsOfTheEventListTable == 0,
    "the Event List is not read, so no note of another region is answered")
  #expect(try refused.printed()["data"] is NSNull, "a failure carries no data")
  #expect(
    (failure["message"] as? String ?? "").contains("region 1 on track 4"),
    "the sentence names the region the command asked for")
  let details = failure["details"] as? [String: Any] ?? [:]
  #expect(
    (details["selected"] as? [Any] ?? []).count == 2,
    "the refusal names the regions Logic kept, so a person reads which ones to let go")
  #expect(
    refused.err.hasPrefix("logicctl: selection_mismatch: "),
    "the one line of standard error reads logicctl: <code>: <message>")
}
