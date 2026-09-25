import Foundation
import LogicctlCore
import LogicctlJournal
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-relink-\(UUID().uuidString)")
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

/// When the session of these tests started.
private let aMoment = Date(timeIntervalSince1970: 1_700_000_000)

/// Where the project of these tests sat before the person moved it.
private let theOldPath = "/Users/someone/Music/Sketch.logicx"

/// Where the person moved it to.
private let theNewPath = "/Users/someone/Archive/2026/Sketch.logicx"

/// The project of these tests, as Logic showed it: one track, nothing muted.
private func aProjectWithOneTrack() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// A session of one project, as a command starts one.
private func aSession(at path: String?) -> Session {
  Session(
    createdAt: aMoment,
    project: Session.Project(name: "Sketch", path: path, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// Writes some steps into a session, numbered from 1.
private func writeSteps(
  _ count: Int, into repository: SessionRepository, leaving state: State
) throws {
  for sequence in 1..<(count + 1) {
    let started = aMoment.addingTimeInterval(Double(sequence) * 60)
    let step = Step(
      seq: sequence,
      kind: .command,
      command: "tracks add",
      argv: ["--type", "software-instrument"],
      startedAt: started,
      finishedAt: started.addingTimeInterval(1),
      exitCode: 0,
      stateBefore: CanonicalJSON.sha256(of: state),
      stateAfter: CanonicalJSON.sha256(of: state))
    try repository.write(step, state: state)
  }
}

/// How many commits one session holds.
private func commits(of repository: SessionRepository, git: Git) throws -> Int {
  try git.run(["log", "--format=%H"], in: repository.folder)
    .split(separator: "\n")
    .count
}

/// What one run of `sessions` wrote, on each channel.
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

  /// What the command answered under `data`.
  func data() throws -> [String: Any] {
    try envelope()["data"] as? [String: Any] ?? [:]
  }

  /// What the command answered under `error`.
  func failure() throws -> [String: Any] {
    try envelope()["error"] as? [String: Any] ?? [:]
  }
}

/// A person moved the project file into another folder, and the work has to follow it.
///
/// logicctl knows a project by where it sits, because a `.logicx` carries no id of its own. So the
/// first command after the move finds no session for the new path, starts a second session, and
/// the work of one project splits into two histories that neither `log` nor `replay` can put back
/// together. Relink points the session that already holds the work at the new path, so the next
/// command goes on writing into it.
///
/// The change is a commit of its own, so the move is part of the history and a person reading the
/// session later sees when the project moved and where it went.
@Test func relinkMovesTheSessionToTheNewPath() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()

  let repository = try SessionRepository.start(
    session: aSession(at: theOldPath), root: root, state: project, git: git)
  try writeSteps(3, into: repository, leaving: project)
  let held = try commits(of: repository, git: git)

  let answer = Answer()
  let exitCode = Sessions.answer(
    relink: [repository.session.id, theNewPath],
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0, "the session is there and the path is new, so nothing refuses this")
  #expect(answer.err == "", "nothing went wrong, so a person reading along is told nothing")

  #expect(
    SessionIndex.session(atProjectPath: theNewPath, root: root)?.id == repository.session.id,
    "a command on the moved project goes on writing into the session that holds the work")
  #expect(
    SessionIndex.session(atProjectPath: theOldPath, root: root) == nil,
    "and nothing is left behind at the path the project moved from")
  #expect(
    try commits(of: repository, git: git) == held + 1,
    "the move is one commit of its own, so the history says when the project moved")
}

/// The answer names the session, where the project sat, where it sits now, and the commit that
/// carries the change. A caller that relinked a session reads the commit and goes straight to it.
@Test func relinkAnswersWhatItChanged() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let repository = try SessionRepository.start(
    session: aSession(at: theOldPath), root: root, state: aProjectWithOneTrack(), git: git)

  let answer = Answer()
  let exitCode = Sessions.answer(
    relink: [repository.session.id, theNewPath],
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0)
  let data = try answer.data()
  #expect(data["session"] as? String == repository.session.id)
  #expect(data["pathBefore"] as? String == theOldPath, "where the project sat")
  #expect(data["pathAfter"] as? String == theNewPath, "and where it sits now")
  let head = try git.run(["rev-parse", "HEAD"], in: repository.folder)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  #expect(
    data["commit"] as? String == head,
    "the commit of the change, so a person reads it without searching the history")
}

/// A relink is not a step. The count of steps says how much work a session holds, and a project
/// that moved is nothing that was done to Logic, so the count must not move with the project.
@Test func relinkAddsNoStepToTheCount() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()

  let repository = try SessionRepository.start(
    session: aSession(at: theOldPath), root: root, state: project, git: git)
  try writeSteps(3, into: repository, leaving: project)

  let answer = Answer()
  _ = Sessions.answer(
    relink: [repository.session.id, theNewPath],
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  let rows = try SessionList.rows(underRoot: root, git: git)
  try #require(rows.count == 1)
  #expect(rows[0].steps == 3, "the work is the same work, and the listing says so")
  #expect(rows[0].path == theNewPath, "and the listing says where the project sits now")
}

/// A person typed an id that no session carries. Nothing is written, and the answer names the id
/// that was typed, because the usual cause is a short id or one character wrong.
@Test func relinkOfASessionThatIsNotThereIsRefused() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try SessionRepository.start(
    session: aSession(at: theOldPath), root: root, state: aProjectWithOneTrack(), git: git)
  let held = try commits(of: repository, git: git)

  let answer = Answer()
  let exitCode = Sessions.answer(
    relink: ["6b441a12", theNewPath],
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 2, "a name that is not there is invalid_argument, code 2")
  #expect(try answer.failure()["code"] as? String == "invalid_argument")
  #expect(try commits(of: repository, git: git) == held, "and nothing was written")
  #expect(
    SessionIndex.session(atProjectPath: theOldPath, root: root)?.id == repository.session.id,
    "the session that is there still carries the path it had")
}

/// The path is the path the session already carries, so there is nothing to change. The person
/// reads a sentence. Writing it would mean a commit that carries no change, which git refuses.
@Test func relinkToThePathItAlreadyCarriesIsRefused() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try SessionRepository.start(
    session: aSession(at: theOldPath), root: root, state: aProjectWithOneTrack(), git: git)
  let held = try commits(of: repository, git: git)

  let answer = Answer()
  let exitCode = Sessions.answer(
    relink: [repository.session.id, theOldPath],
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 2, "nothing to do is invalid_argument, code 2")
  #expect(try answer.failure()["code"] as? String == "invalid_argument")
  #expect(answer.err.hasPrefix("logicctl: invalid_argument: "), "and one line for the person")
  #expect(try commits(of: repository, git: git) == held, "the history is untouched")
}

/// A session of a project nobody saved yet carries no path. A relink gives it one, and the field
/// that was null before says so.
@Test func relinkGivesAPathToASessionThatHadNone() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try SessionRepository.start(
    session: aSession(at: nil), root: root, state: aProjectWithOneTrack(), git: git)

  let answer = Answer()
  let exitCode = Sessions.answer(
    relink: [repository.session.id, theNewPath],
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0)
  #expect(try answer.data()["pathBefore"] is NSNull, "a missing value is null and never absent")
  #expect(SessionIndex.session(atProjectPath: theNewPath, root: root)?.id == repository.session.id)
}

/// The repository of the session cannot be written, so the relink fails as a write that failed
/// and not as a person who typed something wrong.
@Test func aRelinkThatCannotBeWrittenFailsAsJournalFailed() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try SessionRepository.start(
    session: aSession(at: theOldPath), root: root, state: aProjectWithOneTrack(), git: git)
  try FileManager.default.removeItem(at: repository.folder.appendingPathComponent(".git"))

  let answer = Answer()
  let exitCode = Sessions.answer(
    relink: [repository.session.id, theNewPath],
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 14, "a write that failed is journal_failed, code 14")
  #expect(try answer.failure()["code"] as? String == "journal_failed")
}

/// `sessions` reads no Logic, and a relink reads none either. It writes a commit and not a step,
/// so `meta` names no session and no step, the way the data model asks.
@Test func relinkNamesNoSessionAndNoStepInItsMeta() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try SessionRepository.start(
    session: aSession(at: theOldPath), root: root, state: aProjectWithOneTrack(), git: git)

  let answer = Answer()
  _ = Sessions.answer(
    relink: [repository.session.id, theNewPath],
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  let meta = try answer.envelope()["meta"] as? [String: Any] ?? [:]
  #expect(meta["session"] is NSNull, "this command read no project")
  #expect(meta["step"] is NSNull, "and a relink is no step")
}

/// The command line reaches the relink. A flag the command does not hold is not there at all,
/// whatever the code behind it does, and every test above would still pass.
@Test func theCommandLineReachesRelink() throws {
  let answer = Answer()
  let exitCode = Logicctl.run(
    arguments: ["sessions", "--help"], standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 0)
  #expect(answer.out.contains("--relink"), "the help names the flag a person types")
}

/// One value is a session with no path, or a path with no session. Neither can be acted on, so
/// the command refuses it before it reads the journal, and says what to type instead.
@Test func aRelinkThatIsNotASessionAndAPathIsRefused() throws {
  let answer = Answer()
  let exitCode = Logicctl.run(
    arguments: ["sessions", "--relink", theNewPath], standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 2, "the arguments were wrong, so invalid_argument, code 2")
  let parsed = try JSONSerialization.jsonObject(with: Data(answer.out.utf8)) as? [String: Any]
  let failure = parsed?["error"] as? [String: Any] ?? [:]
  #expect(failure["code"] as? String == "invalid_argument")
  #expect(
    (failure["message"] as? String ?? "").contains("--relink"),
    "and the sentence names the flag that was wrong")
}
