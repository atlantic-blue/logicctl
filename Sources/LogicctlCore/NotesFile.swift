import Foundation

/// One note of `notes.json`, in beats.
///
/// The times are in beats and not in seconds or in ticks, because a person writing the file reads
/// beats in Logic, and because the tempo of the file turns beats into either of the other two.
public struct NoteRequest: Sendable, Equatable {
  /// Which key, 0 to 127.
  public var pitch: Int

  /// How hard the key is struck, 1 to 127. A note of 0 is a note that is not played, so the file
  /// says nothing by carrying it.
  public var velocity: Int

  /// Where the note starts, in beats from the start of the file.
  public var start: Double

  /// How long the note sounds, in beats.
  public var length: Double

  /// Which of the 16 MIDI channels the note is sent on.
  public var channel: Int

  public init(pitch: Int, velocity: Int, start: Double, length: Double, channel: Int = 1) {
    self.pitch = pitch
    self.velocity = velocity
    self.start = start
    self.length = length
    self.channel = channel
  }
}

/// What `midi write-file` reads: a tempo and the notes to write, as part 8 of the data model says.
///
/// Every value is held to the scale the data model gives it, and the first value that is outside
/// its scale stops the read. The refusal names the field, so a caller that wrote the file by hand
/// is told where to look instead of being told that the file is wrong.
public struct NotesFile: Sendable, Equatable {
  /// Why a file was refused, and which field carries the trouble.
  ///
  /// The message reads `<field> must be <rule>`, and the answer of the command carries the field
  /// on its own in `details`, so an agent reads the field without reading the sentence.
  public struct Refusal: Error, Equatable {
    /// The field, for example `tempo` or `notes[3].pitch`.
    public let field: String

    /// What the field must be, for example `0 to 127`.
    public let rule: String

    public init(field: String, rule: String) {
      self.field = field
      self.rule = rule
    }

    /// The one sentence the answer carries.
    public var message: String {
      "\(field) must be \(rule)"
    }
  }

  /// Ticks for each beat, when the file does not say.
  public static let defaultPpq = 480

  /// Beats each minute, from the data model.
  public static let tempoRange = 20.0...999.0

  /// Ticks for each beat. The division field of the header of a MIDI file carries 15 bits, so
  /// 32767 is the most a file can say, whatever the data model allows a caller to ask for.
  public static let ppqRange = 1...32767

  public static let pitchRange = 0...127
  public static let velocityRange = 1...127
  public static let channelRange = 1...16

  /// Beats each minute, written into the file as a tempo event.
  public var tempo: Double

  /// Ticks for each beat.
  public var ppq: Int

  /// The notes, in the order the file listed them. The writer decides the order of the bytes.
  public var notes: [NoteRequest]

  public init(tempo: Double, ppq: Int = NotesFile.defaultPpq, notes: [NoteRequest]) {
    self.tempo = tempo
    self.ppq = ppq
    self.notes = notes
  }

  /// The keys the file carries. Anything else is refused, because a key that is ignored reads to
  /// the person who wrote it as a key that was obeyed.
  static let fileKeys = ["tempo", "ppq", "notes"]

  /// The keys one note carries.
  static let noteKeys = ["pitch", "velocity", "start", "length", "channel"]

  static let tempoRule = "a number from 20 to 999"
  static let ppqRule = "a whole number from 1 to 32767"
  static let notesRule = "a list with at least one note"
  static let noteRule = "an object with pitch, velocity, start and length"
  static let pitchRule = "0 to 127"
  static let velocityRule = "1 to 127"
  static let startRule = "0 or more"
  static let lengthRule = "more than 0"
  static let channelRule = "1 to 16"

  /// Reads a file, or refuses it and names the field that stopped the read.
  public static func read(_ text: String) throws -> NotesFile {
    guard let value = try? CanonicalJSON.value(of: text), case .object(let members) = value else {
      throw Refusal(field: "--in", rule: "a JSON object")
    }
    try refuseUnknownKey(in: members, allowed: fileKeys, under: "")

    let tempo = try number(members["tempo"], field: "tempo", rule: tempoRule)
    guard tempoRange.contains(tempo) else {
      throw Refusal(field: "tempo", rule: tempoRule)
    }
    let ppq = try wholeNumber(
      members["ppq"], field: "ppq", rule: ppqRule, within: ppqRange, or: defaultPpq)

    guard case .array(let rows)? = members["notes"], !rows.isEmpty else {
      throw Refusal(field: "notes", rule: notesRule)
    }
    var notes: [NoteRequest] = []
    for (position, row) in rows.enumerated() {
      notes.append(try note(row, at: position))
    }
    return NotesFile(tempo: tempo, ppq: ppq, notes: notes)
  }

  /// One note of the list, with the field of any refusal written as `notes[<position>].<key>`.
  static func note(_ row: JSONValue, at position: Int) throws -> NoteRequest {
    let under = "notes[\(position)]"
    guard case .object(let members) = row else {
      throw Refusal(field: under, rule: noteRule)
    }
    try refuseUnknownKey(in: members, allowed: noteKeys, under: under)

    let pitch = try wholeNumber(
      members["pitch"], field: "\(under).pitch", rule: pitchRule, within: pitchRange)
    let velocity = try wholeNumber(
      members["velocity"], field: "\(under).velocity", rule: velocityRule,
      within: velocityRange)
    let start = try number(members["start"], field: "\(under).start", rule: startRule)
    guard start >= 0 else {
      throw Refusal(field: "\(under).start", rule: startRule)
    }
    let length = try number(members["length"], field: "\(under).length", rule: lengthRule)
    guard length > 0 else {
      throw Refusal(field: "\(under).length", rule: lengthRule)
    }
    let channel = try wholeNumber(
      members["channel"], field: "\(under).channel", rule: channelRule, within: channelRange,
      or: 1)
    return NoteRequest(
      pitch: pitch, velocity: velocity, start: start, length: length, channel: channel)
  }

  /// The first key that does not belong, in one order, so the same file names the same key every
  /// time it is read.
  static func refuseUnknownKey(
    in members: [String: JSONValue], allowed: [String], under prefix: String
  ) throws {
    let unknown = members.keys.filter { !allowed.contains($0) }.sorted()
    guard let first = unknown.first else {
      return
    }
    throw Refusal(
      field: prefix.isEmpty ? first : "\(prefix).\(first)", rule: "one of \(listed(allowed))")
  }

  /// A number the file must carry. A key that is missing, a null, a string and a true are all the
  /// same thing to a reader: the number is not there.
  static func number(_ value: JSONValue?, field: String, rule: String) throws -> Double {
    guard case .number(let carried)? = value, carried.isFinite else {
      throw Refusal(field: field, rule: rule)
    }
    return carried
  }

  /// A whole number the file must carry, inside its scale.
  static func wholeNumber(
    _ value: JSONValue?, field: String, rule: String, within range: ClosedRange<Int>
  ) throws -> Int {
    let carried = try number(value, field: field, rule: rule)
    guard carried.rounded() == carried, let whole = Int(exactly: carried), range.contains(whole)
    else {
      throw Refusal(field: field, rule: rule)
    }
    return whole
  }

  /// A whole number the file may leave out, which then takes the value beside it.
  static func wholeNumber(
    _ value: JSONValue?, field: String, rule: String, within range: ClosedRange<Int>,
    or fallback: Int
  ) throws -> Int {
    guard value != nil else {
      return fallback
    }
    return try wholeNumber(value, field: field, rule: rule, within: range)
  }

  /// Some keys as one phrase: `tempo, ppq and notes`.
  static func listed(_ keys: [String]) -> String {
    guard let last = keys.last else {
      return ""
    }
    guard keys.count > 1 else {
      return last
    }
    return keys.dropLast().joined(separator: ", ") + " and " + last
  }
}
