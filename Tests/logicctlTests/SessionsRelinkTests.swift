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
