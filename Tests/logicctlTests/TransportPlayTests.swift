import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// A folder no other test writes into, for one part of the scenario.
private func aFolderOfItsOwn() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-play-\(UUID().uuidString)")
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

/// Where the project of this scenario sits.
private let projectPath = "/Users/someone/Music/Sketch.logicx"

/// How long Logic is given to start playing, in milliseconds.
private let theLimit = 200

/// The six bytes of the Machine Control play message, as they go on the wire.
private let thePlayMessage: [UInt8] = [0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7]

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class PlayTime {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// The project Logic has open: one software instrument track, and a transport that is stopped.
private func aStoppedProject() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(playing: false, recording: false, tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// The session of that project, as an earlier command started it.
private func aSession() -> Session {
  Session(
    project: Session.Project(name: "Sketch", path: projectPath, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// A Logic that is stopped, with the session of its project, in a folder of its own.
private struct AStoppedLogic {
  let root: URL
  let git: Git
  let session: SessionRepository
  let driver: FakeLogicDriver
}

private func aStoppedLogic() throws -> AStoppedLogic {
  let root = try aFolderOfItsOwn()
  let git = try gitThatSigns(inside: root)
  let project = aStoppedProject()
  return AStoppedLogic(
    root: root,
    git: git,
    session: try SessionRepository.start(
      session: aSession(), root: root, state: project, git: git),
    driver: FakeLogicDriver(state: project, path: projectPath))
}

/// The bus of the scenario: what went out, and the Logic that hears it.
///
/// A Logic that takes Machine Control answers a play message by playing, so a bus given that Logic
/// moves its transport. A bus given none stands for the Logic that hears the message and does
/// nothing with it: the transport stays stopped, and the state says so.
private final class ABus {
  /// What the command sent, in the order it sent it.
  private(set) var sent: [MachineControlMessage] = []

  /// The Logic that answers the message, or none when nothing answers it.
  private let heardBy: FakeLogicDriver?

  init(heardBy: FakeLogicDriver? = nil) {
    self.heardBy = heardBy
  }

  /// The way out the command is given.
  var output: MachineControlOutput {
    let port = MidiDestination(name: "logicctl", isOffline: false)
    return MachineControlOutput(destination: port) { message in
      self.sent.append(message)
      self.heardBy?.state?.transport.playing = true
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

  /// The data of the answer, or nil when the answer carries none.
  func data() throws -> [String: Any]? {
    try json()["data"] as? [String: Any]
  }

  /// The code of the failure the answer carries, or nil when it carries none.
  func failureCode() throws -> String? {
    let failure = try json()["error"] as? [String: Any]
    return failure?["code"] as? String
  }

  /// What the failure says to the person who ran the command.
  func failureMessage() throws -> String? {
    let failure = try json()["error"] as? [String: Any]
    return failure?["message"] as? String
  }

  /// What the failure says about itself.
  func failureDetails() throws -> [String: Any] {
    let failure = try json()["error"] as? [String: Any]
    return failure?["details"] as? [String: Any] ?? [:]
  }

  /// The `meta` of the answer.
  func meta() throws -> [String: Any] {
    try json()["meta"] as? [String: Any] ?? [:]
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

/// A person or an agent starts playback, and reads whether Logic is playing.
///
/// Playback is the one thing here that logicctl cannot see itself. The message leaves this Mac over
/// the bus, and what happens next is up to Logic: the port can be missing, and Logic takes Machine
/// Control only when its own settings say so. So the answer is read back from the transport of
/// Logic after the message, and never from the message. A command that printed `playing: true`
/// because it sent six bytes would report playback on every Mac where nothing is playing, and an
/// agent that read that answer would go on to record silence.
///
/// Three things can happen, and each one is answered on its own terms. The message reaches a Logic
/// that plays, and the answer carries the transport Logic reads back. This Mac carries no port
/// named logicctl, so nothing is sent at all, and the answer is the failure of `midi setup` with
/// its own exit number. The message goes out and the transport stays stopped, so the command gives
/// up at its limit with `timeout` and says how long Logic was given, which is a person's cue to
/// turn Machine Control on in Logic or to wait longer.
///
/// One play is one step of the session, so a person reads what logicctl sent and a replay sends it
/// again.
@Test func playReadsPlayingBack() throws {
  let playing = try aStoppedLogic()
  let ignoring = try aStoppedLogic()
  let quiet = try aStoppedLogic()
  defer {
    for folder in [playing.root, ignoring.root, quiet.root] {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  let typed = try Logicctl.parseAsRoot(["transport", "play"])
  #expect(typed is TransportCommand.Play, "the noun and the verb of the design system")
  #expect(
    playing.driver.state?.transport.playing == false, "Logic is stopped before the command runs")

  let bus = ABus(heardBy: playing.driver)
  let answer = Printed()
  let time = PlayTime()

  let status = TransportCommand.Play.answer(
    openingTheBus: { bus.output },
    driver: playing.driver,
    root: playing.root,
    version: "0.1.0",
    limitMs: theLimit,
    clock: time.read,
    sleeper: time.sleep,
    git: playing.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 0, "Logic is playing")
  #expect(bus.sent.count == 1, "playback is one message")
  #expect(bus.sent.first == MachineControlMessage.play, "and the message is play")
  #expect(
    bus.sent.first?.bytes == thePlayMessage,
    "Logic hears the Machine Control play message, addressed to every device")

  let printed = try answer.json()
  #expect(printed["error"] is NSNull, "nothing failed")
  #expect(try answer.data()?["playing"] as? Bool == true, "the transport Logic reads back")
  #expect(try answer.data()?["recording"] as? Bool == false, "play records nothing")
  #expect(try answer.data()?.keys.sorted() == ["playing", "recording"], "and nothing else")
  #expect(answer.err.isEmpty, "standard error is empty on success")
  #expect(answer.out.hasSuffix("}\n"))
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and one newline")

  let meta = try answer.meta()
  #expect(meta["session"] as? String == playing.session.session.id)
  let commit = try #require(meta["step"] as? String, "the play is in the record")
  #expect(!commit.isEmpty)
  #expect(
    try subjects(of: playing.session.folder, with: playing.git) == [
      "1 transport play", "session \(playing.session.session.shortId)",
    ],
    "the play the command sent is one step of the session")
  let step = try record(ofStep: 1, in: playing.session.folder)
  #expect(step["command"] as? String == "transport play")
  #expect(step["argv"] as? [String] == [], "play takes no flag of its own")
  #expect(step["exitCode"] as? Int == 0)

  // Logic hears the message and the transport stays stopped, which is every Logic that takes no
  // Machine Control input. The command gives up at its limit rather than reporting playback.
  let ignored = ABus()
  let refused = Printed()
  let waited = PlayTime()

  let gaveUp = TransportCommand.Play.answer(
    openingTheBus: { ignored.output },
    driver: ignoring.driver,
    root: ignoring.root,
    version: "0.1.0",
    limitMs: theLimit,
    clock: waited.read,
    sleeper: waited.sleep,
    git: ignoring.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: refused.write,
    standardError: refused.writeError)

  #expect(gaveUp == 6, "the number the design system gives timeout")
  #expect(try refused.failureCode() == "timeout", "Logic did not start playing")
  #expect(try refused.failureDetails()["waitedMs"] as? Int == theLimit, "how long Logic was given")
  let gaveUpJson = try refused.json()
  #expect(gaveUpJson["data"] is NSNull, "no answer is made up for a Logic that is stopped")
  #expect(ignored.sent.count == 1, "the message went out, and Logic did nothing with it")
  #expect(ignoring.driver.state?.transport.playing == false, "the transport is as it was")
  #expect(
    try record(ofStep: 1, in: ignoring.session.folder)["exitCode"] as? Int == 6,
    "the step records what the command answered")

  // This Mac carries no port named logicctl, so the command never reaches a bus at all.
  let withNoBus = Printed()

  let stopped = TransportCommand.Play.answer(
    openingTheBus: { nil },
    driver: quiet.driver,
    root: quiet.root,
    version: "0.1.0",
    limitMs: theLimit,
    git: quiet.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: withNoBus.write,
    standardError: withNoBus.writeError)

  #expect(stopped == 13, "the number the design system gives midi_unavailable")
  #expect(try withNoBus.failureCode() == "midi_unavailable")
  #expect(
    try withNoBus.failureMessage() == theDriverIsOff,
    "the sentence that says how to switch the driver on")
  #expect(withNoBus.err == "logicctl: midi_unavailable: \(theDriverIsOff)\n")
  #expect(quiet.driver.state?.transport.playing == false, "a Mac with no port plays nothing")
  #expect(try withNoBus.meta()["session"] is NSNull, "nothing reached the project")
  #expect(try withNoBus.meta()["step"] is NSNull, "nothing was recorded")
  #expect(
    try subjects(of: quiet.session.folder, with: quiet.git).count == 1,
    "the session gained nothing from a message that was never sent")
}
