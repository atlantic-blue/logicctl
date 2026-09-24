import Foundation
import LogicctlCore
import LogicctlJournal
import Testing

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-index-\(UUID().uuidString)")
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

/// A session of a project, as a command starts one.
private func aSession(named name: String, at moment: Date = Date()) -> Session {
  Session(
    createdAt: moment,
    project: Session.Project(name: name, createdByLogicctl: false),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// The state of that project, as Logic read it before the first command.
private func aProject(named name: String) -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: name),
    transport: Transport(tempo: 120),
    tracks: [])
}

/// The names of the session folders under one root.
private func sessionFolders(underRoot root: URL) throws -> [String] {
  let folder = SessionRepository.sessionsFolder(underRoot: root)
  return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

/// The lines of some output, without the empty one at the end.
private func lines(of output: String) -> [String] {
  output.split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)
    .filter { !$0.isEmpty }
}

/// A person opens a project today, works on it, closes Logic, and opens the same project
/// tomorrow. They read one history of that project, not two, and no command they ran is missing
/// from it. Logic keeps no id in a `.logicx`, so the only thing the two days share is the path of
/// the project: the first command on a project nobody recorded starts a session, and every
/// command after it goes on writing into that same session. The person also types the name of the
/// project, and a folder on disk carries no space, so the name they typed becomes a folder they
/// can still recognise.
@Test func aProjectWithNoSessionStartsOne() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let path = "/Users/someone/Music/My Sketch.logicx"

  let today = try SessionIndex.repository(
    forProjectPath: path,
    startingWith: aSession(named: "My Sketch"),
    root: root,
    state: aProject(named: "My Sketch"),
    git: git)

  #expect(today.didStart, "no session carried the path, so the command started one")
  let session = today.repository.session
  #expect(session.project.path == path, "the session records the project it belongs to")
  #expect(
    today.repository.folder.lastPathComponent == "My_Sketch-\(session.shortId)",
    "a name a person typed becomes a folder name, and a folder name carries no space")
  #expect(try sessionFolders(underRoot: root) == ["My_Sketch-\(session.shortId)"])

  let subjects = lines(
    of: try git.run(["log", "--format=%s"], in: today.repository.folder))
  #expect(subjects == ["session \(session.shortId)"], "the session opens with its first commit")

  let tomorrow = try SessionIndex.repository(
    forProjectPath: path,
    startingWith: aSession(named: "My Sketch"),
    root: root,
    state: aProject(named: "My Sketch"),
    git: git)

  #expect(tomorrow.didStart == false, "the same project is the same session")
  #expect(tomorrow.repository.session.id == session.id)
  #expect(tomorrow.repository.folder == today.repository.folder)
  #expect(
    try sessionFolders(underRoot: root) == ["My_Sketch-\(session.shortId)"],
    "one project keeps one history, so nothing started a second session")
}

/// A project that moves is relinked, and two sessions can then carry one path. The work goes on
/// in the session that was started last, so a person who relinks reads their newest work.
@Test func theNewestSessionOnOnePathWins() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let path = "/Users/someone/Music/Moved.logicx"
  let earlier = Date(timeIntervalSince1970: 1_700_000_000)
  let later = Date(timeIntervalSince1970: 1_800_000_000)

  let old = try SessionRepository.start(
    session: withPath(aSession(named: "Moved", at: earlier), path), root: root, git: git)
  let new = try SessionRepository.start(
    session: withPath(aSession(named: "Moved", at: later), path), root: root, git: git)

  let found = SessionIndex.session(atProjectPath: path, root: root)
  #expect(found?.id == new.session.id)
  #expect(found?.id != old.session.id)
}

/// A command that is writing a session must not stop the command that comes next. A folder with
/// nothing readable in it is passed over, and the project it belongs to still finds its session.
@Test func aHalfWrittenSessionFolderIsPassedOver() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let path = "/Users/someone/Music/Sketch.logicx"

  let repository = try SessionRepository.start(
    session: withPath(aSession(named: "Sketch"), path), root: root, git: git)
  let half = SessionRepository.sessionsFolder(underRoot: root)
    .appendingPathComponent("Half-00000000")
  try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
  try Data("{".utf8).write(to: half.appendingPathComponent("session.json"), options: .atomic)

  #expect(SessionIndex.sessions(underRoot: root).count == 1)
  #expect(SessionIndex.session(atProjectPath: path, root: root)?.id == repository.session.id)
}

/// A session of a project that was saved once, so it carries a path.
private func withPath(_ session: Session, _ path: String) -> Session {
  var carried = session
  carried.project.path = path
  return carried
}
