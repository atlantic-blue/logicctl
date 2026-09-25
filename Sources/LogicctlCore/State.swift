import Foundation

/// What logicctl reads from Logic to compare, and what `state.json` holds.
///
/// The notes, the automation points, the playhead and the front window are not here. Reading a
/// note needs a selection and the Event List, which would change what the operator sees before
/// every command, and the playhead moves when nobody changed the project.
public struct State: Sendable, Equatable {
  /// The version of the schema this state was written with.
  public var schema: Int

  /// The Logic that the state was read from.
  public var logic: LogicVersion

  /// The project that is open in Logic.
  public var project: Project

  /// What the transport of Logic is doing.
  public var transport: Transport

  /// The tracks, in the order Logic shows them.
  public var tracks: [Track]

  public init(
    schema: Int = 1,
    logic: LogicVersion,
    project: Project,
    transport: Transport,
    tracks: [Track]
  ) {
    self.schema = schema
    self.logic = logic
    self.project = project
    self.transport = transport
    self.tracks = tracks
  }

  /// The state as the JSON value that the canonical form and the comparison read.
  public var json: JSONValue {
    .object([
      "schema": .number(Double(schema)),
      "logic": logic.json,
      "project": project.json,
      "transport": transport.json,
      "tracks": .array(tracks.map(\.json)),
    ])
  }
}

/// The Logic that a state was read from.
public struct LogicVersion: Sendable, Equatable {
  /// The version of Logic, for example `12.3.1`.
  public var version: String

  public init(version: String) {
    self.version = version
  }

  /// This part of the state as a JSON value.
  public var json: JSONValue {
    .object(["version": .string(version)])
  }
}

/// The project that is open in Logic.
public struct Project: Sendable, Equatable {
  /// The name in the title of the Logic window.
  public var name: String

  /// The time of the last save, or null before the first save.
  public var savedAt: Date?

  public init(name: String, savedAt: Date? = nil) {
    self.name = name
    self.savedAt = savedAt
  }

  /// This part of the state as a JSON value. A time is RFC 3339 in UTC, as the output rules say.
  public var json: JSONValue {
    .object([
      "name": .string(name),
      "savedAt": savedAt.map { JSONValue.string(Project.text(of: $0)) } ?? .null,
    ])
  }

  /// One time as one text. A hash must not move when a formatter reads a different locale or
  /// a different time zone, so the form is fixed here.
  static func text(of moment: Date) -> String {
    moment.formatted(Project.form)
  }

  /// The one form a time is written in, and the one form it is read back from.
  static let form = Date.ISO8601FormatStyle(
    dateSeparator: .dash,
    dateTimeSeparator: .standard,
    timeSeparator: .colon,
    timeZoneSeparator: .omitted,
    includingFractionalSeconds: false,
    timeZone: .gmt)
}

/// What the transport of Logic is doing.
public struct Transport: Sendable, Equatable {
  /// True while Logic plays.
  public var playing: Bool

  /// True while Logic records.
  public var recording: Bool

  /// The tempo, in beats per minute.
  public var tempo: Double

  public init(playing: Bool = false, recording: Bool = false, tempo: Double) {
    self.playing = playing
    self.recording = recording
    self.tempo = tempo
  }

  /// This part of the state as a JSON value.
  public var json: JSONValue {
    .object([
      "playing": .bool(playing),
      "recording": .bool(recording),
      "tempo": .number(tempo),
    ])
  }
}

/// One track of the project.
public struct Track: Sendable, Equatable {
  /// What kind of track it is.
  public enum Kind: String, Sendable, Equatable, CaseIterable {
    case softwareInstrument = "software-instrument"
    case audio = "audio"
    case other = "other"
  }

  /// The number of the track, from 1. This is the number `--index` takes.
  public var index: Int

  /// The name Logic shows in the track header.
  public var name: String

  /// What kind of track it is.
  public var type: Kind

  /// True while the track is muted.
  public var mute: Bool

  /// True while the track is soloed.
  public var solo: Bool

  /// True while the track is armed to record.
  public var arm: Bool

  /// The regions of the track, in order from the left.
  public var regions: [Region]

  /// The plugins of the channel strip, in slot order.
  public var plugins: [Plugin]

  public init(
    index: Int,
    name: String,
    type: Kind,
    mute: Bool = false,
    solo: Bool = false,
    arm: Bool = false,
    regions: [Region] = [],
    plugins: [Plugin] = []
  ) {
    self.index = index
    self.name = name
    self.type = type
    self.mute = mute
    self.solo = solo
    self.arm = arm
    self.regions = regions
    self.plugins = plugins
  }

  /// The track as a JSON value.
  public var json: JSONValue {
    .object([
      "index": .number(Double(index)),
      "name": .string(name),
      "type": .string(type.rawValue),
      "mute": .bool(mute),
      "solo": .bool(solo),
      "arm": .bool(arm),
      "regions": .array(regions.map(\.json)),
      "plugins": .array(plugins.map(\.json)),
    ])
  }
}

/// One region on a track.
public struct Region: Sendable, Equatable {
  /// The number of the region, from 1, in order from the left. This is the number `--region`
  /// takes.
  public var index: Int

  /// The text of the region item, for example `MIDI Region`.
  public var name: String

  /// Where the region starts, from the help text of the region item, for example `1 bar`.
  public var start: String

  /// Where the region ends, from the help text of the region item, for example `2 bars`.
  public var end: String

  public init(index: Int, name: String, start: String, end: String) {
    self.index = index
    self.name = name
    self.start = start
    self.end = end
  }

  /// The region as a JSON value.
  public var json: JSONValue {
    .object([
      "index": .number(Double(index)),
      "name": .string(name),
      "start": .string(start),
      "end": .string(end),
    ])
  }
}

/// One plugin of a channel strip.
public struct Plugin: Sendable, Equatable {
  /// The slot the plugin sits in, from 1.
  public var slot: Int

  /// The name Logic shows in the slot.
  public var name: String

  /// The hash of the settings of the plugin at the last save, or null before the first save.
  /// It does not change between two saves, whatever happens in Logic.
  public var stateHash: String?

  public init(slot: Int, name: String, stateHash: String? = nil) {
    self.slot = slot
    self.name = name
    self.stateHash = stateHash
  }

  /// The plugin as a JSON value.
  public var json: JSONValue {
    .object([
      "slot": .number(Double(slot)),
      "name": .string(name),
      "stateHash": stateHash.map { JSONValue.string($0) } ?? .null,
    ])
  }
}
