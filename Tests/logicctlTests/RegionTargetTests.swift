import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

/// The element a recorded tree starts at.
private func treeRoot(of file: String) throws -> any AXNode {
  try RecordedTree(contentsOf: fixtureFolder.appending(path: file)).root
}

/// A tree written in a test, read back the way a recorded tree is read.
private func treeRead(from text: String) throws -> any AXNode {
  try JSONDecoder().decode(RecordedTree.self, from: Data(text.utf8)).root
}

/// The failure a resolve gave, or nothing when it gave a region.
private func refusal(of resolve: () throws -> Region) -> Failure? {
  do {
    _ = try resolve()
    return nil
  } catch let carrying as any FailureCarrying {
    return carrying.failure
  } catch {
    return nil
  }
}

/// A project of one track, with the regions a test gives it.
private func aProjectOfOneTrack(carrying regions: [Region]) -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "T3b"),
    transport: Transport(tempo: 120),
    tracks: [
      Track(index: 3, name: "Studio Grand", type: .softwareInstrument, regions: regions)
    ])
}

/// One region of a track.
private func aRegion(_ index: Int, from start: String, to end: String) -> Region {
  Region(index: index, name: "MIDI Region", start: start, end: end)
}

/// A person asks for a region that is not on the track, and reads how many the track has.
///
/// Nothing in Logic writes the number of a region on the screen. The number is the place the
/// region sits in from the left, so asking for one that is not there is the ordinary mistake, and
/// the count is what answers it: the track has one region, so the only number that names a region
/// is 1. A person or an agent reads the count and asks again with a number that exists, without
/// opening Logic to look.
@Test func anUnknownRegionStopsWithRegionNotFound() throws {
  let typed = try RegionOption.parse(["--track", "3", "--region", "2"])
  let project = aProjectOfOneTrack(carrying: [aRegion(1, from: "1 bar", to: "2 bars")])

  let stopped = try #require(
    refusal { try RegionTarget.region(typed, in: project) },
    "the track has one region, so region 2 is not there")

  #expect(stopped.code == .regionNotFound)
  #expect(stopped.code.exitCode == 17, "the number the design system gives region_not_found")
  #expect(stopped.message == "Track 3 has 1 region")
  #expect(
    stopped.details
      == JSONValue.object([
        "track": .number(3),
        "region": .number(2),
        "regions": .number(1),
      ]),
    "the count of the regions the track has is what a person asks again with")
}

/// The count is a count, so it reads as the number the track carries and says so in plural.
///
/// A person reading "has 2 region" learns the number and stops trusting the sentence, and a person
/// reading a fixed "1" asks again with a number that is not there either.
@Test func theCountNamesHowManyRegionsTheTrackHas() throws {
  let two = aProjectOfOneTrack(carrying: [
    aRegion(1, from: "1 bar", to: "2 bars"),
    aRegion(2, from: "3 bars", to: "5 bars"),
  ])
  let asked = try RegionOption.parse(["--track", "3", "--region", "5"])
  let stoppedOnTwo = try #require(refusal { try RegionTarget.region(asked, in: two) })

  #expect(stoppedOnTwo.message == "Track 3 has 2 regions")
  #expect(
    stoppedOnTwo.details
      == JSONValue.object([
        "track": .number(3),
        "region": .number(5),
        "regions": .number(2),
      ]))

  let none = aProjectOfOneTrack(carrying: [])
  let first = try RegionOption.parse(["--track", "3", "--region", "1"])
  let stoppedOnNone = try #require(refusal { try RegionTarget.region(first, in: none) })

  #expect(stoppedOnNone.message == "Track 3 has 0 regions", "an empty track has no first region")
}

/// A number that names a region gives that region and no failure.
@Test func theNumberOfARegionNamesTheRegionAtThatPlace() throws {
  let project = aProjectOfOneTrack(carrying: [
    aRegion(1, from: "1 bar", to: "2 bars"),
    aRegion(2, from: "3 bars", to: "5 bars"),
  ])
  let typed = try RegionOption.parse(["--track", "3", "--region", "2"])

  let found = try RegionTarget.region(typed, in: project)

  #expect(found.index == 2)
  #expect(found.start == "3 bars", "the second region from the left, not the first")
  #expect(found.end == "5 bars")
}

/// A track that is not in the project is named before the region is looked for.
///
/// The two numbers fail for different reasons, and a person told that a region is missing goes
/// looking for the region. The track is what is missing, so that is what the failure says, with the
/// number that was typed.
@Test func anUnknownTrackStopsWithTrackNotFound() throws {
  let project = aProjectOfOneTrack(carrying: [aRegion(1, from: "1 bar", to: "2 bars")])
  let typed = try RegionOption.parse(["--track", "9", "--region", "1"])

  let stopped = try #require(
    refusal { try RegionTarget.region(typed, in: project) },
    "the project has one track and it is track 3")

  #expect(stopped.code == .trackNotFound)
  #expect(stopped.code.exitCode == 10, "the number the design system gives track_not_found")
  #expect(stopped.message == "No track at index 9")
  #expect(stopped.details == JSONValue.object(["index": .number(9)]))
}

/// The Tracks window is where a region gets its name and its two borders.
///
/// The recorded tree is a project of three tracks with one region on the third, imported from a
/// MIDI file. Its item carries the name, and its help text carries the borders inside a sentence
/// with two spaces in it, which do not belong in the state.
@Test func theTracksWindowNamesTheRegionAndItsBorders() throws {
  let window = try treeRoot(of: "region.json")

  let onTheThird = RegionReader.regions(ofTrack: 3, in: window)

  #expect(onTheThird.count == 1, "the third track carries the region the import made")
  let region = try #require(onTheThird.first)
  #expect(region.index == 1)
  #expect(region.name == "MIDI Region")
  #expect(region.start == "1 bar")
  #expect(region.end == "2 bars")

  #expect(RegionReader.regions(ofTrack: 1, in: window).isEmpty, "the first track carries nothing")
  #expect(RegionReader.regions(ofTrack: 9, in: window).isEmpty, "and there is no ninth track")
}

/// The number of a region is its place from the left, so the reader keeps the order it read.
///
/// Nothing in the tree carries a position, so the order Accessibility answers the items in is the
/// whole of what says which region is first. A reader that sorted them by name or by their borders
/// would move the number of a region when a person renames one.
@Test func theRegionsOfATrackReadInTheOrderTheySitFromTheLeft() throws {
  let window = try treeRead(from: aWindowOfTwoRegions)

  let regions = RegionReader.regions(ofTrack: 2, in: window)

  #expect(regions.map(\.index) == [1, 2])
  #expect(regions.map(\.name) == ["Intro", "Verse"])
  #expect(regions.map(\.start) == ["1 bar", "3 bars"])
  #expect(regions.map(\.end) == ["2 bars", "5 bars"])
  #expect(RegionReader.regions(ofTrack: 1, in: window).isEmpty, "the first track carries nothing")
}

/// A region that does not start on a bar keeps what the window says about it.
///
/// Logic writes the borders of such a region as a position of four numbers rather than a count of
/// bars. The state carries the text the window gives, whichever of the two it is, so a reader of
/// the journal sees what Logic showed.
@Test func aRegionThatDoesNotStartOnABarKeepsWhatTheWindowSays() throws {
  let offTheBar = RegionReader.borders(
    of: "Region starts at 1 1 3 1  and ends at 2 bars , MIDI region. Contains MIDI note events. ")

  #expect(offTheBar.start == "1 1 3 1")
  #expect(offTheBar.end == "2 bars")
}

/// A help text that does not carry the sentence gives no borders at all.
///
/// The borders are what the Tracks window says, and a window that says nothing about them has
/// nothing to give. Two empty texts say that, where a guess would put a border into the journal
/// that Logic never showed.
@Test func aHelpTextWithoutTheSentenceGivesNoBorders() throws {
  #expect(RegionReader.borders(of: "").start == "")
  #expect(RegionReader.borders(of: "").end == "")
  #expect(RegionReader.borders(of: "Audio region. Drag the middle to move. ").start == "")
  #expect(RegionReader.borders(of: "Region starts at 1 bar and never ends").end == "")
}

/// A person reads the regions of a track that sits after the fourth row, and finds them.
///
/// Logic writes a description on some of the areas under `Tracks contents` and none on the rest,
/// and the numbers in the ones it writes do not follow the rows. So the only thing that says which
/// track an area belongs to is its place in the group. A person who imports a MIDI file of seven
/// tracks reads the regions the import made on every one of them, and not on the first four alone.
@Test func theRegionReaderFindsATrackByItsPlace() throws {
  let window = try treeRead(from: aWindowOfSevenTracks)

  let onTheSixth = RegionReader.regions(ofTrack: 6, in: window)
  #expect(
    onTheSixth.map(\.name) == ["Sixth"],
    "the sixth track carries the region of the sixth area")
  #expect(onTheSixth.map(\.start) == ["3 bars"])
  #expect(onTheSixth.map(\.end) == ["4 bars"])

  let onTheSeventh = RegionReader.regions(ofTrack: 7, in: window)
  #expect(
    onTheSeventh.map(\.name) == ["Seventh"],
    "and the seventh track carries the region of the seventh area")
  #expect(onTheSeventh.map(\.start) == ["58 bars"])
  #expect(onTheSeventh.map(\.end) == ["59 bars"])

  #expect(
    RegionReader.regions(ofTrack: 8, in: window).isEmpty,
    "eight areas give seven tracks, because the last area is the room under the last track")

  #expect(
    RegionReader.regions(ofTrack: 5, in: window).map(\.name) == ["Fifth"],
    "the first area with no description is a track and not the room")
  #expect(
    (1...4).allSatisfy { RegionReader.regions(ofTrack: $0, in: window).isEmpty },
    "the four described areas keep their place and carry nothing")

  let recorded = try treeRoot(of: "mixer-and-event-list-in-front.json")

  #expect(
    RegionReader.regions(ofTrack: 4, in: recorded).map(\.start) == ["1 bar"],
    "the fourth track of the recorded project carries the region the recording shows on it")
  #expect(
    RegionReader.regions(ofTrack: 5, in: recorded).map(\.start) == ["58 bars"],
    "and the fifth carries its own, which no other track of that recording carries")
}

/// A window of two tracks, the second carrying two regions, and the room under the last track.
private let aWindowOfTwoRegions = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXWindow",
      "children": [
        {
          "role": "AXGroup",
          "description": "Tracks contents",
          "children": [
            { "role": "AXLayoutArea", "description": "Track 1 \\u201cDeluxe Classic\\u201d" },
            {
              "role": "AXLayoutArea",
              "description": "Track 2 \\u201cStudio Grand\\u201d",
              "children": [
                {
                  "role": "AXLayoutItem",
                  "description": "Intro",
                  "help": "Region starts at 1 bar  and ends at 2 bars , MIDI region. "
                },
                {
                  "role": "AXLayoutItem",
                  "description": "Verse",
                  "help": "Region starts at 3 bars  and ends at 5 bars , MIDI region. "
                }
              ]
            },
            { "role": "AXLayoutArea" }
          ]
        }
      ]
    }
  }
  """

/// A window of seven tracks, described the way Logic 12.3.1 describes them after a MIDI import.
///
/// Measured on 2026-09-27: the group holds eight layout areas in the order of the rows from the
/// top, the first four carry a description whose number does not follow its row, the last four
/// carry none, the eighth is the room under the last track, and children of other roles stand
/// between some of the areas. Rows 5, 6 and 7 carry one region each.
private let aWindowOfSevenTracks = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXWindow",
      "children": [
        {
          "role": "AXGroup",
          "description": "Tracks contents",
          "children": [
            { "role": "AXLayoutArea", "description": "Track 1 \\u201cDeluxe Classic\\u201d" },
            { "role": "AXButton", "description": "Mute" },
            { "role": "AXLayoutArea", "description": "Track 3 \\u201cStudio Grand\\u201d" },
            { "role": "AXLayoutItem" },
            { "role": "AXLayoutArea", "description": "Track 5 \\u201cStudio Grand\\u201d" },
            { "role": "AXLayoutArea", "description": "Track 7 \\u201cEpic Cloud Formation\\u201d" },
            {
              "role": "AXLayoutArea",
              "children": [
                {
                  "role": "AXLayoutItem",
                  "description": "Fifth",
                  "help": "Region starts at 1 bar  and ends at 2 bars , MIDI region. "
                }
              ]
            },
            { "role": "AXButton", "description": "Solo" },
            {
              "role": "AXLayoutArea",
              "children": [
                {
                  "role": "AXLayoutItem",
                  "description": "Sixth",
                  "help": "Region starts at 3 bars  and ends at 4 bars , MIDI region. "
                }
              ]
            },
            {
              "role": "AXLayoutArea",
              "children": [
                {
                  "role": "AXLayoutItem",
                  "description": "Seventh",
                  "help": "Region starts at 58 bars  and ends at 59 bars , MIDI region. "
                }
              ]
            },
            { "role": "AXLayoutArea" }
          ]
        }
      ]
    }
  }
  """

/// One element of a tree a test drives, which keeps what is written to it and answers it again.
///
/// It is a class, so a selection written at a region item lands on the element the command read,
/// the way it lands in Logic. It says when anything reads the elements under it, which is how the
/// test knows the command reached the Event List.
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
    read?()
    return kept
  }

  /// What a test is told each time the elements under this one are read.
  var read: (() -> Void)? = nil

  /// True while Logic holds this region item selected. No tree carries a selection, so a command
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

  init(role: String, description: String? = nil, help: String? = nil, children: [any AXNode] = []) {
    self.role = role
    self.description = description
    self.help = help
    kept = children
  }
}

/// A Tracks window where every track named carries one region.
///
/// Logic answers one layout area per track under the contents group, in the order of the rows from
/// the top, and one area after them, which is the room under the last track. The recorded windows
/// carry a region on tracks 3, 4 and 5, and this scenario needs one on track 2, so the window is
/// written here. Each region is described by the track it sits on, so the answer of a command reads
/// as a person reads it.
private func aTracksWindow(whereTheseTracksCarryARegion tracks: [Int]) -> any AXNode {
  let rows = (tracks.max() ?? 1) + 1
  let areas: [any AXNode] = (1...rows).map { place in
    let regions: [any AXNode] = tracks.contains(place) ? [aRegionItem(ofTrack: place)] : []
    return Element(role: RegionReader.trackRole, children: regions)
  }
  return Element(
    role: "AXWindow",
    children: [
      Element(role: "AXGroup", description: RegionReader.contentsGroup, children: areas)
    ])
}

/// One region item, described by the track it sits on. Logic describes a region by its name, and a
/// test that names them this way reads the answer of a command the way a person reads it.
private func aRegionItem(ofTrack place: Int) -> Element {
  Element(
    role: RegionReader.regionRole,
    description: "the region of track \(place)",
    help: "Region starts at 1 bar  and ends at 3 bars , MIDI region. ")
}

/// A Logic that shows a Tracks window of three regions and the Event List of one of them.
private final class AFakeLogic {
  /// The window this fake was given holds no Event List, so it holds no table to read.
  struct ShowsNoEventList: Error {}

  /// The window this fake was given holds no contents group, so it shows no region to select.
  struct ShowsNoRegion: Error {}

  /// The Tracks window, as Logic answers it.
  let tracks: Element

  /// The Event List window, as Logic answers it.
  let events: Element

  /// The regions a write of `AXSelected` landed on, in order, as Logic describes each one.
  private(set) var writes: [String] = []

  /// Every region item of the Tracks window, in the order Accessibility answers them.
  private let items: [Element]

  /// The region item each track carries, against the number of that track.
  private let ofTrack: [Int: Element]

  /// The table of events. A read of it is a read of the Event List.
  private let table: Element

  /// Whether a write of `AXSelected` lets a region go.
  ///
  /// Logic toggles the item, so a write on a region it holds lets that region go. A Logic that
  /// keeps it is what a readback holding a region nobody named comes from.
  private let theWriteLetsARegionGo: Bool

  /// Whether Logic stops taking a selection once a command reached the Event List, which is the
  /// Logic that does not give the regions back.
  private let theWriteBackTakesNoSelection: Bool

  /// True once anything read the table of the Event List.
  private var reachedTheEventList = false

  init(
    tracks: any AXNode,
    events: any AXNode,
    theWriteLetsARegionGo: Bool = true,
    theWriteBackTakesNoSelection: Bool = false
  ) throws {
    self.tracks = Element(of: tracks)
    self.events = Element(of: events)
    self.theWriteLetsARegionGo = theWriteLetsARegionGo
    self.theWriteBackTakesNoSelection = theWriteBackTakesNoSelection
    guard
      let found = try LocatorResolver.element(of: Locators.eventListTable, in: self.events)
        as? Element
    else {
      throw ShowsNoEventList()
    }
    table = found
    guard let group = AFakeLogic.contents(of: self.tracks) else {
      throw ShowsNoRegion()
    }
    let areas = group.children.compactMap { $0 as? Element }
      .filter { $0.role == RegionReader.trackRole }
    var carried: [Int: Element] = [:]
    for (place, area) in areas.enumerated() {
      let regions = area.children.compactMap { $0 as? Element }
        .filter { $0.role == RegionReader.regionRole }
      if let first = regions.first {
        carried[place + 1] = first
      }
    }
    ofTrack = carried
    items = areas.flatMap { area in
      area.children.compactMap { $0 as? Element }.filter { $0.role == RegionReader.regionRole }
    }
    table.read = { [weak self] in self?.reachedTheEventList = true }
  }

  /// The windows Logic is showing.
  ///
  /// The Tracks window comes first. A walk looking for the region items stops at the first contents
  /// group it finds, so it never reaches the Event List, and a read of that table is a read a
  /// command made.
  var tree: LogicTree {
    LogicTree(
      logicVersion: "12.3.1",
      root: Element(role: "AXApplication", children: [tracks, events]))
  }

  /// How Logic selects a region: a write of `AXSelected` toggles the item it lands on.
  var selection: AutomationMenus.RegionSelection {
    AutomationMenus.RegionSelection(
      holds: { ($0 as? Element)?.held ?? false },
      write: { item in
        guard let region = item as? Element else {
          return
        }
        self.writes.append(region.description ?? "")
        if self.theWriteBackTakesNoSelection, self.reachedTheEventList {
          return
        }
        if region.held, !self.theWriteLetsARegionGo {
          return
        }
        region.held.toggle()
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
    for region in items {
      region.held = false
    }
    for track in tracks {
      ofTrack[track]?.held = true
    }
  }

  /// The regions Logic holds selected, as it describes each one.
  var heldRegions: [String] {
    items.filter { $0.held }.map { $0.description ?? "" }
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
}

/// What one run of a command wrote, on each channel, and the number it exited with.
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

  /// What `meta` carries, or an empty object when it carried none.
  func meta() throws -> [String: Any] {
    try printed()["meta"] as? [String: Any] ?? [:]
  }

  /// What `meta` carries under `details`, or an empty object when it carries none.
  func details() throws -> [String: Any] {
    try meta()["details"] as? [String: Any] ?? [:]
  }
}

/// A Logic showing the Tracks window of tracks 2, 4 and 5 and the Event List of a region of four
/// notes.
private func aLogicShowingTheTracksAndTheEventList(
  theWriteLetsARegionGo: Bool = true,
  theWriteBackTakesNoSelection: Bool = false
) throws -> AFakeLogic {
  try AFakeLogic(
    tracks: aTracksWindow(whereTheseTracksCarryARegion: [2, 4, 5]),
    events: try treeRoot(of: "event-list-automation.json"),
    theWriteLetsARegionGo: theWriteLetsARegionGo,
    theWriteBackTakesNoSelection: theWriteBackTakesNoSelection)
}

/// Runs `logicctl midi notes` against a Logic that shows these windows.
///
/// The project sits nowhere, which is a project that was never saved, so there is no session to
/// write a step into and nothing of this run touches the disk.
private func midiNotes(_ arguments: [String], against logic: AFakeLogic) throws -> Answer {
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(["midi", "notes"] + arguments)
  let notes = try #require(typed as? Midi.Notes)
  let status = notes.answer(
    driver: FakeLogicDriver(tracks: [
      Track(
        index: 4,
        name: "Studio Grand",
        type: .softwareInstrument,
        regions: [Region(index: 1, name: "MIDI Region", start: "1 bar", end: "3 bars")])
    ]),
    of: { logic.tree },
    selection: logic.selection,
    root: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A command gives the selection back, because the selection says which part of the song the person
/// is working on.
///
/// A person selects the regions they are working on, here the regions of tracks 2 and 5. Then they
/// ask for the notes of one region of track 4. The Event List shows whichever region Logic holds,
/// so every command that reads it takes that selection down to the one region it was asked about.
/// That is the right thing to do and it costs the person their place: the two regions they had are
/// gone, the answer says nothing about it, and the next key they press in Logic lands on a region
/// logicctl chose.
///
/// So the command gives it back. The regions of tracks 2 and 5 are selected again when it ends, the
/// region of track 4 is not, and the answer carries the four notes of that region and nothing more,
/// because a selection that went back is not news.
///
/// The second run is the Logic that stops taking a selection after the read. The notes are read by
/// then, so the command still answers them, and it says `selectionRestored` false and names the
/// regions the person had, which is what they select again by hand without opening Logic to look.
///
/// The third run is the Logic that keeps every region a write asks it to let go. There is no one
/// region to read, so the command reads no note and answers `selection_mismatch`. It writes the old
/// selection back just the same, because a command that was refused took the selection away too.
@Test func aRegionCommandPutsBackTheSelectedRegions() throws {
  let logic = try aLogicShowingTheTracksAndTheEventList()
  logic.hold(theRegionsOfTracks: [2, 5])
  try #require(
    logic.heldRegions == ["the region of track 2", "the region of track 5"],
    "Logic holds the regions of two tracks, which is where the person was working")

  let answer = try midiNotes(["--track", "4", "--region", "1"], against: logic)

  #expect(answer.status == 0, "the command exits 0")
  #expect(
    try answer.rows().map { $0["pitch"] as? Int } == [60, 62, 64, 65],
    "the four notes of the region the command named, as Logic shows them")
  #expect(
    logic.heldRegions == ["the region of track 2", "the region of track 5"],
    "the regions of tracks 2 and 5 are selected again, as the person left them")
  #expect(
    logic.writes == [
      "the region of track 2", "the region of track 4", "the region of track 5",
      "the region of track 2", "the region of track 4", "the region of track 5",
    ],
    "each region is written once to take the named one alone, and once more to give it back")
  #expect(
    try answer.meta()["details"] is NSNull,
    "a selection that went back is not news, so the answer is the answer of any other read")

  let quiet = try aLogicShowingTheTracksAndTheEventList(theWriteBackTakesNoSelection: true)
  quiet.hold(theRegionsOfTracks: [2, 5])

  let said = try midiNotes(["--track", "4", "--region", "1"], against: quiet)

  #expect(said.status == 0, "the notes were read, so a selection that stayed put fails nothing")
  #expect(try said.rows().count == 4, "the four notes of the named region")
  #expect(
    quiet.heldRegions == ["the region of track 4"],
    "Logic kept the region the command named and took no selection back")
  let details = try said.details()
  #expect(
    details["selectionRestored"] as? Bool == false,
    "the answer says the regions did not go back")
  #expect(
    details["selectionBefore"] as? [String]
      == ["the region of track 2", "the region of track 5"],
    "and it names the regions the person had, so they select them again without looking")

  let keeping = try aLogicShowingTheTracksAndTheEventList(theWriteLetsARegionGo: false)
  keeping.hold(theRegionsOfTracks: [2, 5])

  let refused = try midiNotes(["--track", "4", "--region", "1"], against: keeping)

  #expect(refused.status == 20, "the number the design system gives selection_mismatch")
  #expect(
    try refused.failure()["code"] as? String == "selection_mismatch",
    "Logic holds a region nobody named, so there is no one region to read")
  #expect(try refused.printed()["data"] is NSNull, "no note of another region is answered")
  #expect(
    keeping.writes.filter { $0 == "the region of track 4" }.count == 2,
    "the named region is written once to take it, and once more to let it go after the refusal")
  let refusedDetails = try refused.failure()["details"] as? [String: Any] ?? [:]
  #expect(
    refusedDetails["selectionBefore"] as? [String]
      == ["the region of track 2", "the region of track 5"],
    "a command that was refused says which regions it took away")
}
