import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import Testing

@testable import logicctl

/// The sentence the approved mockup of this command carries.
private let driverOff =
  "The IAC driver is off. Open Audio MIDI Setup, show the MIDI Studio, and enable the IAC Driver"

/// What one run wrote, on each channel.
private final class Printed {
  var out = ""
  var err = ""

  func write(_ text: String) {
    out += text
  }

  func writeError(_ text: String) {
    err += text
  }

  /// What standard output carried, read back as JSON.
  func json() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// The code of the failure the answer carries, or nil when it carries none.
  func failureCode() throws -> String? {
    let failure = try json()["error"] as? [String: Any]
    return failure?["code"] as? String
  }
}

/// A Mac that carries these MIDI destinations and no others.
private struct Mac {
  let destinations: [MidiDestination]

  /// The bus, as the command reads it.
  var bus: MidiBus {
    MidiBus(destinations: { destinations })
  }
}

/// A person sets up the MIDI route to Logic, and the IAC driver of this Mac is off.
///
/// Every command that plays something, `midi note`, `midi chord` and `midi cc`, sends to a port
/// named logicctl. A Mac without that port takes the notes and drops them, so those three report
/// success while Logic hears nothing and the region stays empty. This command is the gate in front
/// of them: it fails with its own code and its own exit number, and it says the three things the
/// person does in Audio MIDI Setup to fix it. A script reads 13 and goes no further.
///
/// The same Mac with the port answers the other way: the name of the bus, whether the port is
/// online, exit 0, and nothing on standard error.
@Test func setupReportsTheIacDriverOff() throws {
  let typed = try Logicctl.parseAsRoot(["midi", "setup"])
  #expect(typed is Midi.Setup)

  let off = Mac(destinations: [MidiDestination(name: "Network Session 1", isOffline: false)])
  let refused = Printed()

  let status = Midi.Setup.answer(
    of: off.bus,
    standardOutput: refused.write,
    standardError: refused.writeError)

  #expect(status == 13)
  let code = try refused.failureCode()
  #expect(code == "midi_unavailable")

  let printed = try refused.json()
  #expect(printed["data"] is NSNull)
  let failure = printed["error"] as? [String: Any]
  #expect(failure?["message"] as? String == driverOff)
  #expect(failure?["details"] is NSNull)

  let meta = printed["meta"] as? [String: Any]
  #expect(meta?["version"] as? String == Logicctl.version)
  #expect(meta?["session"] is NSNull)
  #expect(meta?["step"] is NSNull)
  #expect(meta?["durationMs"] as? Int != nil)
  #expect(refused.err == "logicctl: midi_unavailable: \(driverOff)\n")
  #expect(refused.out.hasSuffix("}\n"))
  #expect(refused.out.filter(\.isNewline).count == 1)

  let ready = Mac(destinations: [
    MidiDestination(name: "Network Session 1", isOffline: false),
    MidiDestination(name: "logicctl", isOffline: false),
  ])
  let answer = Printed()

  let found = Midi.Setup.answer(
    of: ready.bus,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(found == 0)
  let read = try answer.json()
  #expect(read["error"] is NSNull)
  let data = read["data"] as? [String: Any]
  #expect(data?["bus"] as? String == "logicctl")
  #expect(data?["seenByLogic"] as? Bool == true)
  #expect(data?.keys.sorted() == ["bus", "seenByLogic"])
  #expect(answer.err.isEmpty)

  let asleep = Mac(destinations: [MidiDestination(name: "logicctl", isOffline: true)])
  let offline = Printed()

  let carried = Midi.Setup.answer(
    of: asleep.bus,
    standardOutput: offline.write,
    standardError: offline.writeError)

  #expect(carried == 0)
  let sleeping = try offline.json()["data"] as? [String: Any]
  #expect(sleeping?["bus"] as? String == "logicctl")
  #expect(sleeping?["seenByLogic"] as? Bool == false)
}
