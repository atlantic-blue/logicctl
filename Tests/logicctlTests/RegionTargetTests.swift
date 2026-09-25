import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
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
