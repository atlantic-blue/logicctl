import Foundation

/// Reads a state back from the JSON that `state.json` carries.
///
/// `State.json` writes it, and this reads it, so the two are one pair and the round trip is what
/// proves they agree. A command needs this because the plugins of a track come from the Mixer, and
/// Logic shows the Mixer only while a person keeps it open: the first read of a command takes the
/// plugins of the state the session recorded last, and a walk that sees no strip leaves them as
/// they were.
///
/// A value that is not a state logicctl wrote reads as nothing, rather than as a state with a field
/// made up here. A made up field would reach the comparison as a change nobody made.
extension State {
  /// The state one `state.json` holds, or nothing when the value is not a state logicctl wrote.
  public init?(json: JSONValue) {
    guard let schema = numberValue(member("schema", of: json)),
      let logic = member("logic", of: json).flatMap(LogicVersion.init(json:)),
      let project = member("project", of: json).flatMap(Project.init(json:)),
      let transport = member("transport", of: json).flatMap(Transport.init(json:)),
      let written = arrayValue(member("tracks", of: json))
    else {
      return nil
    }
    var read: [Track] = []
    for track in written {
      guard let one = Track(json: track) else {
        return nil
      }
      read.append(one)
    }
    self.init(
      schema: Int(schema), logic: logic, project: project, transport: transport, tracks: read)
  }
}

extension LogicVersion {
  /// The Logic one state was read from, or nothing when the value carries no version.
  public init?(json: JSONValue) {
    guard let version = stringValue(member("version", of: json)) else {
      return nil
    }
    self.init(version: version)
  }
}

extension Project {
  /// The project one state holds, or nothing when the value carries no name.
  ///
  /// A time that is not the form the writer writes reads as no time, because a project that was
  /// never saved carries none either and a guess there would name a save that never happened.
  public init?(json: JSONValue) {
    guard let name = stringValue(member("name", of: json)) else {
      return nil
    }
    let written = stringValue(member("savedAt", of: json))
    self.init(name: name, savedAt: written.flatMap(Project.time(of:)))
  }

  /// The moment one written time names, or nothing when the text is not the form the writer wrote.
  static func time(of written: String) -> Date? {
    try? Project.form.parse(written)
  }
}

extension Transport {
  /// What the transport was doing, or nothing when the value carries less than the three fields.
  public init?(json: JSONValue) {
    guard let playing = boolValue(member("playing", of: json)),
      let recording = boolValue(member("recording", of: json)),
      let tempo = numberValue(member("tempo", of: json))
    else {
      return nil
    }
    self.init(playing: playing, recording: recording, tempo: tempo)
  }
}

extension Track {
  /// One track of a state, or nothing when the value carries less than a whole track.
  public init?(json: JSONValue) {
    guard let index = numberValue(member("index", of: json)),
      let name = stringValue(member("name", of: json)),
      let kind = stringValue(member("type", of: json)).flatMap(Kind.init(rawValue:)),
      let mute = boolValue(member("mute", of: json)),
      let solo = boolValue(member("solo", of: json)),
      let arm = boolValue(member("arm", of: json)),
      let written = arrayValue(member("regions", of: json)),
      let strip = arrayValue(member("plugins", of: json))
    else {
      return nil
    }
    var regions: [Region] = []
    for region in written {
      guard let one = Region(json: region) else {
        return nil
      }
      regions.append(one)
    }
    var plugins: [Plugin] = []
    for plugin in strip {
      guard let one = Plugin(json: plugin) else {
        return nil
      }
      plugins.append(one)
    }
    self.init(
      index: Int(index), name: name, type: kind, mute: mute, solo: solo, arm: arm,
      regions: regions, plugins: plugins)
  }
}

extension Region {
  /// One region of a track, or nothing when the value carries less than a whole region.
  public init?(json: JSONValue) {
    guard let index = numberValue(member("index", of: json)),
      let name = stringValue(member("name", of: json)),
      let start = stringValue(member("start", of: json)),
      let end = stringValue(member("end", of: json))
    else {
      return nil
    }
    self.init(index: Int(index), name: name, start: start, end: end)
  }
}

extension Plugin {
  /// One plugin of a channel strip, or nothing when the value carries no slot and no name.
  public init?(json: JSONValue) {
    guard let slot = numberValue(member("slot", of: json)),
      let name = stringValue(member("name", of: json))
    else {
      return nil
    }
    self.init(slot: Int(slot), name: name, stateHash: stringValue(member("stateHash", of: json)))
  }
}

/// The member one object carries, or nothing when the value is no object or holds no such key.
private func member(_ name: String, of value: JSONValue) -> JSONValue? {
  guard case .object(let members) = value else {
    return nil
  }
  return members[name]
}

/// The text one value carries, or nothing when it is no text. Null reads as nothing, which is how
/// a state says that a project was never saved and that a plugin carries no hash.
private func stringValue(_ value: JSONValue?) -> String? {
  guard let value, case .string(let written) = value else {
    return nil
  }
  return written
}

/// The number one value carries, or nothing when it is no number.
private func numberValue(_ value: JSONValue?) -> Double? {
  guard let value, case .number(let read) = value else {
    return nil
  }
  return read
}

/// The true or false one value carries, or nothing when it is neither.
private func boolValue(_ value: JSONValue?) -> Bool? {
  guard let value, case .bool(let read) = value else {
    return nil
  }
  return read
}

/// The values one array carries, or nothing when the value is no array.
private func arrayValue(_ value: JSONValue?) -> [JSONValue]? {
  guard let value, case .array(let read) = value else {
    return nil
  }
  return read
}
