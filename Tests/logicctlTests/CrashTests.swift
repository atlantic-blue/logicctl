import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlTesting
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-crash-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A git whose configuration signs every commit, with a signing program that always fails.
///
/// Every test here writes a real repository, and a session repository turns signing off for
/// itself. So no test reads or writes the configuration of the operator.
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

/// Where the project of these tests sits.
private let projectPath = "/Users/someone/Music/Sketch.logicx"

/// The project as the person last saved it: one track, 120 beats a minute.
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

/// A moment the steps a test writes carry. One time for all of them keeps the record readable.
private let aMoment = Date(timeIntervalSince1970: 1_758_700_000)

/// The step the `save` command writes. That command arrives in part 3, so a test that needs a
/// saved project writes the step itself.
private func aSaveStep(seq: Int, kind: Step.Kind) -> Step {
  Step(
    seq: seq,
    kind: kind,
    command: "save",
    argv: [],
    startedAt: aMoment,
    finishedAt: aMoment,
    exitCode: 0)
}

/// A step of a command that changed the project and saved nothing.
private func aTempoStep(seq: Int) -> Step {
  Step(
    seq: seq,
    kind: .command,
    command: "transport tempo",
    argv: ["96"],
    startedAt: aMoment,
    finishedAt: aMoment,
    exitCode: 0)
}

/// A command that Logic dies in the middle of.
///
/// Logic ends, so the read that the command makes next finds nothing. That is what the crash of
/// 2026-09-24 looked like from outside: an Accessibility read, and then no process.
private struct AddATrackAndDie: LogicCommand {
  let name = "tracks add"
  let argv = ["--type", "software-instrument"]

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    guard let fake = driver as? FakeLogicDriver else {
      throw DriverRefusal.logicNotRunning
    }
    fake.state = nil
    fake.runningProcessID = nil
    throw DriverRefusal.logicNotRunning
  }
}

/// A command that Logic dies in the middle of, and a person starts Logic again before it ends.
///
/// The Logic that answers now carries another process id and an empty project. It is not the
/// Logic the command acted on, and its project is not the project the command acted on.
private struct AddATrackAndComeBack: LogicCommand {
  let name = "tracks add"
  let argv = ["--type", "software-instrument"]

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    guard let fake = driver as? FakeLogicDriver else {
      throw DriverRefusal.logicNotRunning
    }
    fake.state = State(
      logic: LogicVersion(version: "12.3.1"),
      project: Project(name: "Untitled"),
      transport: Transport(tempo: 120),
      tracks: [])
    fake.runningProcessID = 5150
    return .object(["index": .number(2)])
  }
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

/// What the state of a session holds now.
private func storedState(in folder: URL) throws -> String {
  let data = try Data(contentsOf: folder.appendingPathComponent("state.json"))
  return String(decoding: data, as: UTF8.self)
}

/// Logic dies while logicctl is adding a track, and everything the person did since they last
/// saved dies with it.
///
/// Two things must reach that person at once. The command did not finish, so nothing it reports
/// can be trusted. And the project on disk is still the project of the last save, so they know
/// exactly how much work to do again: the tempo change of step 2, and nothing before it. A tool
/// that answered "track added" here, or that answered only "Logic is not running", would leave
/// them to find that out by opening the project.
@Test func aCrashDuringACommandIsRecorded() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let saved = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: saved, git: git)
  let theSave = try session.write(aSaveStep(seq: 1, kind: .save), state: saved)

  var sinceTheSave = saved
  sinceTheSave.transport.tempo = 96
  let theTempo = try session.write(aTempoStep(seq: 2), state: sinceTheSave)
  #expect(theSave != theTempo, "the save and the change after it are two steps")

  let driver = FakeLogicDriver(state: sinceTheSave, path: projectPath)
  let answer = Run(driver: driver, root: root, version: "0.1.0", git: git)
    .run(command: AddATrackAndDie())

  #expect(answer.error?.code == .logicCrashed, "Logic ended, so the command did not finish")
  #expect(answer.exitCode == 21)
  #expect(answer.data == nil, "a command Logic died in answers nothing")
  #expect(
    answer.error?.details == .object(["lostSince": .string(theSave)]),
    "the project on disk is the project of the last save, and the tempo change is gone")

  _ = try #require(answer.meta.step, "the crash is kept, because logicctl touched the project")
  let crash = try record(ofStep: 3, in: session.folder)
  #expect(crash["kind"] as? String == "command")
  #expect(crash["command"] as? String == "tracks add")
  #expect(crash["exitCode"] as? Int == 21)
  #expect(
    crash["stateBefore"] as? String == CanonicalJSON.sha256(of: sinceTheSave),
    "the command started from the project as the tempo change left it")
  #expect(crash["stateAfter"] is NSNull, "no Logic was left to read")
  #expect(
    try storedState(in: session.folder) == CanonicalJSON.text(of: sinceTheSave, indent: 2) + "\n",
    "the session still holds the last state it could read")
}

/// A person starts Logic again while the command is still running. The Logic that answers is
/// another process with another project, so nothing it says is about the command that ran.
///
/// The project of that new Logic must not reach the record. A session that kept it would say the
/// command ended on an empty project, and the next command would read the difference as a change
/// the person made by hand.
@Test func aCrashThatLogicCameBackFromIsRecordedToo() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let saved = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: saved, git: git)
  let theSave = try session.write(aSaveStep(seq: 1, kind: .command), state: saved)

  let driver = FakeLogicDriver(state: saved, path: projectPath)
  let answer = Run(driver: driver, root: root, version: "0.1.0", git: git)
    .run(command: AddATrackAndComeBack())

  #expect(answer.error?.code == .logicCrashed, "another process id is another Logic")
  #expect(answer.exitCode == 21)
  #expect(
    answer.error?.details == .object(["lostSince": .string(theSave)]),
    "a step of the `save` command saved the project, whatever kind it was written as")

  let crash = try record(ofStep: 2, in: session.folder)
  #expect(crash["exitCode"] as? Int == 21)
  #expect(
    crash["stateAfter"] is NSNull,
    "the project of the new Logic is not the project this command acted on")
  #expect(
    try storedState(in: session.folder) == CanonicalJSON.text(of: saved, indent: 2) + "\n",
    "the session holds the project that was there, not the empty one that came back")
}

/// Logic dies in a project nobody ever saved. There is no point to go back to, so the failure
/// says that with null rather than naming a step that saved nothing.
@Test func aCrashInASessionThatNeverSavedNamesNoStep() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let recorded = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: recorded, git: git)
  try session.write(aTempoStep(seq: 1), state: recorded)

  let driver = FakeLogicDriver(state: recorded, path: projectPath)
  let answer = Run(driver: driver, root: root, version: "0.1.0", git: git)
    .run(command: AddATrackAndDie())

  #expect(answer.error?.code == .logicCrashed)
  #expect(
    answer.error?.details == .object(["lostSince": .null]),
    "nothing was ever saved, so there is nothing to go back to")
}
