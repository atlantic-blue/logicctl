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
    .appendingPathComponent("logicctl-stop-\(UUID().uuidString)")
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

/// How long Logic is given to stop, in milliseconds.
private let theLimit = 200

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class StopTime {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// Every control of the window of Logic that the command pressed, in the order it pressed them.
private final class Buttons {
  var pressed: [Locator] = []

  /// The name of the control the one press went to, or nothing when nothing was pressed.
  var theOneName: String? {
    pressed.count == 1 ? pressed.first?.name : nil
  }
}

/// The project Logic has open: one software instrument track, and a transport that is playing.
private func aPlayingProject() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(playing: true, recording: false, tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// The same project with a transport that is playing and recording.
private func aRecordingProject() -> State {
  var state = aPlayingProject()
  state.transport.recording = true
  return state
}

/// The same project with a transport that reads neither playing nor recording.
private func aStoppedProject() -> State {
  var state = aPlayingProject()
  state.transport.playing = false
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

/// Runs `transport stop` against one Logic, and says what the press of the button does to it.
///
/// The press stands for what Logic makes of the button. A Logic that stops answers a press by
/// reading neither playing nor recording afterwards, and a Logic that keeps moving is what a
/// person sees when the press reached nothing.
private func transportStop(
  _ logic: ALogic,
  buttons: Buttons,
  time: StopTime,
  press: @escaping (FakeLogicDriver) -> Void
) -> (status: Int32, answer: Printed) {
  let answer = Printed()
  let actions = TrackActions(pressInWindow: { locator in
    buttons.pressed.append(locator)
    press(logic.driver)
  })
  let status = TransportCommand.Stop.answer(
    driver: logic.driver,
    actions: actions,
    root: logic.root,
    version: "0.1.0",
    limitMs: theLimit,
    clock: time.read,
    sleeper: time.sleep,
    git: logic.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: answer.write,
    standardError: answer.writeError)
  return (status, answer)
}

/// A person or an agent stops the transport of Logic, and reads whether it is still moving.
///
/// The transport is stopped the way a person stops it, by the Stop button of the Control Bar. It
/// was stopped by a Machine Control message on the bus before this, and that asked for two things
/// this Mac cannot promise: a port of the IAC driver named logicctl, and a Logic whose settings
/// take Machine Control input. A Mac missing either one answered `midi_unavailable` or `timeout`
/// for a transport a person stops with one click. The press reaches the same button that person
/// clicks, so the command needs neither.
///
/// The answer is what Logic reads back and never what logicctl asked for. A command that reported
/// a stop because it pressed a button would say the transport is stopped on every Mac where it
/// keeps moving, and an agent that read that answer would go on to edit a project whose playhead
/// is running. So the transport is read again after the press, both values of it: a transport that
/// stopped playing and keeps recording is still moving, and the command says so with `timeout` and
/// the time Logic was given.
///
/// A transport that already reads neither playing nor recording is what the command asks for, so
/// nothing is pressed. In Logic the Stop button moves the playhead when the transport is stopped,
/// and a stop that is not needed moves nothing.
///
/// One stop is one step of the session, so a person reads what logicctl did and a replay does it
/// again.
@Test func stopPressesTheStopButtonOfTheControlBar() throws {
  let stopping = try aLogic(showing: aPlayingProject())
  let recording = try aLogic(showing: aRecordingProject())
  let halfWay = try aLogic(showing: aRecordingProject())
  let ignoring = try aLogic(showing: aPlayingProject())
  let already = try aLogic(showing: aStoppedProject())
  defer {
    for folder in [stopping.root, recording.root, halfWay.root, ignoring.root, already.root] {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  let typed = try Logicctl.parseAsRoot(["transport", "stop"])
  #expect(typed is TransportCommand.Stop, "the noun and the verb of the design system")
  #expect(
    stopping.driver.state?.transport.playing == true, "Logic is playing before the command runs")

  // Logic takes the press and the transport stops, which is the Logic of a person who clicks Stop.
  let buttons = Buttons()
  let stopped = transportStop(stopping, buttons: buttons, time: StopTime()) { driver in
    driver.state?.transport.playing = false
    driver.state?.transport.recording = false
  }

  #expect(stopped.status == 0, "Logic stopped")
  #expect(buttons.pressed.count == 1, "a stop is one press")
  #expect(
    buttons.theOneName == Locators.transportStopButton.name,
    "the command presses the Stop button of the Control Bar and nothing else")
  #expect(buttons.theOneName == "transport.stopButton", "which is the control a person clicks")

  let printed = try stopped.answer.json()
  #expect(printed["error"] is NSNull, "nothing failed")
  #expect(
    try stopped.answer.failureCode() == nil,
    "no bus is opened here, so no Mac is missing a port and nothing answers midi_unavailable")
  #expect(try stopped.answer.data()?["playing"] as? Bool == false, "the transport Logic reads back")
  #expect(try stopped.answer.data()?["recording"] as? Bool == false, "and what it is recording")
  #expect(try stopped.answer.data()?.keys.sorted() == ["playing", "recording"], "and nothing else")
  #expect(stopped.answer.err.isEmpty, "standard error is empty on success")
  #expect(stopped.answer.out.hasSuffix("}\n"))
  #expect(stopped.answer.out.filter(\.isNewline).count == 1, "one JSON object and one newline")

  let meta = try stopped.answer.meta()
  #expect(meta["session"] as? String == stopping.session.session.id)
  let commit = try #require(meta["step"] as? String, "the stop is in the record")
  #expect(!commit.isEmpty)
  #expect(
    try subjects(of: stopping.session.folder, with: stopping.git) == [
      "1 transport stop", "session \(stopping.session.session.shortId)",
    ],
    "the stop is one step of the session")
  let step = try record(ofStep: 1, in: stopping.session.folder)
  #expect(step["command"] as? String == "transport stop")
  #expect(step["argv"] as? [String] == [], "stop takes no flag of its own")
  #expect(step["exitCode"] as? Int == 0)

  // A transport that is recording is stopped by the same one press.
  let onARecording = Buttons()
  let ended = transportStop(recording, buttons: onARecording, time: StopTime()) { driver in
    driver.state?.transport.playing = false
    driver.state?.transport.recording = false
  }

  #expect(ended.status == 0, "the recording stopped")
  #expect(onARecording.pressed.count == 1, "a stop of a recording is one press too")
  #expect(try ended.answer.data()?["recording"] as? Bool == false, "and Logic records nothing now")

  // Logic stops playing and it keeps recording, so the transport is still moving. The command
  // reads both values, so it gives up at its limit rather than reporting a stop.
  let onAHalfStop = Buttons()
  let halfTime = StopTime()
  let halfStopped = transportStop(halfWay, buttons: onAHalfStop, time: halfTime) { driver in
    driver.state?.transport.playing = false
  }

  #expect(halfStopped.status == 6, "a transport that records is not a transport that stopped")
  #expect(try halfStopped.answer.failureCode() == "timeout")
  #expect(try halfStopped.answer.failureDetails()["waitedMs"] as? Int == theLimit)
  #expect(
    try halfStopped.answer.json()["data"] is NSNull, "no stop is reported that did not happen")
  #expect(halfWay.driver.state?.transport.recording == true, "Logic is recording still")

  // The press reaches nothing and the transport keeps playing, which is a Logic whose Control Bar
  // the walk never found. The command gives up at its limit.
  let onADeafLogic = Buttons()
  let gaveUp = transportStop(ignoring, buttons: onADeafLogic, time: StopTime()) { _ in }

  #expect(gaveUp.status == 6, "the number the design system gives timeout")
  #expect(try gaveUp.answer.failureCode() == "timeout", "Logic did not stop")
  #expect(
    try gaveUp.answer.failureDetails()["waitedMs"] as? Int == theLimit,
    "how long Logic was given")
  #expect(try gaveUp.answer.json()["data"] is NSNull, "no answer is made up for a Logic that plays")
  #expect(onADeafLogic.pressed.count == 1, "the button was pressed, and Logic did nothing with it")
  #expect(ignoring.driver.state?.transport.playing == true, "the transport is as it was")
  #expect(
    try record(ofStep: 1, in: ignoring.session.folder)["exitCode"] as? Int == 6,
    "the step records what the command answered")

  // The transport already reads neither playing nor recording, which is what the command asks for.
  // The Stop button moves the playhead of a stopped transport, so nothing is pressed.
  let onAStoppedTransport = Buttons()
  let noWait = StopTime()
  let stoppedAlready = transportStop(already, buttons: onAStoppedTransport, time: noWait) { _ in }

  #expect(stoppedAlready.status == 0, "a transport that is stopped is what the command asked for")
  #expect(
    onAStoppedTransport.pressed.isEmpty,
    "a stop that is not needed presses nothing, so the playhead stays where it is")
  #expect(try stoppedAlready.answer.data()?["playing"] as? Bool == false, "and the answer says so")
  #expect(try stoppedAlready.answer.data()?["recording"] as? Bool == false)
  #expect(noWait.now == 0, "the stopped transport is read before the command sleeps")
  #expect(
    try record(ofStep: 1, in: already.session.folder)["command"] as? String == "transport stop",
    "a stop of a stopped transport is a step like any other")
}
