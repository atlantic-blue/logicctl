import CoreMIDI
import Foundation

/// One place this Mac can send MIDI to.
///
/// A destination is what an application opens to play notes into something else. The IAC driver of
/// macOS makes one for each port a person adds to it, and that port is how logicctl reaches Logic.
public struct MidiDestination: Sendable, Equatable {
  /// The name of the port, as Audio MIDI Setup shows it.
  public let name: String

  /// Whether this Mac says the destination is offline. An offline destination is there and takes
  /// nothing.
  public let isOffline: Bool

  public init(name: String, isOffline: Bool) {
    self.name = name
    self.isOffline = isOffline
  }
}

/// The MIDI destinations of this Mac, and the one logicctl sends to.
///
/// Every read is a closure the caller gives. The pipeline has no CoreMIDI server and no IAC driver,
/// so a test drives this with the destinations it wants and this Mac is asked nothing.
public struct MidiBus {
  /// Reads every destination this Mac carries now.
  public typealias Reader = () -> [MidiDestination]

  /// The name of the port logicctl sends to. A person makes it once, in Audio MIDI Setup.
  public static let busName = "logicctl"

  /// Reads the destinations.
  public let destinations: Reader

  public init(destinations: @escaping Reader) {
    self.destinations = destinations
  }

  /// The destination with this name, or nil when this Mac carries none.
  public func named(_ name: String = MidiBus.busName) -> MidiDestination? {
    destinations().first { $0.name == name }
  }
}

extension MidiBus {
  /// The destinations of this Mac, as CoreMIDI answers them now.
  ///
  /// A destination that answers with no name is left out, because nothing can ask for it by name.
  /// Reading a property asks for no MIDI client, so this opens nothing and sends nothing.
  public static func live() -> MidiBus {
    MidiBus(destinations: {
      (0..<MIDIGetNumberOfDestinations()).compactMap { index in
        let endpoint = MIDIGetDestination(index)
        guard endpoint != 0, let name = text(kMIDIPropertyName, of: endpoint) else {
          return nil
        }
        return MidiDestination(
          name: name, isOffline: number(kMIDIPropertyOffline, of: endpoint) != 0)
      }
    })
  }

  /// A text property of one MIDI object, or nil when it carries none.
  private static func text(_ property: CFString, of object: MIDIObjectRef) -> String? {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, property, &value) == noErr else {
      return nil
    }
    guard let found = value?.takeRetainedValue() else {
      return nil
    }
    return found as String
  }

  /// A whole number property of one MIDI object. A property that is not there reads as zero, which
  /// is what CoreMIDI means by a flag that was never set.
  private static func number(_ property: CFString, of object: MIDIObjectRef) -> Int32 {
    var value: Int32 = 0
    guard MIDIObjectGetIntegerProperty(object, property, &value) == noErr else {
      return 0
    }
    return value
  }
}

extension MidiBus {
  /// The endpoint of the destination with this name, or nil when this Mac carries none.
  ///
  /// CoreMIDI addresses a destination by its endpoint, and `MidiDestination` carries the name a
  /// person reads instead, so the name is looked up again here when something is sent.
  static func endpoint(named name: String) -> MIDIEndpointRef? {
    for index in 0..<MIDIGetNumberOfDestinations() {
      let endpoint = MIDIGetDestination(index)
      if endpoint != 0, MidiBus.text(kMIDIPropertyName, of: endpoint) == name {
        return endpoint
      }
    }
    return nil
  }
}

/// One MIDI message logicctl sends.
///
/// A note is two messages and not one. Note on starts it and note off stops it, and a note that
/// never gets its note off holds the key down for as long as Logic stays open.
///
/// Every message here carries two numbers after its status byte. A note reads them as the key and
/// how hard it was struck. A control change reads the same two as the controller it moves and where
/// that controller lands.
public struct MidiMessage: Sendable, Equatable {
  /// What the message does.
  public enum Kind: String, Sendable, Equatable {
    /// Start a note.
    case noteOn = "note_on"

    /// Stop a note.
    case noteOff = "note_off"

    /// Move one controller of the instrument.
    case controlChange = "control_change"
  }

  public let kind: Kind

  /// The key, 0 to 127, where 60 is middle C.
  public let pitch: Int

  /// How hard the key is struck for a note on, and how fast it is let go for a note off.
  public let velocity: Int

  /// The channel, 1 to 16, as Logic counts them.
  public let channel: Int

  public init(kind: Kind, pitch: Int, velocity: Int, channel: Int = 1) {
    self.kind = kind
    self.pitch = pitch
    self.velocity = velocity
    self.channel = channel
  }

  /// A key struck this hard.
  public static func noteOn(pitch: Int, velocity: Int, channel: Int = 1) -> MidiMessage {
    MidiMessage(kind: .noteOn, pitch: pitch, velocity: velocity, channel: channel)
  }

  /// A key let go. No flag sets the release velocity, so it is 0, which every instrument reads.
  public static func noteOff(pitch: Int, channel: Int = 1) -> MidiMessage {
    MidiMessage(kind: .noteOff, pitch: pitch, velocity: 0, channel: channel)
  }

  /// One controller moved to one place. This is how everything that is not a note reaches an
  /// instrument: the modulation wheel, the sustain pedal, the level of a send.
  public static func controlChange(number: Int, value: Int, channel: Int = 1) -> MidiMessage {
    MidiMessage(kind: .controlChange, pitch: number, velocity: value, channel: channel)
  }

  /// The controller this message moves, for a control change.
  public var controller: Int { pitch }

  /// Where that controller lands, for a control change.
  public var amount: Int { velocity }

  /// The three bytes of the message. MIDI carries seven bits of each value and counts channels
  /// from 0, so the numbers a person reads are cut to the wire here and nowhere else.
  public var bytes: [UInt8] {
    let status: UInt8
    switch kind {
    case .noteOn: status = 0x90
    case .noteOff: status = 0x80
    case .controlChange: status = 0xB0
    }
    return [
      status | (UInt8(truncatingIfNeeded: channel - 1) & 0x0F),
      UInt8(truncatingIfNeeded: pitch) & 0x7F,
      UInt8(truncatingIfNeeded: velocity) & 0x7F,
    ]
  }
}

/// An open way out of this Mac to one MIDI destination.
///
/// The send is a closure the caller gives, so a test drives what goes out, and in which order, and
/// this Mac is asked nothing. Opening it is the part that needs CoreMIDI, and a command opens it
/// before it acts, so a Mac that cannot open a port says so before it plays anything.
public struct MidiOutput {
  /// Sends one message. It throws when this Mac refuses to take it.
  public typealias Send = (MidiMessage) throws -> Void

  /// Where the messages go.
  public let destination: MidiDestination

  /// Sends one message.
  public let send: Send

  public init(destination: MidiDestination, send: @escaping Send) {
    self.destination = destination
    self.send = send
  }

  /// Why this Mac took nothing.
  public struct Refusal: Error, Equatable {
    /// One sentence a person can act on.
    public let reason: String

    public init(reason: String) {
      self.reason = reason
    }
  }
}

extension MidiOutput {
  /// A way out to one destination of this Mac, over CoreMIDI.
  ///
  /// The client and the port are made once, here, and the closure holds them while the command
  /// runs.
  public static func live(to destination: MidiDestination) throws -> MidiOutput {
    var client = MIDIClientRef()
    guard MIDIClientCreate("logicctl" as CFString, nil, nil, &client) == noErr else {
      throw Refusal(reason: "This Mac did not open a MIDI client for logicctl.")
    }
    var port = MIDIPortRef()
    guard MIDIOutputPortCreate(client, "logicctl out" as CFString, &port) == noErr else {
      throw Refusal(reason: "This Mac did not open a MIDI output port for logicctl.")
    }
    guard let endpoint = MidiBus.endpoint(named: destination.name) else {
      throw Refusal(reason: "This Mac carries no MIDI destination named \(destination.name).")
    }
    return MidiOutput(destination: destination) { message in
      try MidiOutput.send(message, through: port, to: endpoint)
    }
  }

  /// Sends one message out of one port, as an event list carrying a single MIDI 1.0 message.
  private static func send(
    _ message: MidiMessage, through port: MIDIPortRef, to endpoint: MIDIEndpointRef
  ) throws {
    var list = MIDIEventList()
    let packet = MIDIEventListInit(&list, ._1_0)
    var word = MidiOutput.word(of: message)
    _ = MIDIEventListAdd(
      &list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
    let status = MIDISendEventList(port, endpoint, &list)
    guard status == noErr else {
      throw Refusal(reason: "This Mac refused the MIDI message, with the status \(status).")
    }
  }

  /// One MIDI 1.0 channel message as the 32 bit word CoreMIDI takes: the message type 2, the
  /// group 0, then the three bytes of the message.
  static func word(of message: MidiMessage) -> UInt32 {
    let bytes = message.bytes
    return (UInt32(0x2) << 28) | (UInt32(bytes[0]) << 16) | (UInt32(bytes[1]) << 8)
      | UInt32(bytes[2])
  }
}
