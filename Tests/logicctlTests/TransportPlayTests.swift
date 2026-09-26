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

/// Where the project of this scenario sits.
private let projectPath = "/Users/someone/Music/Sketch.logicx"

/// How long Logic is given to start playing, in milliseconds.
private let theLimit = 200

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

/// The project Logic has open: one software instrument track, and a transport in this state.
private func aProject(playing: Bool) -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(playing: playing, recording: false, tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
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

private func aLogic(playing: Bool = false) throws -> ALogic {
  let root = try aFolderOfItsOwn()
  let git = try gitThatSigns(inside: root)
  let project = aProject(playing: playing)
  return ALogic(
    root: root,
    git: git,
    session: try SessionRepository.start(
      session: aSession(), root: root, state: project, git: git),
    driver: FakeLogicDriver(state: project, path: projectPath))
}

/// Every press that reached the window of Logic, in the order it reached it.
private final class Buttons {
  var pressed: [Locator] = []

  /// The name of the control the last press went to.
  var lastLocatorName: String? {
    pressed.last?.name
  }
}

/// What presses the Control Bar of this Logic, and what that Logic does about it.
///
/// The Play button of Logic 12.3.1 is a check box whose one action is `AXPress`. Measured on this
/// Mac on 2026-09-26 against a project with a plugin window in front: one press moved the button
/// from 0 to 1, and a second press left it at 1. A Logic that does not start stands for a press
/// that reached the button and started nothing, which is what a refused press answers too.
private func aControlBar(of logic: ALogic, buttons: Buttons, starts: Bool) -> TrackActions {
  TrackActions(pressInWindow: { locator in
    buttons.pressed.append(locator)
    if starts {
      logic.driver.state?.transport.playing = true
    }
  })
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

/// A person or an agent starts playback, and Logic plays, on every Mac.
///
/// Playback is what a person starts by pressing Play in the Control Bar, so that is what logicctl
/// presses. It needs no port and no setting of Logic. A command that sent Machine Control instead
/// asked for two things this Mac may not have: a port named logicctl, which a Mac with the IAC
/// driver off carries none of, and a Logic whose own settings take Machine Control input. Neither
/// is needed to press a button, so play now works where it used to fail.
///
/// The answer is what Logic reads back and never what logicctl pressed, because a press Logic
/// refused answers the same as one it took. So a Logic that does not start playing is `timeout`
/// with the time it was given, which is a person's cue to look at Logic, and never a report of
/// playback that did not happen.
///
/// The Play button is a check box, and Logic leaves it on when it is pressed again. A person who
/// runs the command twice still gets a Logic that plays. So a press goes out only where Logic is
/// stopped, and a Logic that already plays is read and answered.
///
/// One play is one step of the session, so a person reads what logicctl did and a replay does it
/// again.
@Test func playPressesThePlayButtonOfTheControlBar() throws {
  let stopped = try aLogic()
  let already = try aLogic(playing: true)
  let ignoring = try aLogic()
  defer {
    for folder in [stopped.root, already.root, ignoring.root] {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  let typed = try Logicctl.parseAsRoot(["transport", "play"])
  #expect(typed is TransportCommand.Play, "the noun and the verb of the design system")
  #expect(
    stopped.driver.state?.transport.playing == false, "Logic is stopped before the command runs")

  let buttons = Buttons()
  let answer = Printed()
  let time = PlayTime()

  let status = TransportCommand.Play.answer(
    driver: stopped.driver,
    actions: aControlBar(of: stopped, buttons: buttons, starts: true),
    root: stopped.root,
    version: "0.1.0",
    limitMs: theLimit,
    clock: time.read,
    sleeper: time.sleep,
    git: stopped.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 0, "Logic is playing")
  #expect(buttons.pressed.count == 1, "playback is one press")
  #expect(
    buttons.lastLocatorName == Locators.transportPlayButton.name,
    "and the press goes to the Play button of the Control Bar")

  let printed = try answer.json()
  #expect(printed["error"] is NSNull, "nothing failed")
  #expect(try answer.data()?["playing"] as? Bool == true, "the transport Logic reads back")
  #expect(try answer.data()?["recording"] as? Bool == false, "play records nothing")
  #expect(try answer.data()?.keys.sorted() == ["playing", "recording"], "and nothing else")
  #expect(answer.err.isEmpty, "standard error is empty on success")
  #expect(answer.out.hasSuffix("}\n"))
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and one newline")

  let meta = try answer.meta()
  #expect(meta["session"] as? String == stopped.session.session.id)
  let commit = try #require(meta["step"] as? String, "the play is in the record")
  #expect(!commit.isEmpty)
  #expect(
    try subjects(of: stopped.session.folder, with: stopped.git) == [
      "1 transport play", "session \(stopped.session.session.shortId)",
    ],
    "the play is one step of the session")
  let step = try record(ofStep: 1, in: stopped.session.folder)
  #expect(step["command"] as? String == "transport play")
  #expect(step["argv"] as? [String] == [], "play takes no flag of its own")
  #expect(step["exitCode"] as? Int == 0)

  // Logic is playing already. The button is on, and a press would be a press of a check box that
  // is already on, so the command reads the transport and presses nothing.
  let untouched = Buttons()
  let second = Printed()
  let noWait = PlayTime()

  let again = TransportCommand.Play.answer(
    driver: already.driver,
    actions: aControlBar(of: already, buttons: untouched, starts: false),
    root: already.root,
    version: "0.1.0",
    limitMs: theLimit,
    clock: noWait.read,
    sleeper: noWait.sleep,
    git: already.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: second.write,
    standardError: second.writeError)

  #expect(again == 0, "Logic plays, which is what was asked for")
  #expect(untouched.pressed.isEmpty, "a Logic that plays is left alone")
  #expect(try second.data()?["playing"] as? Bool == true, "the transport Logic reads back")
  #expect(second.err.isEmpty, "standard error is empty on success")

  // The press reached the button and Logic started nothing, which is what a refused press answers
  // too. The command gives up at its limit rather than reporting playback.
  let refused = Buttons()
  let gaveUp = Printed()
  let waited = PlayTime()

  let stillStopped = TransportCommand.Play.answer(
    driver: ignoring.driver,
    actions: aControlBar(of: ignoring, buttons: refused, starts: false),
    root: ignoring.root,
    version: "0.1.0",
    limitMs: theLimit,
    clock: waited.read,
    sleeper: waited.sleep,
    git: ignoring.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: gaveUp.write,
    standardError: gaveUp.writeError)

  #expect(stillStopped == 6, "the number the design system gives timeout")
  #expect(try gaveUp.failureCode() == "timeout", "Logic did not start playing")
  #expect(try gaveUp.failureDetails()["waitedMs"] as? Int == theLimit, "how long Logic was given")
  let stoppedJson = try gaveUp.json()
  #expect(stoppedJson["data"] is NSNull, "no answer is made up for a Logic that is stopped")
  #expect(refused.pressed.count == 1, "the press went out, and Logic did nothing with it")
  #expect(ignoring.driver.state?.transport.playing == false, "the transport is as it was")
  #expect(
    try record(ofStep: 1, in: ignoring.session.folder)["exitCode"] as? Int == 6,
    "the step records what the command answered")
}
