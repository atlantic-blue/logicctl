import Foundation
import LogicctlCore
import LogicctlMac
import Testing

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

/// The Mixer of a project of six tracks, recorded on this Mac on 2026-09-26 after `tracks add
/// --type audio` made the third one.
private let theMixerWithAnAudioTrack = "mixer-with-audio-track.json"

/// The window of a project that holds three tracks and one region.
private let theTracksOfAProject = "region.json"

/// The tempo a test hands the reader. The display of the running Logic answers it on this Mac,
/// and the pipeline has no running Logic.
private let aTempo = 96

/// The tracks of the project the Mixer was recorded from, in the order Logic shows them.
private let theSixTracks = [
  "Deluxe Classic", "Deluxe Classic", "Audio 1", "Studio Grand", "Studio Grand", "Studio Grand",
]

/// What kind of track each of the six is, as a person sees it in Logic: five software instrument
/// tracks, and the audio track in the third place.
private let theSixKinds: [Track.Kind] = [
  .softwareInstrument, .softwareInstrument, .audio, .softwareInstrument, .softwareInstrument,
  .softwareInstrument,
]

/// The tracks of the recorded project, as the window shows them.
private let theThreeTracks = ["Deluxe Classic", "Deluxe Classic", "Studio Grand"]

/// What those three tracks read as against the recorded Mixer: two strips carry their names, and
/// the strip in the third place belongs to another track.
private let twoKindsAndAStranger: [Track.Kind] = [.softwareInstrument, .softwareInstrument, .other]

/// What every track reads as where no Mixer can be read at all.
private let noKindAtAll: [Track.Kind] = [.other, .other, .other]

/// A person or an agent asks what the project holds, and every track answers what kind it is.
///
/// A track is a software instrument track or an audio track, and what a person can do with one
/// they cannot do with the other: a note goes to an instrument, and a microphone goes to an input.
/// Until now every track answered `other`, because the track header of Logic says nothing about
/// the kind. So `tracks list` named no kind at all, an agent that made a track could not read back
/// which kind it got, and the journal kept `other` for every step of every session. The Mixer is
/// where Logic says it, and this is the read that goes and looks.
///
/// The reader opens the Mixer when a person has it closed, and closes it again afterwards, so the
/// answer does not depend on which windows somebody left open. A Mixer that was already open
/// stays open, because a command must not take a window away from the person using it. A Mixer
/// that will not open at all leaves the kinds at `other` and answers everything else, because a
/// read of a project is worth more than the one field it could not get.
///
/// The recorded Mixer and the recorded Tracks window are of two projects, so the strip in the
/// third place carries another track's name. That is what a Mixer somebody scrolled looks like,
/// and the kind of a track nobody can see is `other` rather than the kind of the strip that
/// happens to sit in its place.
@Test func theStateReaderReadsTheTypeOfEveryTrack() throws {
  let mixer = try recorded(theMixerWithAnAudioTrack).root
  let kinds = theSixTracks.enumerated().map { place, name in
    TrackReader.type(ofTrackNumber: place + 1, named: name, in: mixer)
  }

  #expect(kinds == theSixKinds, "the six tracks of the recorded Mixer, in track order")

  let tracks = try recorded(theTracksOfAProject).root
  let open = ALogicShowing(tracks: tracks, mixer: mixer, showingTheMixer: true)
  let read = try open.reader().state(after: nil)

  #expect(
    read.tracks.map(\.type) == twoKindsAndAStranger,
    "the two strips that carry the names of these tracks, and one that carries another name")
  #expect(read.tracks.map(\.name) == theThreeTracks, "the tracks Logic shows, as before")
  #expect(open.did.isEmpty, "the reader opened no Mixer, so it closed none either")

  let closed = ALogicShowing(tracks: tracks, mixer: mixer, showingTheMixer: false)
  let opened = try closed.reader().state(after: nil)

  #expect(
    opened.tracks.map(\.type) == twoKindsAndAStranger,
    "the same kinds, read from a Mixer the reader opened for itself")
  #expect(closed.did == ["open", "close"], "it opened the Mixer, and it put it back")
  #expect(opened.tracks.map(\.name) == theThreeTracks, "and the tracks are still read")

  let stuck = ALogicShowing(
    tracks: tracks, mixer: mixer, showingTheMixer: false, refusingToOpen: true)
  let unread = try stuck.reader().state(after: nil)

  #expect(unread.tracks.map(\.type) == noKindAtAll, "no Mixer, so no kind to read")
  #expect(stuck.did == ["open"], "it asked once, and it closed nothing it never opened")
  #expect(unread.tracks.map(\.name) == theThreeTracks, "the tracks are read as they always were")
  #expect(unread.transport.tempo == Double(aTempo), "and so is everything else in the state")
}

/// One tree of one window, as `inspect` recorded it from Logic 12.3.1.
private func recorded(_ file: String) throws -> LogicTree {
  let read = try RecordedTree(contentsOf: fixtureFolder.appending(path: file))
  return LogicTree(logicVersion: read.logicVersion, root: read.root)
}

/// A Logic that shows the Tracks window of one recording, and shows the Mixer of another once
/// something opens it.
///
/// It records what the reader asked it to do, in order, because the question this test asks is
/// whether the reader leaves the windows of a person as it found them.
private final class ALogicShowing {
  private let tracks: any AXNode
  private let mixer: any AXNode
  private let refuses: Bool
  private var showing: Bool

  /// What the reader asked Logic to do, in order.
  private(set) var did: [String] = []

  init(
    tracks: any AXNode, mixer: any AXNode, showingTheMixer: Bool, refusingToOpen: Bool = false
  ) {
    self.tracks = tracks
    self.mixer = mixer
    showing = showingTheMixer
    refuses = refusingToOpen
  }

  /// The windows Logic shows, in the order it answers them.
  var tree: LogicTree {
    let windows: [any AXNode] = showing ? [tracks, mixer] : [tracks]
    return LogicTree(
      logicVersion: Locators.recordedFrom,
      root: Element(role: "AXApplication", children: windows))
  }

  /// The reader over this Logic, with every read a running Logic answers given here.
  func reader() -> StateReader {
    StateReader(
      tree: { self.tree },
      status: AXDriver(tree: { self.tree }, applicationInFront: { nil }).status,
      name: { ProjectReader.name(inTitle: self.tree.atTheFrontWindow()?.root.title ?? "") },
      path: { nil },
      tempo: { aTempo },
      openMixer: {
        self.did.append("open")
        guard !self.refuses else {
          throw AMixerThatWillNotOpen()
        }
        self.showing = true
      },
      closeMixer: {
        self.did.append("close")
        self.showing = false
      })
  }
}

/// What a Logic that will not open its Mixer answers.
private struct AMixerThatWillNotOpen: Error {}

/// One element a test builds, where no recording carries the one it needs.
private struct Element: AXNode {
  var role: String
  var title: String? = nil
  var identifier: String? = nil
  var value: String? = nil
  var valueDescription: String? = nil
  var description: String? = nil
  var help: String? = nil
  var actions: [String] = []
  var children: [any AXNode] = []
}
