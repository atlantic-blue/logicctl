import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlTesting
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-run-\(UUID().uuidString)")
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

/// The project as logicctl last recorded it: one track, nothing muted, 120 beats a minute.
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

/// The command a test drives the run with. No subcommand of logicctl talks to Logic yet, so a
/// test declares the smallest command there is: it sets the tempo of the project Logic holds.
private struct SetTheTempo: LogicCommand {
  let name = "transport tempo"
  let argv: [String]
  let tempo: Double

  init(_ tempo: Double) {
    self.tempo = tempo
    self.argv = [String(Int(tempo))]
  }

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    guard let fake = driver as? FakeLogicDriver, var state = fake.state else {
      throw DriverRefusal.logicNotRunning
    }
    state.transport.tempo = tempo
    fake.state = state
    return .object(["tempo": .number(tempo)])
  }
}

/// A command that Logic refuses, for the half of the record that holds what did not work.
private struct ACommandLogicRefuses: LogicCommand {
  let name = "transport play"
  let argv: [String] = []

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    throw DriverRefusal.logicNotRunning
  }
}

/// What one run wrote, on each channel.
private final class Answer {
  var out = ""
  var err = ""

  func write(_ text: String) {
    out += text
  }

  func writeError(_ text: String) {
    err += text
  }

  /// What `meta` of the printed answer holds.
  func meta() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
    return parsed?["meta"] as? [String: Any] ?? [:]
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

/// What the state of a session holds now.
private func storedState(in folder: URL) throws -> String {
  let data = try Data(contentsOf: folder.appendingPathComponent("state.json"))
  return String(decoding: data, as: UTF8.self)
}

/// A person mutes a track in Logic with the mouse, and then asks logicctl for a new tempo. The
/// record must not read as though logicctl muted that track.
///
/// So the change of the person is written first, as a step of its own that names no command, and
/// the command that follows writes its own step after it. A person who reads the session tomorrow
/// sees who did what, and a replay of the session runs the commands of logicctl and reports the
/// change of the person as skipped.
@Test func aHandMadeChangeIsRecordedBeforeTheCommand() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let recorded = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: recorded, git: git)

  var byHand = recorded
  byHand.tracks[0].mute = true
  let driver = FakeLogicDriver(state: byHand, path: projectPath)

  let answer = Run(driver: driver, root: root, version: "0.1.0", git: git)
    .run(command: SetTheTempo(96))

  #expect(answer.error == nil, "the command worked")
  #expect(
    answer.meta.session == session.session.id, "the answer names the session it was written into")
  let change = try #require(answer.meta.externalChange, "the change of the person was recorded")
  let wrote = try #require(answer.meta.step, "the command recorded itself")
  #expect(change != wrote, "two changes are two steps, and not one")

  #expect(
    try subjects(of: session.folder, with: git) == [
      "2 transport tempo", "1 external_change", "session \(session.session.shortId)",
    ],
    "the change of the person is recorded before the command that came after it")

  let byThePerson = try record(ofStep: 1, in: session.folder)
  #expect(byThePerson["kind"] as? String == "external_change")
  #expect(byThePerson["command"] is NSNull, "no command of logicctl made this change")
  let differences = byThePerson["differences"] as? [[String: Any]] ?? []
  #expect(differences.count == 1, "one track was muted, so one field differs")
  #expect(differences.first?["path"] as? String == "/tracks/0/mute")
  #expect(differences.first?["after"] as? Bool == true)
  #expect(byThePerson["stateBefore"] as? String == CanonicalJSON.sha256(of: recorded))
  #expect(byThePerson["stateAfter"] as? String == CanonicalJSON.sha256(of: byHand))

  var afterwards = byHand
  afterwards.transport.tempo = 96
  let byLogicctl = try record(ofStep: 2, in: session.folder)
  #expect(byLogicctl["kind"] as? String == "command")
  #expect(byLogicctl["command"] as? String == "transport tempo")
  #expect(byLogicctl["argv"] as? [String] == ["96"])
  #expect(byLogicctl["exitCode"] as? Int == 0)
  #expect(
    byLogicctl["stateBefore"] as? String == CanonicalJSON.sha256(of: byHand),
    "the command started from the project as the person left it")
  #expect(byLogicctl["stateAfter"] as? String == CanonicalJSON.sha256(of: afterwards))
  #expect(
    (byLogicctl["differences"] as? [[String: Any]])?.isEmpty == true,
    "what a command changed is read from the two hashes, not repeated here")

  let head = try git.run(["rev-parse", "HEAD"], in: session.folder)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  #expect(wrote == head, "the answer names the commit that holds the step")
  #expect(
    try storedState(in: session.folder) == CanonicalJSON.text(of: afterwards, indent: 2) + "\n",
    "the session holds the project as Logic has it now")
}

/// A command that is refused before logicctl reads Logic touched no project, so it leaves no step
/// behind. A caller reads that from the answer: no session and no step.
@Test func aRefusalBeforeLogicRecordsNothing() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: aProjectWithOneTrack(), git: git)

  let answer = Answer()
  let exitCode = Logicctl.run(
    arguments: ["--nope"], standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 2, "a wrong flag is invalid_argument")
  let meta = try answer.meta()
  #expect(meta["session"] is NSNull, "no project was read, so no session answered")
  #expect(meta["step"] is NSNull, "nothing was recorded")
  #expect(
    try subjects(of: session.folder, with: git) == ["session \(session.session.shortId)"],
    "the session of the open project gained nothing")
}

/// Logic refuses a command while it acts. The command failed, and logicctl still touched the
/// project, so the record holds the attempt with the number the command exited with. A session
/// that held only what worked would say a project was never touched when it was.
@Test func aCommandThatFailsIsRecordedToo() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let recorded = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: recorded, git: git)
  let driver = FakeLogicDriver(state: recorded, path: projectPath)

  let answer = Run(driver: driver, root: root, version: "0.1.0", git: git)
    .run(command: ACommandLogicRefuses())

  #expect(answer.error?.code == .logicNotRunning)
  #expect(answer.exitCode == 4)
  #expect(answer.meta.session == session.session.id)
  #expect(answer.meta.externalChange == nil, "nobody changed the project by hand")
  _ = try #require(answer.meta.step, "the attempt is in the record")

  #expect(
    try subjects(of: session.folder, with: git) == [
      "1 transport play", "session \(session.session.shortId)",
    ])
  let attempt = try record(ofStep: 1, in: session.folder)
  #expect(attempt["kind"] as? String == "command")
  #expect(attempt["exitCode"] as? Int == 4)
  let envelope = attempt["envelope"] as? [String: Any] ?? [:]
  let failure = envelope["error"] as? [String: Any] ?? [:]
  #expect(failure["code"] as? String == "logic_not_running")
  let meta = envelope["meta"] as? [String: Any] ?? [:]
  #expect(meta["step"] is NSNull, "the commit of a step is not known until the step is written")
}
