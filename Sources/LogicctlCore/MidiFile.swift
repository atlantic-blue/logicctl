import CryptoKit
import Foundation

/// The bytes of a standard MIDI file: format 0, one track, the tempo as a meta event.
///
/// The same notes give the same bytes. A file that changed between two runs would make every
/// replay of the session that wrote it differ, and the difference would be in logicctl and not in
/// Logic, so three things are fixed here rather than left to the order a person typed the notes
/// in. The events are sorted. Nothing carries a time of its own. No running status is used, so one
/// note always writes the same three bytes.
public enum MidiFile {
  /// One thing that happens at one tick: a note starts, or a note stops.
  struct Event: Sendable, Equatable {
    let tick: Int
    let isOff: Bool
    let pitch: Int
    let channel: Int
    let velocity: Int

    /// The first byte, which says what happens and on which channel. Channels are counted from 1
    /// in the file a person writes and from 0 in the bytes.
    var status: UInt8 {
      UInt8(isOff ? 0x80 : 0x90) | UInt8(channel - 1)
    }
  }

  /// The largest tick the format carries, because a delta time is a variable length quantity of
  /// four bytes at most.
  static let highestTick = 0x0fff_ffff

  /// The bytes of one file.
  public static func bytes(of file: NotesFile) -> [UInt8] {
    var out = Array("MThd".utf8)
    out += fourBytes(6)
    out += [0x00, 0x00, 0x00, 0x01]
    out += [UInt8((file.ppq >> 8) & 0xff), UInt8(file.ppq & 0xff)]

    let track = trackBytes(of: file)
    out += Array("MTrk".utf8)
    out += fourBytes(track.count)
    out += track
    return out
  }

  /// The SHA-256 of some bytes, in lowercase hexadecimal.
  public static func sha256(of bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
  }

  /// The one track: the tempo, then every note, then the end of the track.
  static func trackBytes(of file: NotesFile) -> [UInt8] {
    var out: [UInt8] = [0x00, 0xff, 0x51, 0x03]
    let microseconds = microsecondsForEachBeat(at: file.tempo)
    out += [
      UInt8((microseconds >> 16) & 0xff), UInt8((microseconds >> 8) & 0xff),
      UInt8(microseconds & 0xff),
    ]

    var last = 0
    for event in events(of: file) {
      out += variableLength(event.tick - last)
      last = event.tick
      out += [event.status, UInt8(event.pitch), UInt8(event.velocity)]
    }

    out += [0x00, 0xff, 0x2f, 0x00]
    return out
  }

  /// Every note as two events, in the one order the file writes them.
  static func events(of file: NotesFile) -> [Event] {
    var out: [Event] = []
    for note in file.notes {
      let starts = ticks(of: note.start, ppq: file.ppq)
      // A note is held for at least one tick. A length that is more than nothing in beats and
      // nothing in ticks would otherwise write a note that stops where it starts, and a note like
      // that is silent in Logic.
      let held = max(1, ticks(of: note.length, ppq: file.ppq))
      out.append(
        Event(
          tick: starts, isOff: false, pitch: note.pitch, channel: note.channel,
          velocity: note.velocity))
      out.append(
        Event(
          tick: starts + held, isOff: true, pitch: note.pitch, channel: note.channel, velocity: 0))
    }
    return out.sorted { comes($0, before: $1) }
  }

  /// Which of two events is written first.
  ///
  /// The data model asks for the notes by start, then by pitch. Two more rules are needed before
  /// the bytes are the same every run. A note that stops is written before a note that starts at
  /// the same tick, so one pitch that stops and starts again at that tick sounds twice instead of
  /// once. And the channel parts two notes that are the same in every other way.
  static func comes(_ left: Event, before right: Event) -> Bool {
    if left.tick != right.tick {
      return left.tick < right.tick
    }
    if left.isOff != right.isOff {
      return left.isOff
    }
    if left.pitch != right.pitch {
      return left.pitch < right.pitch
    }
    return left.channel < right.channel
  }

  /// Beats as ticks, with a half tick rounded away from zero. A time the format cannot carry is
  /// held at the end of the file rather than stopping the command.
  static func ticks(of beats: Double, ppq: Int) -> Int {
    let exact = (beats * Double(ppq)).rounded(.toNearestOrAwayFromZero)
    guard exact.isFinite else {
      return highestTick
    }
    return Int(min(Double(highestTick), max(0, exact)))
  }

  /// The tempo as the file writes it: how many microseconds one beat takes.
  static func microsecondsForEachBeat(at tempo: Double) -> Int {
    let exact = (60_000_000.0 / tempo).rounded()
    guard exact.isFinite else {
      return 0xff_ffff
    }
    return Int(min(Double(0xff_ffff), max(1, exact)))
  }

  /// A number as the variable length quantity the format writes a delta time in: seven bits of the
  /// number in each byte, and the top bit set on every byte but the last.
  static func variableLength(_ value: Int) -> [UInt8] {
    var rest = max(0, value)
    var out = [UInt8(rest & 0x7f)]
    rest >>= 7
    while rest > 0 {
      out.insert(UInt8((rest & 0x7f) | 0x80), at: 0)
      rest >>= 7
    }
    return out
  }

  /// A length as the four bytes a chunk header carries, highest byte first.
  static func fourBytes(_ value: Int) -> [UInt8] {
    [
      UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
  }
}
