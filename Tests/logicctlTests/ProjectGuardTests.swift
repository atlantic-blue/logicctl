import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlTesting
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-guard-\(UUID().uuidString)")
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

/// Where the project of these tests sits.
private let projectPath = "/Users/someone/Music/Their Sketch.logicx"

/// The project as Logic holds it: one track, 120 beats a minute.
private func aProject() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Their Sketch"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// The session of that project. `madeByLogicctl` says who started the project.
private func aSession(madeByLogicctl: Bool) -> Session {
  Session(
    project: Session.Project(
      name: "Their Sketch", path: projectPath, createdByLogicctl: madeByLogicctl),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// A command that changes the project: it sets the tempo. No subcommand of logicctl changes Logic
/// yet, so a test declares the smallest change there is.
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

/// The subjects of every commit of a session, newest first.
private func subjects(of folder: URL, with git: Git) throws -> [String] {
  try git.run(["log", "--format=%s"], in: folder)
    .split(separator: "\n", omittingEmptySubsequences: true)
    .map(String.init)
}

/// A person opens a project they wrote themselves, and an agent asks logicctl to change it.
///
/// The work in that project is theirs, so logicctl does not touch it on its own word. The agent
/// reads `confirm_required` and exit 7, and the project is as the person left it: the tempo has
/// not moved, and the session gained no step. The person then says `--confirm`, and the same
/// command goes through and is recorded.
@Test func aChangeToAProjectLogicctlDidNotCreateNeedsConfirm() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let theirs = aProject()
  let session = try SessionRepository.start(
    session: aSession(madeByLogicctl: false), root: root, state: theirs, git: git)
  let driver = FakeLogicDriver(state: theirs, path: projectPath)
  let run = Run(driver: driver, root: root, version: "0.1.0", git: git)

  let refused = run.run(change: SetTheTempo(96), confirmed: false)

  #expect(refused.error?.code == .confirmRequired, "the project is not one logicctl made")
  #expect(refused.exitCode == 7)
  #expect(
    driver.state?.transport.tempo == 120, "the project of the person is as they left it")
  #expect(refused.meta.step == nil, "a refused change writes no step")
  #expect(
    try subjects(of: session.folder, with: git) == ["session \(session.session.shortId)"],
    "the session of the project gained nothing")

  let allowed = run.run(change: SetTheTempo(96), confirmed: true)

  #expect(allowed.error == nil, "the person said --confirm, so the change goes through")
  #expect(driver.state?.transport.tempo == 96, "Logic holds the tempo the command asked for")
  _ = try #require(allowed.meta.step, "the change that went through is in the record")
  #expect(
    try subjects(of: session.folder, with: git).first == "1 transport tempo",
    "the session holds the change that was allowed, and only that one")
}

/// A project that no session carries is a project logicctl never made, so it is guarded too.
///
/// The first command against a project a person saved somewhere new must not be the one that
/// changes it, because nothing so far says logicctl started that work.
@Test func aChangeToAProjectWithNoSessionNeedsConfirmToo() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let driver = FakeLogicDriver(state: aProject(), path: projectPath)
  let run = Run(driver: driver, root: root, version: "0.1.0", git: git)

  let refused = run.run(change: SetTheTempo(96), confirmed: false)

  #expect(refused.error?.code == .confirmRequired)
  #expect(driver.state?.transport.tempo == 120, "nothing was changed")
  #expect(
    SessionIndex.session(atProjectPath: projectPath, root: root) == nil,
    "a refused change starts no session either")
}

/// A project that logicctl made is its own work, so a change to it needs no word from anybody.
@Test func aChangeToAProjectLogicctlMadeNeedsNoConfirm() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let ours = aProject()
  _ = try SessionRepository.start(
    session: aSession(madeByLogicctl: true), root: root, state: ours, git: git)
  let driver = FakeLogicDriver(state: ours, path: projectPath)

  let answer = Run(driver: driver, root: root, version: "0.1.0", git: git)
    .run(change: SetTheTempo(96), confirmed: false)

  #expect(answer.error == nil, "logicctl made this project, so it changes it")
  #expect(driver.state?.transport.tempo == 96)
}

/// A project that was never saved sits at no path, so no session carries it and the guard has
/// nothing to read. The run answers as it does for any project with no path: it records nothing.
@Test func aProjectThatWasNeverSavedIsNotGuarded() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let driver = FakeLogicDriver(state: aProject(), path: nil)

  let answer = Run(driver: driver, root: root, version: "0.1.0", git: git)
    .run(change: SetTheTempo(96), confirmed: false)

  #expect(answer.error == nil, "there is no project of a person to protect yet")
  #expect(driver.state?.transport.tempo == 96)
  #expect(answer.meta.session == nil, "a project with no path has no session")
}
