import Foundation
import LogicctlCore
import LogicctlJournal
import Testing

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-journal-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A git whose configuration signs every commit, with a signing program that always fails.
///
/// One configuration covers the two things a session must survive: an operator who signs every
/// commit, and a machine with no signing program at all. A commit that tries to sign cannot
/// succeed here, so the only way past it is the repository turning signing off for itself.
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

/// The lines of some output, without the empty one at the end.
private func lines(of output: String) -> [String] {
  output.split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)
    .filter { !$0.isEmpty }
}

/// The state of a project with one track, as Logic read it before the first command.
private func aProjectWithOneTrack() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch 1"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// A session of that project, as `new-project` starts one.
private func aSession() -> Session {
  Session(
    project: Session.Project(
      name: "Sketch 1", path: "/tmp/Sketch 1.logicx", createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// One step as a command writes it: it ran, it ended, and it carries the two state hashes.
private func aStep(sequence: Int, command: String, before: State, after: State) -> Step {
  Step(
    seq: sequence,
    kind: .command,
    command: command,
    argv: ["--index", "1", "--on"],
    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
    finishedAt: Date(timeIntervalSince1970: 1_700_000_001),
    exitCode: 0,
    stateBefore: CanonicalJSON.sha256(of: before),
    stateAfter: CanonicalJSON.sha256(of: after),
    differences: StateDiff.between(before, after))
}

/// What one trailer of one commit holds.
private func trailer(
  _ key: String, of commit: String, of repository: SessionRepository, with git: Git
) throws -> String {
  let format = "--format=%(trailers:key=\(key),valueonly)"
  let printed = try git.run(["show", "--quiet", format, commit], in: repository.folder)
  return printed.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The text of one file of the repository.
private func text(of relative: String, of repository: SessionRepository) throws -> String {
  let data = try Data(contentsOf: repository.folder.appendingPathComponent(relative))
  return String(decoding: data, as: UTF8.self)
}

/// The sequence that the `step.json` of one step carries.
private func sequenceInStep(_ sequence: Int, of repository: SessionRepository) throws -> Int {
  let name = SessionRepository.stepFolderName(ofSequence: sequence)
  let read = try CanonicalJSON.value(of: text(of: "steps/\(name)/step.json", of: repository))
  guard case .object(let members) = read, case .number(let found) = members["seq"] ?? .null else {
    return 0
  }
  return Int(found)
}

/// The names of the step folders the repository holds.
private func stepFolders(of repository: SessionRepository) throws -> [String] {
  let steps = repository.folder.appendingPathComponent("steps").path
  return try FileManager.default.contentsOfDirectory(atPath: steps).sorted()
}

/// A person reads a session as a history. `git log` is the list of commands that ran, and the
/// difference between two commits is what Logic did between them. That holds only while one
/// command is one commit, while the commit says which command it was and which state it left
/// behind, and while writing a step never asks anybody for a signing key.
@Test func oneStepIsOneCommit() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let session = aSession()

  let opening = aProjectWithOneTrack()
  var muted = opening
  muted.tracks[0].mute = true
  var soloed = muted
  soloed.tracks[0].solo = true

  let repository = try SessionRepository.start(
    session: session, root: root, state: opening, git: git)
  let first = try repository.write(
    aStep(
      sequence: repository.nextSequence(), command: "tracks mute", before: opening, after: muted),
    state: muted)
  let second = try repository.write(
    aStep(
      sequence: repository.nextSequence(), command: "tracks solo", before: muted, after: soloed),
    state: soloed)

  let subjects = lines(of: try git.run(["log", "--reverse", "--format=%s"], in: repository.folder))
  #expect(subjects == ["session \(session.shortId)", "1 tracks mute", "2 tracks solo"])

  let authors = lines(of: try git.run(["log", "--format=%an <%ae>"], in: repository.folder))
  #expect(authors == Array(repeating: "logicctl <logicctl@localhost>", count: 3))

  let signatures = lines(of: try git.run(["log", "--format=%G?"], in: repository.folder))
  #expect(signatures == ["N", "N", "N"], "a session is written with nobody's key")

  let kind = try trailer("Logicctl-Kind", of: first, of: repository, with: git)
  let before = try trailer("Logicctl-State-Before", of: first, of: repository, with: git)
  let after = try trailer("Logicctl-State-After", of: first, of: repository, with: git)
  #expect(kind == "command")
  #expect(before == CanonicalJSON.sha256(of: opening))
  #expect(after == CanonicalJSON.sha256(of: muted))

  let secondAfter = try trailer("Logicctl-State-After", of: second, of: repository, with: git)
  #expect(secondAfter == CanonicalJSON.sha256(of: soloed))

  let touched = try git.run(["show", "--name-only", "--format=", first], in: repository.folder)
  #expect(lines(of: touched).sorted() == ["state.json", "steps/000001/step.json"])

  let sequences = [try sequenceInStep(1, of: repository), try sequenceInStep(2, of: repository)]
  #expect(sequences == [1, 2], "the sequence starts at 1 and it carries no gap")
  #expect(try stepFolders(of: repository) == ["000001", "000002"])

  let state = try text(of: "state.json", of: repository)
  #expect(state == CanonicalJSON.text(of: soloed, indent: 2) + "\n")
}

/// Two writers never write one step into the middle of another. The watcher records a save while
/// a command runs, and a command runs while the watcher records, so the second one waits for the
/// first and gives up when the wait runs out.
@Test func aSecondWriterWaitsForTheLockAndThenGivesUp() throws {
  let folder = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: folder) }
  let holder = Lock()
  let second = Lock(waitSeconds: 0.2)
  var refused: Lock.Refusal?

  try holder.holding(folder) {
    do {
      try second.holding(folder) { () throws -> Void in
        Issue.record("the second writer took a lock the first one was holding")
      }
    } catch let found as Lock.Refusal {
      refused = found
    }
  }

  guard let found = refused, case .anotherWriterHeldIt(let waitedMs) = found else {
    Issue.record("the second writer did not report a wait that ran out")
    return
  }
  #expect(waitedMs >= 200, "it waited for the whole limit before it gave up")
  #expect(Lock.defaultWaitSeconds == 5, "contract RUN-6 gives five seconds to every wait")
}

/// A git that never ends does not hold logicctl for ever, so a command answers the person even
/// when the tool underneath it is stuck.
@Test func aRunOfGitThatPassesItsLimitIsStopped() throws {
  let folder = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: folder) }
  let slow = Git(executable: URL(fileURLWithPath: "/bin/sleep"), limitSeconds: 0.3)

  #expect(throws: Git.Refusal.tookTooLong(arguments: ["30"], seconds: 0.3)) {
    try slow.run(["30"], in: folder)
  }
  #expect(Git.defaultLimitSeconds == 10, "the architecture gives ten seconds to one run of git")
}
