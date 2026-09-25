import Foundation
import LogicctlCore
import LogicctlJournal
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-sessions-\(UUID().uuidString)")
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

/// When the older session of these tests started.
private let anEarlierMoment = Date(timeIntervalSince1970: 1_600_000_000)

/// When the newer session of these tests started.
private let aLaterMoment = Date(timeIntervalSince1970: 1_700_000_000)

/// The project of these tests, as Logic showed it: one track, nothing muted.
private func aProjectWithOneTrack() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// A session of one project, as a command starts one.
private func aSession(named name: String, at path: String?, created: Date) -> Session {
  Session(
    createdAt: created,
    project: Session.Project(name: name, path: path, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// Writes some steps into a session, numbered from 1.
private func writeSteps(
  _ count: Int, into repository: SessionRepository, leaving state: State
) throws {
  for sequence in 1..<(count + 1) {
    let started = aLaterMoment.addingTimeInterval(Double(sequence) * 60)
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

  /// The rows of `data.sessions`.
  func sessions() throws -> [[String: Any]] {
    let data = try envelope()["data"] as? [String: Any] ?? [:]
    return data["sessions"] as? [[String: Any]] ?? []
  }
}

/// The count of steps of every row, by the project each row names.
///
/// A lookup by project and not by position, because what a row says about its own session must
/// hold however the listing is ordered. The order is a contract of its own, with a test of its own.
private func steps(byProject rows: [[String: Any]]) -> [String: Int] {
  var found: [String: Int] = [:]
  for row in rows {
    guard let project = row["project"] as? String, let held = row["steps"] as? Int else {
      continue
    }
    found[project] = held
  }
  return found
}

/// One text field of every row, by the project each row names.
private func text(_ key: String, byProject rows: [[String: Any]]) -> [String: String] {
  var found: [String: String] = [:]
  for row in rows {
    guard let project = row["project"] as? String, let value = row[key] as? String else {
      continue
    }
    found[project] = value
  }
  return found
}

/// A person worked on two projects and comes back to find the one that holds the work. The
/// listing says how much work each session holds, and that number is what tells a session that
/// carries the work from a session that was started and left.
///
/// The count is the steps of the session and nothing else. A session is started by the first
/// command that touches a project, and that first commit names the session and did nothing to
/// Logic, so it is no step. A count that included it would report five steps for a session that
/// holds four, and a person reading the listing would take an empty session for a session with
/// work in it.
@Test func sessionsCountsSteps() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()

  let ballad = try SessionRepository.start(
    session: aSession(
      named: "Ballad", at: "/Users/someone/Music/Ballad.logicx", created: anEarlierMoment),
    root: root, state: project, git: git)
  try writeSteps(5, into: ballad, leaving: project)

  let sketch = try SessionRepository.start(
    session: aSession(
      named: "Sketch", at: "/Users/someone/Music/Sketch.logicx", created: aLaterMoment),
    root: root, state: project, git: git)
  try writeSteps(3, into: sketch, leaving: project)

  let answer = Answer()
  let exitCode = Sessions.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0, "reading the journal is not a failure")
  #expect(answer.err == "", "nothing went wrong, so a person reading along is told nothing")

  let rows = try answer.sessions()
  try #require(rows.count == 2, "two sessions were started, so two rows come back")

  #expect(
    steps(byProject: rows) == ["Sketch": 3, "Ballad": 5],
    "each row carries the steps of its own session, and the commit that started it is no step")
  #expect(
    text("id", byProject: rows) == [
      "Sketch": sketch.session.id, "Ballad": ballad.session.id,
    ],
    "each row names the session a person then reads with log and show")
  #expect(
    text("path", byProject: rows) == [
      "Sketch": "/Users/someone/Music/Sketch.logicx",
      "Ballad": "/Users/someone/Music/Ballad.logicx",
    ],
    "each row says where its own project sits")
}

/// The newest session comes first, the way `log` prints the newest step first. A person who just
/// worked on something finds that session at the top.
///
/// The order is the order the sessions were started in, and never the order the folders happen to
/// be listed in. Here the folder of the older session sorts first by name, so a listing that read
/// the folders would answer the older session first.
@Test func sessionsListsTheNewestFirst() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()

  _ = try SessionRepository.start(
    session: aSession(
      named: "Ballad", at: "/Users/someone/Music/Ballad.logicx", created: anEarlierMoment),
    root: root, state: project, git: git)
  _ = try SessionRepository.start(
    session: aSession(
      named: "Sketch", at: "/Users/someone/Music/Sketch.logicx", created: aLaterMoment),
    root: root, state: project, git: git)

  let answer = Answer()
  _ = Sessions.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(
    try answer.sessions().map { $0["project"] as? String } == ["Sketch", "Ballad"],
    "the session that was started last is the first row")
}

/// A session that was started and never used holds no step. The count is zero, which is the
/// answer, and the row is still there: the session exists and a person may want to know that.
@Test func aSessionWithNoStepsCountsZero() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  _ = try SessionRepository.start(
    session: aSession(
      named: "Sketch", at: "/Users/someone/Music/Sketch.logicx", created: aLaterMoment),
    root: root, state: aProjectWithOneTrack(), git: git)

  let answer = Answer()
  let exitCode = Sessions.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0)
  let rows = try answer.sessions()
  try #require(rows.count == 1)
  #expect(rows[0]["steps"] as? Int == 0, "the commit that started the session is not a step")
}

/// A project that Logic has open and nobody saved yet has no path. The field is null and never a
/// path to a file that is not there.
@Test func aSessionOfAnUnsavedProjectCarriesNoPath() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  _ = try SessionRepository.start(
    session: aSession(named: "Untitled", at: nil, created: aLaterMoment),
    root: root, state: aProjectWithOneTrack(), git: git)

  let answer = Answer()
  _ = Sessions.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  let rows = try answer.sessions()
  try #require(rows.count == 1)
  #expect(rows[0]["path"] is NSNull, "a missing value is null and never absent")
  #expect(rows[0]["project"] as? String == "Untitled", "and the project is still named")
}

/// Nothing was ever recorded on this Mac. The answer is an empty list and not a failure: the
/// question has an answer, and the answer is that there are no sessions.
@Test func sessionsListsNothingWhenNoneWereStarted() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let answer = Answer()
  let exitCode = Sessions.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0, "an empty journal is not a failure")
  #expect(try answer.sessions().isEmpty)
  #expect(answer.err == "")
}

/// `sessions` reads the journal and never Logic, so it names no session and no step in `meta`, the
/// way the data model asks of every command that does not talk to Logic.
@Test func sessionsNamesNoSessionAndNoStepInItsMeta() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try SessionRepository.start(
    session: aSession(
      named: "Sketch", at: "/Users/someone/Music/Sketch.logicx", created: aLaterMoment),
    root: root, state: aProjectWithOneTrack(), git: git)
  try writeSteps(1, into: repository, leaving: aProjectWithOneTrack())

  let answer = Answer()
  _ = Sessions.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  let meta = try answer.envelope()["meta"] as? [String: Any] ?? [:]
  #expect(meta["session"] is NSNull, "this command read no project")
  #expect(meta["step"] is NSNull, "it wrote nothing, so it recorded nothing")
  #expect(try answer.sessions().count == 1, "and it still answered the session that is there")
}

/// The history of one session cannot be read, so its count of steps is not known. The command
/// fails and says so, rather than answering zero for that session, because zero is what a session
/// that was started and never used answers, and a person looking for their work would pass it by.
@Test func aSessionWhoseHistoryCannotBeReadFailsTheCommand() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = aProjectWithOneTrack()
  let repository = try SessionRepository.start(
    session: aSession(
      named: "Sketch", at: "/Users/someone/Music/Sketch.logicx", created: aLaterMoment),
    root: root, state: project, git: git)
  try writeSteps(2, into: repository, leaving: project)
  try FileManager.default.removeItem(at: repository.folder.appendingPathComponent(".git"))

  let answer = Answer()
  let exitCode = Sessions.answer(
    root: root, git: git, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 70, "a damaged journal is internal, code 70")
  let failure = try answer.envelope()["error"] as? [String: Any] ?? [:]
  #expect(failure["code"] as? String == "internal")
  #expect(try answer.envelope()["data"] is NSNull, "a failure carries no rows")
  #expect(answer.err.hasPrefix("logicctl: internal: "), "a person reading along is told one line")
}

/// The command line reaches `sessions`. A subcommand that the root command does not hold is not
/// there at all, whatever the code behind it does, and every test above would still pass.
@Test func theCommandLineReachesSessions() throws {
  let answer = Answer()
  let exitCode = Logicctl.run(
    arguments: ["sessions", "--help"], standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 0, "the help of a command is not a failure")
  #expect(answer.out.contains("logicctl sessions"), "the help names the command a person types")
  #expect(answer.out.contains("--pretty"), "and the one flag it takes")
}
