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

/// Where the project of this scenario sits.
private let projectPath = "/Users/someone/Music/Sketch.logicx"

/// How long Logic is given to start recording, in milliseconds.
private let theLimit = 200

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

/// The Control Bar of the scenario: what the command pressed, and the Logic that answers a press.
///
/// A Logic given here starts a take when its Record button is pressed. Measured on this Mac at
/// 15:27 on 2026-09-26 against Logic 12.3.1: one press of Record moved both the Play and the
/// Record button of the Control Bar to 1, so the Logic here sets both. A Control Bar given no
/// Logic stands for the press that reaches Logic and starts nothing: no take runs, and the
/// transport says so.
private final class AControlBar {
  /// The controls the command pressed inside the window of the project, in the order it pressed
  /// them.
  private(set) var pressedInTheWindow: [String] = []

  /// The items the command pressed in the menu bar. The Control Bar is in the window, so a press
  /// that lands here is a press in the wrong tree.
  private(set) var pressedInTheMenuBar: [String] = []

  /// The Logic that answers the press, or none when nothing answers it.
  private let heardBy: FakeLogicDriver?

  init(heardBy: FakeLogicDriver? = nil) {
    self.heardBy = heardBy
  }

  /// What the command presses through.
  var actions: TrackActions {
    TrackActions(
      press: { locator in
        self.pressedInTheMenuBar.append(locator.name)
      },
      pressInWindow: { locator in
        self.pressedInTheWindow.append(locator.name)
        self.heardBy?.state?.transport.recording = true
        self.heardBy?.state?.transport.playing = true
      })
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
/// A take is the one thing here that costs a performance to get wrong. logicctl starts it the way
/// a person does, by pressing the Record button of the Control Bar, and what happens next is up to
/// Logic. So the answer is read back from the transport of Logic after the press, and never from
/// the press. A command that printed `recording: true` because it pressed something would report a
/// take on every Mac where Logic is idle. A person would then play the part, and there would be
/// nothing to keep.
///
/// The press reaches Logic through Accessibility and nothing goes over MIDI, so this command asks
/// nothing of the IAC driver. A Mac with the driver off records, where before it was refused with
/// `midi_unavailable` and no take at all.
///
/// Three things can happen, and each one is answered on its own terms. The press starts a take,
/// and the answer carries the transport Logic reads back. The press lands and no take starts, so
/// the command gives up at its limit with `timeout` and says how long Logic was given, which is a
/// person's cue to look at Logic or to wait longer. Logic is already recording, and the command
/// presses nothing and answers that it is recording: the Record button is a check box, so a second
/// press would turn the take off and the performance would be gone.
///
/// One record is one step of the session, so a person reads what logicctl did and a replay does it
/// again.
@Test func recordPressesTheRecordButtonOfTheControlBar() throws {
  let recording = try aLogic(showing: anIdleProject())
  let ignoring = try aLogic(showing: anIdleProject())
  let already = try aLogic(showing: aRecordingProject())
  defer {
    for folder in [recording.root, ignoring.root, already.root] {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  let typed = try Logicctl.parseAsRoot(["transport", "record"])
  #expect(typed is TransportCommand.Record, "the noun and the verb of the design system")
  #expect(
    recording.driver.state?.transport.recording == false,
    "Logic is recording nothing before the command runs")

  let controlBar = AControlBar(heardBy: recording.driver)
  let answer = Printed()
  let time = RecordTime()

  let status = TransportCommand.Record.answer(
    driver: recording.driver,
    actions: controlBar.actions,
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
  #expect(
    controlBar.pressedInTheWindow == [Locators.transportRecordButton.name],
    "one press, on the Record button of the Control Bar")
  #expect(
    controlBar.pressedInTheMenuBar.isEmpty,
    "the Control Bar sits in the window of the project, and not in the menu bar")

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
    "the press is one step of the session")
  let step = try record(ofStep: 1, in: recording.session.folder)
  #expect(step["command"] as? String == "transport record")
  #expect(step["argv"] as? [String] == [], "record takes no flag of its own")
  #expect(step["exitCode"] as? Int == 0)

  // The press lands and no take starts. The command gives up at its limit rather than reporting a
  // take that is not running.
  let ignored = AControlBar()
  let refused = Printed()
  let waited = RecordTime()

  let gaveUp = TransportCommand.Record.answer(
    driver: ignoring.driver,
    actions: ignored.actions,
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
  #expect(
    ignored.pressedInTheWindow == [Locators.transportRecordButton.name],
    "the press went in, and Logic started nothing")
  #expect(ignoring.driver.state?.transport.recording == false, "the transport is as it was")
  #expect(
    try record(ofStep: 1, in: ignoring.session.folder)["exitCode"] as? Int == 6,
    "the step records what the command answered")

  // Logic is already recording. The Record button is a check box, so a press here would stop the
  // take. The command presses nothing and answers the transport it reads.
  let running = AControlBar(heardBy: already.driver)
  let again = Printed()
  let noWait = RecordTime()

  let recordingAlready = TransportCommand.Record.answer(
    driver: already.driver,
    actions: running.actions,
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
  #expect(running.pressedInTheWindow.isEmpty, "a take that runs is left running")
  #expect(noWait.now == 0, "the recording transport is read before the command sleeps")
  #expect(already.driver.state?.transport.recording == true, "the take is still running")
  #expect(
    try record(ofStep: 1, in: already.session.folder)["command"] as? String == "transport record",
    "a record of a recording transport is a step like any other")
}
