import Foundation
import LogicctlCore
import LogicctlJournal
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-log-\(UUID().uuidString)")
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

/// When the first step of these tests started. The next two follow it a minute apart, so the time
/// of a row says which step it came from.
private let firstMoment = Date(timeIntervalSince1970: 1_700_000_000)

/// The project of these tests, as Logic showed it at the start: one track, nothing muted.
private func aProjectWithOneTrack() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// A session of that project, as `new-project` started one.
private func aSession(
  named name: String = "Sketch", at path: String, created: Date = Date()
) -> Session {
  Session(
    createdAt: created,
    project: Session.Project(name: name, path: path, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// One step, written into a session, answering the commit that holds it.
@discardableResult
private func write(
  _ sequence: Int,
  kind: Step.Kind = .command,
  command: String? = nil,
  argv: [String] = [],
  exitCode: Int = 0,
  minutesIn: Int,
  into repository: SessionRepository,
  leaving state: State
) throws -> String {
  let started = firstMoment.addingTimeInterval(Double(minutesIn) * 60)
  let step = Step(
    seq: sequence,
    kind: kind,
    command: command,
    argv: argv,
    startedAt: started,
    finishedAt: started.addingTimeInterval(1),
    exitCode: exitCode,
    stateBefore: CanonicalJSON.sha256(of: state),
    stateAfter: CanonicalJSON.sha256(of: state))
  return try repository.write(step, state: state)
}

/// What one run of `log` wrote, on each channel.
private final class Answer {
  var out = ""
  var err = ""

  func write(_ text: String) {
    out += text
  }

  func writeError(_ text: String) {
    err += text
  }

  /// The whole answer, read back as JSON.
  func envelope() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
    return parsed ?? [:]
  }

  /// The rows of `data.steps`.
  func steps() throws -> [[String: Any]] {
    let data = try envelope()["data"] as? [String: Any] ?? [:]
    return data["steps"] as? [[String: Any]] ?? []
  }

  /// The session the answer says the rows came from.
  func session() throws -> Any {
    let data = try envelope()["data"] as? [String: Any] ?? [:]
    return data["session"] ?? NSNull()
  }
}

/// The commits of a repository, newest first, as git lists them.
private func commits(of repository: SessionRepository, with git: Git) throws -> [String] {
  try git.run(["log", "--format=%H"], in: repository.folder)
    .split(separator: "\n", omittingEmptySubsequences: true)
    .map(String.init)
}

/// A person asks what logicctl did to this project. The newest thing it did comes first, because
/// that is what the person is looking for, and the older steps follow it in order.
///
/// The answer is held to the history git keeps: the same steps, the same commits, the same order.
/// A reader that sorted the folders under `steps/` by name, or that dropped the change nobody
/// typed, would answer something git does not carry, and the session would stop being the record
/// of what happened to the project.
@Test func logListsNewestFirst() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()
  let repository = try SessionRepository.start(
    session: aSession(at: "/Users/someone/Music/Sketch.logicx"), root: root, state: project,
    git: git)

  var muted = project
  muted.tracks[0].mute = true
  try write(
    1, command: "tracks add", argv: ["--type", "software-instrument"], minutesIn: 0,
    into: repository, leaving: project)
  try write(2, kind: .externalChange, minutesIn: 1, into: repository, leaving: muted)
  try write(
    3, command: "tracks mute", argv: ["--index", "9", "--on"], exitCode: 10, minutesIn: 2,
    into: repository, leaving: muted)

  let answer = Answer()
  let exitCode = Log.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0, "reading a history is not a failure")
  #expect(answer.err == "", "nothing went wrong, so a person reading along is told nothing")

  let rows = try answer.steps()
  try #require(rows.count == 3, "three steps went into the session, so three rows come back")
  #expect(rows.map { $0["step"] as? Int } == [3, 2, 1], "the newest step is the first one")

  #expect(
    rows.map { $0["time"] as? String } == [
      "2023-11-14T22:15:20Z", "2023-11-14T22:14:20Z", "2023-11-14T22:13:20Z",
    ],
    "each row carries the time its own step started, RFC 3339 in UTC")
  #expect(
    rows.map { $0["command"] as? String } == ["tracks mute", nil, "tracks add"],
    "each row names the command that ran, and the change nobody typed names none")
  #expect(rows[1]["command"] is NSNull, "a missing value is null and never absent")
  #expect(
    rows.map { $0["kind"] as? String } == ["command", "external_change", "command"],
    "a row says what wrote the step, so a row with no command still reads")
  #expect(
    rows.map { $0["exitCode"] as? Int } == [10, 0, 0],
    "each row carries the number its own step exited with")

  let listed = try commits(of: repository, with: git)
  #expect(listed.count == 4, "three steps, and the commit that started the session")
  let answered = rows.compactMap { $0["commit"] as? String }
  #expect(answered.count == rows.count, "every row names the commit that holds its step")
  #expect(
    answered == Array(listed.dropLast()),
    "git log lists the same commits, in the same order, and the session commit is no step")
  #expect(
    try answer.session() as? String == repository.session.id,
    "the answer says which session the rows came from")
}

/// `log` reads the journal and never Logic, so it names no session and no step in `meta`, the way
/// the data model asks of every command that does not talk to Logic. The session the rows came
/// from is in the answer itself, where a reader can still find it.
@Test func logNamesNoSessionAndNoStepInItsMeta() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()
  let repository = try SessionRepository.start(
    session: aSession(at: "/Users/someone/Music/Sketch.logicx"), root: root, state: project,
    git: git)
  try write(1, command: "tracks add", minutesIn: 0, into: repository, leaving: project)

  let answer = Answer()
  _ = Log.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  let meta = try answer.envelope()["meta"] as? [String: Any] ?? [:]
  #expect(meta["session"] is NSNull, "this command read no project")
  #expect(meta["step"] is NSNull, "it wrote nothing, so it recorded nothing")
  #expect(try answer.steps().count == 1, "and it still answered the step the session holds")
}

/// A session that was started and not used yet holds no step. The answer is an empty list and not
/// a failure: the question has an answer, and the answer is that nothing happened.
@Test func aSessionWithNoStepsListsNothing() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try SessionRepository.start(
    session: aSession(at: "/Users/someone/Music/Sketch.logicx"), root: root,
    state: aProjectWithOneTrack(), git: git)

  let answer = Answer()
  let exitCode = Log.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0)
  #expect(try answer.steps().isEmpty, "the commit that started the session is not a step")
  #expect(try answer.session() as? String == repository.session.id)
}

/// Nothing was ever recorded on this Mac. There is no session to name and no step to list, and
/// that is still an answer.
@Test func noSessionAtAllListsNothing() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let answer = Answer()
  let exitCode = Log.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0, "an empty history is not a failure")
  #expect(try answer.steps().isEmpty)
  #expect(try answer.session() is NSNull, "there is no session to name")
}

/// Two projects have sessions, and `log` reads the one that was started last.
///
/// This command cannot ask Logic which project is open, because it never talks to Logic. So the
/// current session is the newest one, and a person who wants another reads it with `sessions`.
@Test func logReadsTheSessionThatWasStartedLast() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()

  let older = try SessionRepository.start(
    session: aSession(
      named: "Older", at: "/Users/someone/Music/Older.logicx",
      created: Date(timeIntervalSince1970: 1_600_000_000)),
    root: root, state: project, git: git)
  try write(1, command: "tracks add", minutesIn: 0, into: older, leaving: project)

  let newer = try SessionRepository.start(
    session: aSession(
      named: "Newer", at: "/Users/someone/Music/Newer.logicx",
      created: Date(timeIntervalSince1970: 1_700_000_000)),
    root: root, state: project, git: git)
  try write(1, command: "transport tempo", minutesIn: 1, into: newer, leaving: project)

  let answer = Answer()
  _ = Log.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(try answer.session() as? String == newer.session.id)
  #expect(
    try answer.steps().map { $0["command"] as? String } == ["transport tempo"],
    "the steps of the older session belong to the older session")
}

/// A commit names a step whose record cannot be read. The command fails and says so, rather than
/// answering a history with one step missing from it, which reads exactly like a history that
/// never held that step.
@Test func aStepThatCannotBeReadFailsTheCommand() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()
  let repository = try SessionRepository.start(
    session: aSession(at: "/Users/someone/Music/Sketch.logicx"), root: root, state: project,
    git: git)
  try write(1, command: "tracks add", minutesIn: 0, into: repository, leaving: project)
  try write(2, command: "tracks mute", minutesIn: 1, into: repository, leaving: project)

  let record =
    repository.folder
    .appendingPathComponent("steps")
    .appendingPathComponent(SessionRepository.stepFolderName(ofSequence: 1))
    .appendingPathComponent("step.json")
  try Data("{}".utf8).write(to: record, options: .atomic)

  let answer = Answer()
  let exitCode = Log.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 70, "a damaged history is internal, code 70")
  let failure = try answer.envelope()["error"] as? [String: Any] ?? [:]
  #expect(failure["code"] as? String == "internal")
  #expect(try answer.envelope()["data"] is NSNull, "a failure carries no rows")
  #expect(answer.err.hasPrefix("logicctl: internal: "), "a person reading along is told one line")
}

/// The command line reaches `log`. A subcommand that the root command does not hold is not there
/// at all, whatever the code behind it does, and every test above would still pass.
@Test func theCommandLineReachesLog() throws {
  let answer = Answer()
  let exitCode = Logicctl.run(
    arguments: ["log", "--help"], standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0, "the help of a command is not a failure")
  #expect(answer.out.contains("logicctl log"), "the help names the command a person types")
  #expect(answer.out.contains("--pretty"), "and the one flag it takes")
}
