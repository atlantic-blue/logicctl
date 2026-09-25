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
    .appendingPathComponent("logicctl-record-\(UUID().uuidString)")
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

/// How long Logic is given to start recording, in milliseconds.
private let theLimit = 200

/// The six bytes of the Machine Control record message, as they go on the wire. The Machine
/// Control command set calls this one Record Strobe.
private let theRecordMessage: [UInt8] = [0xF0, 0x7F, 0x7F, 0x06, 0x06, 0xF7]

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class RecordTime {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// The project Logic has open: one software instrument track, and a transport that is idle.
private func anIdleProject() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(playing: false, recording: false, tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// The same project with a take already running.
private func aRecordingProject() -> State {
  var state = anIdleProject()
  state.transport.playing = true
  state.transport.recording = true
  return state
}

/// The session of that project, as an earlier command started it.
private func aSession() -> Session {
  Session(
    project: Session.Project(name: "Sketch", path: projectPath, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// A Logic with the session of its project, in a folder of its own.
private struct ALogic {
  let root: URL
  let git: Git
  let session: SessionRepository
  let driver: FakeLogicDriver
}

private func aLogic(showing project: State) throws -> ALogic {
  let root = try aFolderOfItsOwn()
  let git = try gitThatSigns(inside: root)
  return ALogic(
    root: root,
    git: git,
    session: try SessionRepository.start(
      session: aSession(), root: root, state: project, git: git),
    driver: FakeLogicDriver(state: project, path: projectPath))
}

/// The bus of the scenario: what went out, and the Logic that hears it.
///
/// A Logic that takes Machine Control answers a record message by starting a take, so a bus given
/// that Logic sets its transport recording. A bus given none stands for the Logic that hears the
/// message and does nothing with it: no take starts, and the state says so.
private final class ABus {
  /// What the command sent, in the order it sent it.
  private(set) var sent: [MachineControlMessage] = []

  /// The Logic that answers the message, or none when nothing answers it.
  private let heardBy: FakeLogicDriver?

  init(heardBy: FakeLogicDriver? = nil) {
    self.heardBy = heardBy
  }

  /// The way out the command is given.
  ///
  /// A Logic that records also rolls the transport, so this Logic sets both. The step makes a
  /// contract of `recording` alone, because what Logic does to `playing` while it records is read
  /// from Logic at the live acceptance and not decided here.
  var output: MachineControlOutput {
    let port = MidiDestination(name: "logicctl", isOffline: false)
    return MachineControlOutput(destination: port) { message in
      self.sent.append(message)
      self.heardBy?.state?.transport.recording = true
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

/// A person or an agent starts a take, and reads whether Logic is recording.
///
/// A take is the one thing here that costs a performance to get wrong. The message leaves this Mac
/// over the bus, and what happens next is up to Logic: the port can be missing, and Logic takes
/// Machine Control only when its own settings say so. So the answer is read back from the
/// transport of Logic after the message, and never from the message. A command that printed
/// `recording: true` because it sent six bytes would report a take on every Mac where Logic is
/// idle. A person would then play the part, and there would be nothing to keep.
///
/// Four things can happen, and each one is answered on its own terms. The message reaches a Logic
/// that starts recording, and the answer carries the transport Logic reads back. This Mac carries
/// no port named logicctl, so nothing is sent at all, and the answer is the failure of
/// `midi setup` with its own exit number. The message goes out and no take starts, so the command
/// gives up at its limit with `timeout` and says how long Logic was given, which is a person's cue
/// to turn Machine Control on in Logic or to wait longer. Logic is already recording, and the
/// command answers that it is recording without waiting, because a record sets a state and never
/// toggles one.
///
/// One record is one step of the session, so a person reads what logicctl sent and a replay sends
/// it again.
@Test func recordReadsRecordingBack() throws {
  let recording = try aLogic(showing: anIdleProject())
  let ignoring = try aLogic(showing: anIdleProject())
  let quiet = try aLogic(showing: anIdleProject())
  let already = try aLogic(showing: aRecordingProject())
  defer {
    for folder in [recording.root, ignoring.root, quiet.root, already.root] {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  let typed = try Logicctl.parseAsRoot(["transport", "record"])
  #expect(typed is TransportCommand.Record, "the noun and the verb of the design system")
  #expect(
    recording.driver.state?.transport.recording == false,
    "Logic is recording nothing before the command runs")

  let bus = ABus(heardBy: recording.driver)
  let answer = Printed()
  let time = RecordTime()

  let status = TransportCommand.Record.answer(
    openingTheBus: { bus.output },
    driver: recording.driver,
    root: recording.root,
    version: "0.1.0",
    limitMs: theLimit,
    clock: time.read,
    sleeper: time.sleep,
    git: recording.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 0, "Logic is recording")
  #expect(bus.sent.count == 1, "a record is one message")
  #expect(bus.sent.first == MachineControlMessage.record, "and the message is record")
  #expect(
    bus.sent.first?.bytes == theRecordMessage,
    "Logic hears the Machine Control record message, addressed to every device")

  let printed = try answer.json()
  #expect(printed["error"] is NSNull, "nothing failed")
  #expect(try answer.data()?["recording"] as? Bool == true, "the transport Logic reads back")
  #expect(try answer.data()?.keys.sorted() == ["playing", "recording"], "and what else it says")
  #expect(answer.err.isEmpty, "standard error is empty on success")
  #expect(answer.out.hasSuffix("}\n"))
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and one newline")

  let meta = try answer.meta()
  #expect(meta["session"] as? String == recording.session.session.id)
  let commit = try #require(meta["step"] as? String, "the take is in the record")
  #expect(!commit.isEmpty)
  #expect(
    try subjects(of: recording.session.folder, with: recording.git) == [
      "1 transport record", "session \(recording.session.session.shortId)",
    ],
    "the record the command sent is one step of the session")
  let step = try record(ofStep: 1, in: recording.session.folder)
  #expect(step["command"] as? String == "transport record")
  #expect(step["argv"] as? [String] == [], "record takes no flag of its own")
  #expect(step["exitCode"] as? Int == 0)

  // Logic hears the message and no take starts, which is every Logic that takes no Machine
  // Control input. The command gives up at its limit rather than reporting a take.
  let ignored = ABus()
  let refused = Printed()
  let waited = RecordTime()

  let gaveUp = TransportCommand.Record.answer(
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
  #expect(try refused.failureCode() == "timeout", "Logic did not start recording")
  #expect(try refused.failureDetails()["waitedMs"] as? Int == theLimit, "how long Logic was given")
  let gaveUpJson = try refused.json()
  #expect(gaveUpJson["data"] is NSNull, "no take is made up for a Logic that is idle")
  #expect(ignored.sent.count == 1, "the message went out, and Logic did nothing with it")
  #expect(ignoring.driver.state?.transport.recording == false, "the transport is as it was")
  #expect(
    try record(ofStep: 1, in: ignoring.session.folder)["exitCode"] as? Int == 6,
    "the step records what the command answered")

  // This Mac carries no port named logicctl, so the command never reaches a bus at all.
  let withNoBus = Printed()

  let sentNothing = TransportCommand.Record.answer(
    openingTheBus: { nil },
    driver: quiet.driver,
    root: quiet.root,
    version: "0.1.0",
    limitMs: theLimit,
    git: quiet.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: withNoBus.write,
    standardError: withNoBus.writeError)

  #expect(sentNothing == 13, "the number the design system gives midi_unavailable")
  #expect(try withNoBus.failureCode() == "midi_unavailable")
  #expect(
    try withNoBus.failureMessage() == theDriverIsOff,
    "the sentence that says how to switch the driver on")
  #expect(withNoBus.err == "logicctl: midi_unavailable: \(theDriverIsOff)\n")
  #expect(quiet.driver.state?.transport.recording == false, "a Mac with no port records nothing")
  #expect(try withNoBus.meta()["session"] is NSNull, "nothing reached the project")
  #expect(try withNoBus.meta()["step"] is NSNull, "nothing was recorded")
  #expect(
    try subjects(of: quiet.session.folder, with: quiet.git).count == 1,
    "the session gained nothing from a message that was never sent")

  // Logic is already recording. A record sets a state and never toggles one, so the command
  // answers that Logic is recording, and it waits for nothing to change.
  let running = ABus(heardBy: already.driver)
  let again = Printed()
  let noWait = RecordTime()

  let recordingAlready = TransportCommand.Record.answer(
    openingTheBus: { running.output },
    driver: already.driver,
    root: already.root,
    version: "0.1.0",
    limitMs: theLimit,
    clock: noWait.read,
    sleeper: noWait.sleep,
    git: already.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: again.write,
    standardError: again.writeError)

  #expect(recordingAlready == 0, "a transport that records is what the command asked for")
  #expect(try again.data()?["recording"] as? Bool == true, "and the answer says so")
  #expect(noWait.now == 0, "the recording transport is read before the command sleeps")
  #expect(running.sent.count == 1, "the message goes out, because Logic says what the transport is")
  #expect(
    try record(ofStep: 1, in: already.session.folder)["command"] as? String == "transport record",
    "a record of a recording transport is a step like any other")
}
