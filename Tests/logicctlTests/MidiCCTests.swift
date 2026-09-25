import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-cc-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A git whose configuration signs every commit, with a signing program that always fails.
///
/// A session repository turns signing off for itself, so no test here reads or writes the
/// configuration of the operator.
private func gitThatSigns(inside folder: URL) throws -> Git {
  let configuration = folder.appendingPathComponent("gitconfig")
  let written = """
    [commit]
    \tgpgsign = true
    [gpg]
    \tprogram = /usr/bin/false
    """
  try Data(written.utf8).write(to: configuration, options: .atomic)
  return Git(environment: [
    "GIT_CONFIG_GLOBAL": configuration.path,
    "GIT_CONFIG_SYSTEM": "/dev/null",
  ])
}

/// The sentence the approved mockup carries for a Mac that cannot reach Logic over MIDI.
private let theDriverIsOff =
  "The IAC driver is off. Open Audio MIDI Setup, show the MIDI Studio, and enable the IAC Driver"

/// Where the project of these tests sits.
private let projectPath = "/Users/someone/Music/Sketch.logicx"

/// The controller the approved story moves, and where it moves to. Controller 1 is the modulation
/// wheel, and 64 is the middle of its travel.
private let modulationWheel = 1
private let halfway = 64

/// The project Logic has open: one software instrument track, waiting for a control change.
private func aProjectWithOneTrack() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// The session of that project, as an earlier command started it.
private func aSession() -> Session {
  Session(
    project: Session.Project(name: "Sketch", path: projectPath, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// The bus of a test: what went out, in the order it went.
private final class ABusThatRecords {
  /// What the command sent, in the order it sent it.
  private(set) var sent: [MidiMessage] = []

  /// The way out the command is given.
  var output: MidiOutput {
    MidiOutput(destination: MidiDestination(name: "logicctl", isOffline: false)) { message in
      self.sent.append(message)
    }
  }
}

/// A Mac that takes no picture of the window, which is every Mac the pipeline runs on.
private struct NoPictureOfTheWindow: WindowCapturer {
  struct TookNone: Error {}

  func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    throw TookNone()
  }
}

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

/// The subjects of every commit of a session, newest first.
private func subjects(of folder: URL, with git: Git) throws -> [String] {
  try git.run(["log", "--format=%s"], in: folder)
    .split(separator: "\n", omittingEmptySubsequences: true)
    .map(String.init)
}

/// What the `step.json` of one step holds.
private func record(ofStep sequence: Int, in folder: URL) throws -> [String: Any] {
  let file =
    folder
    .appendingPathComponent("steps")
    .appendingPathComponent(SessionRepository.stepFolderName(ofSequence: sequence))
    .appendingPathComponent("step.json")
  let read = try JSONSerialization.jsonObject(with: try Data(contentsOf: file))
  return read as? [String: Any] ?? [:]
}

/// A person turns a knob in Logic, and Logic must hear the number that person asked for.
///
/// A control change is how everything that is not a note reaches an instrument: the modulation
/// wheel, the sustain pedal, the level of a send. It is one message, and it carries seven bits, so
/// the wire holds 0 to 127 and nothing else. A number above that does not arrive as an error. It
/// wraps: 128 reaches Logic as 0. A command that let it through would report that it moved the
/// wheel, while Logic heard the wheel go to nothing, which is the opposite of what was asked. So
/// the value is held to the scale before the bus is opened, and a value outside it plays nothing
/// at all.
///
/// The message reaches Logic through the port named logicctl, and a Mac without that port takes
/// nothing. That Mac gets the failure of `midi setup`, with its own exit number, and sends
/// nothing, because a command that reported a change there would be reporting a change Logic never
/// heard.
///
/// One control change is one step of the session, so a person can read what logicctl sent, and a
/// replay can send it again.
@Test func aControlChangeReachesTheBus() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: project, git: git)
  let driver = FakeLogicDriver(state: project, path: projectPath)

  let typed = try Logicctl.parseAsRoot(["midi", "cc", "--number", "1", "--value", "64"])
  let asked = try #require(typed as? Midi.ControlChange)
  #expect(asked.number == modulationWheel)
  #expect(asked.value == halfway)

  let bus = ABusThatRecords()
  let answer = Printed()

  let status = Midi.ControlChange.answer(
    number: asked.number,
    value: asked.value,
    openingTheBus: { bus.output },
    driver: driver,
    root: root,
    version: "0.1.0",
    git: git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 0)
  #expect(bus.sent.count == 1, "a control change is one message")
  let moved = try #require(bus.sent.first)
  #expect(moved.kind == .controlChange)
  #expect(
    moved.bytes == [0xB0, 1, 64],
    "Logic hears a control change on channel 1, of controller 1, at 64")

  let printed = try answer.json()
  #expect(printed["error"] is NSNull)
  let data = printed["data"] as? [String: Any]
  #expect(data?["sent"] as? Int == 1, "one message was sent")
  #expect(data?.keys.sorted() == ["sent"])
  #expect(answer.err.isEmpty)
  #expect(answer.out.hasSuffix("}\n"))
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and one newline")

  let meta = printed["meta"] as? [String: Any]
  #expect(meta?["session"] as? String == session.session.id)
  let commit = try #require(meta?["step"] as? String, "the control change is in the record")
  #expect(!commit.isEmpty)

  #expect(
    try subjects(of: session.folder, with: git) == [
      "1 midi cc", "session \(session.session.shortId)",
    ],
    "the control change the command sent is one step of the session")
  let step = try record(ofStep: 1, in: session.folder)
  #expect(step["kind"] as? String == "command")
  #expect(step["command"] as? String == "midi cc")
  #expect(
    step["argv"] as? [String] == ["--number", "1", "--value", "64"],
    "a replay of the step sends the same message")
  #expect(step["exitCode"] as? Int == 0)

  let quiet = ABusThatRecords()
  let refused = Printed()

  let withNoBus = Midi.ControlChange.answer(
    number: modulationWheel,
    value: halfway,
    openingTheBus: { nil },
    driver: driver,
    root: root,
    version: "0.1.0",
    git: git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: refused.write,
    standardError: refused.writeError)

  #expect(withNoBus == 13)
  #expect(try refused.failureCode() == "midi_unavailable")
  #expect(quiet.sent.isEmpty, "a Mac with no port sends nothing")
  let failure = try refused.json()["error"] as? [String: Any]
  #expect(failure?["message"] as? String == theDriverIsOff)
  #expect(refused.err == "logicctl: midi_unavailable: \(theDriverIsOff)\n")
  let refusedMeta = try refused.json()["meta"] as? [String: Any]
  #expect(refusedMeta?["session"] is NSNull, "nothing reached the project")
  #expect(refusedMeta?["step"] is NSNull, "nothing was recorded")
  #expect(
    try subjects(of: session.folder, with: git).count == 2,
    "the session gained nothing from a message that was never sent")

  for line in [
    ["midi", "cc", "--number", "1", "--value", "128"],
    ["midi", "cc", "--number", "1", "--value", "-1"],
    ["midi", "cc", "--number", "128", "--value", "64"],
    ["midi", "cc", "--number", "-1", "--value", "64"],
    ["midi", "cc", "--number", "1"],
    ["midi", "cc", "--value", "64"],
  ] {
    let outside = Printed()

    let stopped = Logicctl.run(
      arguments: line, standardOutput: outside.write, standardError: outside.writeError)

    #expect(stopped == 2, "a control change logicctl cannot send is refused")
    #expect(try outside.failureCode() == "invalid_argument")
  }

  // The channel mode messages sit at the top of the range, and Logic takes them like any other
  // controller, so the command sends them rather than deciding for the person.
  for number in [0, 120, 127] {
    let taken = try Logicctl.parseAsRoot(["midi", "cc", "--number", "\(number)", "--value", "0"])
    let read = try #require(taken as? Midi.ControlChange)
    try read.validate()
    #expect(read.number == number)
  }
}
