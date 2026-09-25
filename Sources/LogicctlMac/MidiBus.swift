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
