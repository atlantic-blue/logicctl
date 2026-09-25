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
    .appendingPathComponent("logicctl-chord-\(UUID().uuidString)")
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

/// The keys of a C major chord, the chord the approved story plays.
private let cMajor = [60, 64, 67]

/// The project Logic has open: one software instrument track, waiting for a chord.
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

/// The bus of a test: what went out, and the moment each message went.
///
/// The clock of this bus moves only when the command sleeps, so the gap between two messages is
/// the gap the command asked for and not the gap the machine happened to take.
private final class ABusThatRecords {
  /// What the command sent, in the order it sent it.
  private(set) var sent: [(message: MidiMessage, atMs: Int)] = []

  /// The moment this bus is at, in milliseconds.
  private var nowMs = 0

  /// The way out the command is given.
  var output: MidiOutput {
    MidiOutput(destination: MidiDestination(name: "logicctl", isOffline: false)) { message in
      self.sent.append((message: message, atMs: self.nowMs))
    }
  }

  /// The sleep the command is given. It moves this bus instead of holding the thread.
  func sleep(_ milliseconds: Int) {
    nowMs += milliseconds
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

/// A person asks Logic for a chord, and Logic must hear the keys go down together.
///
/// A chord is several keys held at once. A command that struck one key and let it go, then struck
/// the next, would play the same notes one after the other, and that is an arpeggio and not a
/// chord: Logic records three short notes in a row, and the person who asked for C major gets a
/// broken chord. So the order of the messages is the whole behaviour here. Every key goes down
/// before any key comes up, and the keys come up after the length.
///
/// The chord reaches Logic through the port named logicctl, and a Mac without that port takes
/// nothing at all. That Mac gets the failure of `midi setup`, with its own exit number, and plays
/// nothing, because a command that reported a chord there would be reporting a chord Logic never
/// heard. A key or a velocity outside the scale Logic shows is refused before anything is played.
///
/// One chord is one step of the session, so a person can read what logicctl played, and a replay
/// can play it again.
@Test func aChordSendsEveryNoteOnFirst() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: project, git: git)
  let driver = FakeLogicDriver(state: project, path: projectPath)

  let typed = try Logicctl.parseAsRoot(["midi", "chord", "--pitches", "60,64,67"])
  let asked = try #require(typed as? Midi.Chord)
  #expect(try Midi.Chord.keys(of: asked.pitches) == cMajor)
  #expect(asked.loudness == 100, "a chord with no velocity is struck at 100")
  #expect(asked.length.milliseconds == 500, "a chord with no length is held for half a second")

  let bus = ABusThatRecords()
  let answer = Printed()

  let status = Midi.Chord.answer(
    pitches: cMajor,
    velocity: asked.loudness,
    length: asked.length,
    openingTheBus: { bus.output },
    driver: driver,
    root: root,
    version: "0.1.0",
    sleeper: bus.sleep,
    git: git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 0)
  #expect(bus.sent.count == 6, "three keys go down and the same three come up")

  let struck = bus.sent.prefix(cMajor.count)
  #expect(
    struck.allSatisfy { $0.message.kind == .noteOn },
    "every key of the chord goes down before any key comes up")
  #expect(struck.map(\.message.pitch) == cMajor, "the keys go down in the order they were asked")
  #expect(
    struck.allSatisfy { $0.atMs == 0 },
    "the chord sounds as one, so no key waits for another")
  #expect(struck.allSatisfy { $0.message.velocity == 100 }, "every key is struck as hard")
  #expect(struck.first?.message.bytes == [0x90, 60, 100])

  let released = bus.sent.dropFirst(cMajor.count)
  #expect(released.allSatisfy { $0.message.kind == .noteOff })
  #expect(released.map(\.message.pitch) == cMajor)
  #expect(
    released.allSatisfy { $0.atMs == 500 }, "the keys are held for the length before they come up")
  #expect(released.first?.message.bytes == [0x80, 60, 0])

  let printed = try answer.json()
  #expect(printed["error"] is NSNull)
  let data = printed["data"] as? [String: Any]
  #expect(data?["sent"] as? Int == 3, "three notes were sent")
  #expect(data?.keys.sorted() == ["sent"])
  #expect(answer.err.isEmpty)
  #expect(answer.out.hasSuffix("}\n"))
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and one newline")

  let meta = printed["meta"] as? [String: Any]
  #expect(meta?["session"] as? String == session.session.id)
  let commit = try #require(meta?["step"] as? String, "the chord is in the record")
  #expect(!commit.isEmpty)

  #expect(
    try subjects(of: session.folder, with: git) == [
      "1 midi chord", "session \(session.session.shortId)",
    ],
    "the chord the command played is one step of the session")
  let step = try record(ofStep: 1, in: session.folder)
  #expect(step["kind"] as? String == "command")
  #expect(step["command"] as? String == "midi chord")
  let asItWasPlayed = ["--pitches", "60,64,67", "--velocity", "100", "--length", "500ms"]
  #expect(
    step["argv"] as? [String] == asItWasPlayed, "a replay of the step plays the same chord")
  #expect(step["exitCode"] as? Int == 0)

  let quiet = ABusThatRecords()
  let refused = Printed()

  let withNoBus = Midi.Chord.answer(
    pitches: cMajor,
    velocity: 100,
    length: DurationValue(milliseconds: 500),
    openingTheBus: { nil },
    driver: driver,
    root: root,
    version: "0.1.0",
    sleeper: quiet.sleep,
    git: git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: refused.write,
    standardError: refused.writeError)

  #expect(withNoBus == 13)
  #expect(try refused.failureCode() == "midi_unavailable")
  #expect(quiet.sent.isEmpty, "a Mac with no port plays nothing")
  let failure = try refused.json()["error"] as? [String: Any]
  #expect(failure?["message"] as? String == theDriverIsOff)
  #expect(refused.err == "logicctl: midi_unavailable: \(theDriverIsOff)\n")
  let refusedMeta = try refused.json()["meta"] as? [String: Any]
  #expect(refusedMeta?["session"] is NSNull, "nothing reached the project")
  #expect(refusedMeta?["step"] is NSNull, "nothing was recorded")
  #expect(
    try subjects(of: session.folder, with: git).count == 2,
    "the session gained nothing from a chord that was never played")

  for line in [
    ["midi", "chord", "--pitches", "60,64,67", "--velocity", "128"],
    ["midi", "chord", "--pitches", "60,64,128"],
    ["midi", "chord", "--pitches", "60,60,67"],
    ["midi", "chord", "--pitches", ""],
  ] {
    let outside = Printed()

    let stopped = Logicctl.run(
      arguments: line, standardOutput: outside.write, standardError: outside.writeError)

    #expect(stopped == 2, "a chord logicctl cannot play is refused")
    #expect(try outside.failureCode() == "invalid_argument")
  }
}
