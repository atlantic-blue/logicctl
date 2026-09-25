import CoreMIDI
import Foundation

/// One Machine Control message, which is how logicctl moves the transport of Logic.
///
/// Machine Control is a system exclusive message and not a channel message. It carries no channel,
/// and its bytes sit between `F0` and `F7` rather than in a status byte and two numbers after it.
/// So it is its own type here, beside `MidiMessage`, and the two meet only at the port they both go
/// out of.
public struct MachineControlMessage: Sendable, Equatable {
  /// What the message asks the transport to do.
  public enum Kind: Sendable, Equatable {
    /// Start playing from where the playhead sits.
    case play

    /// Stop the transport where it is.
    case stop

    /// Start recording on the tracks that are armed.
    case record

    /// The byte the Machine Control command set gives this command.
    var command: UInt8 {
      switch self {
      case .play: return 0x02
      case .stop: return 0x01
      case .record: return 0x06
      }
    }
  }

  /// What the message asks for.
  public let kind: Kind

  /// The device the message is addressed to.
  public let device: UInt8

  /// The number every device on the bus answers to. logicctl talks to the one Logic on this Mac
  /// and not to a studio of machines, so no flag moves it.
  public static let everyDevice: UInt8 = 0x7F

  /// The byte that opens a message meant for every device, whatever the device number says.
  public static let universal: UInt8 = 0x7F

  /// The byte that names the Machine Control command set.
  public static let commandSet: UInt8 = 0x06

  /// The byte that opens a system exclusive message.
  public static let start: UInt8 = 0xF0

  /// The byte that closes a system exclusive message.
  public static let end: UInt8 = 0xF7

  public init(kind: Kind, device: UInt8 = MachineControlMessage.everyDevice) {
    self.kind = kind
    self.device = device
  }

  /// Start playing.
  public static let play = MachineControlMessage(kind: .play)

  /// Stop the transport.
  public static let stop = MachineControlMessage(kind: .stop)

  /// Start recording. The Machine Control command set calls this one Record Strobe.
  public static let record = MachineControlMessage(kind: .record)

  /// The six bytes of the message.
  public var bytes: [UInt8] {
    [
      MachineControlMessage.start,
      MachineControlMessage.universal,
      device,
      MachineControlMessage.commandSet,
      kind.command,
      MachineControlMessage.end,
    ]
  }
}

/// An open way out of this Mac to one MIDI destination, for Machine Control.
///
/// The send is a closure the caller gives, so a test reads what went out and in which order, and
/// this Mac is asked nothing. Opening it is the part that needs CoreMIDI, and a command opens it
/// before it acts, so a Mac that cannot open a port says so before it reports any playback.
public struct MachineControlOutput {
  /// Sends one message. It throws when this Mac refuses to take it.
  public typealias Send = (MachineControlMessage) throws -> Void

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

extension MachineControlOutput {
  /// A way out to one destination of this Mac, over CoreMIDI.
  ///
  /// The client and the port are made once, here, and the closure holds them while the command
  /// runs.
  public static func live(to destination: MidiDestination) throws -> MachineControlOutput {
    var client = MIDIClientRef()
    guard MIDIClientCreate("logicctl" as CFString, nil, nil, &client) == noErr else {
      throw Refusal(reason: "This Mac did not open a MIDI client for logicctl.")
    }
    var port = MIDIPortRef()
    guard MIDIOutputPortCreate(client, "logicctl transport" as CFString, &port) == noErr else {
      throw Refusal(reason: "This Mac did not open a MIDI output port for logicctl.")
    }
    guard let endpoint = MidiBus.endpoint(named: destination.name) else {
      throw Refusal(reason: "This Mac carries no MIDI destination named \(destination.name).")
    }
    return MachineControlOutput(destination: destination) { message in
      try MachineControlOutput.send(message, through: port, to: endpoint)
    }
  }

  /// Sends one message out of one port, as a packet of its bytes.
  ///
  /// An event list carries one 32 bit word per message, which holds a channel message and holds no
  /// system exclusive one, so a Machine Control message goes out as a packet instead.
  private static func send(
    _ message: MachineControlMessage, through port: MIDIPortRef, to endpoint: MIDIEndpointRef
  ) throws {
    let bytes = message.bytes
    var list = MIDIPacketList()
    let first = MIDIPacketListInit(&list)
    guard
      MIDIPacketListAdd(
        &list, MemoryLayout<MIDIPacketList>.size, first, 0, bytes.count, bytes) != nil
    else {
      throw Refusal(reason: "The Machine Control message did not fit one MIDI packet.")
    }
    let status = MIDISend(port, endpoint, &list)
    guard status == noErr else {
      throw Refusal(
        reason: "This Mac refused the Machine Control message, with the status \(status).")
    }
  }
}
