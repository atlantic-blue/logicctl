import Foundation
import LogicctlCore
import LogicctlJournal
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-show-\(UUID().uuidString)")
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

/// When the first step of these tests started. The next ones follow it a minute apart.
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
private func aSession(at path: String) -> Session {
  Session(
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    project: Session.Project(name: "Sketch", path: path, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// One step, written into a session, answering the commit that holds it.
///
/// The step carries the state it started from and the state it left, so the hash before a step and
/// the hash after it are two different hashes, and the hashes of one step are not the hashes of
/// the step beside it.
@discardableResult
private func write(
  _ sequence: Int,
  kind: Step.Kind = .command,
  command: String? = nil,
  argv: [String] = [],
  exitCode: Int = 0,
  minutesIn: Int,
  into repository: SessionRepository,
  from before: State,
  leaving after: State,
  picture: Data? = nil
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
    envelope: .object(["data": .null, "error": .null]),
    stateBefore: CanonicalJSON.sha256(of: before),
    stateAfter: CanonicalJSON.sha256(of: after))
  return try repository.write(step, state: after, screenshot: picture)
}

/// What one run of `show` wrote, on each channel.
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

  /// The step the answer carries.
  func step() throws -> [String: Any] {
    try envelope()["data"] as? [String: Any] ?? [:]
  }

  /// What the answer says went wrong.
  func failure() throws -> [String: Any] {
    try envelope()["error"] as? [String: Any] ?? [:]
  }
}

/// A session of three steps, each one leaving the project in a state of its own.
///
/// Track 1 is muted, then renamed, then the tempo moves. So every step has a hash before it and a
/// different hash after it, and no two steps share a pair.
private func aSessionOfThreeSteps(
  root: URL, git: Git, picture: Data? = nil
) throws -> SessionRepository {
  let repository = try SessionRepository.start(
    session: aSession(at: "/Users/someone/Music/Sketch.logicx"), root: root,
    state: aProjectWithOneTrack(), git: git)

  let start = aProjectWithOneTrack()
  var muted = start
  muted.tracks[0].mute = true
  var renamed = muted
  renamed.tracks[0].name = "Bass"
  var faster = renamed
  faster.transport.tempo = 128

  try write(
    1, command: "tracks add", argv: ["--type", "software-instrument"], minutesIn: 0,
    into: repository, from: start, leaving: muted)
  try write(
    2, command: "tracks mute", argv: ["--index", "1", "--on"], minutesIn: 1, into: repository,
    from: muted, leaving: renamed, picture: picture)
  try write(
    3, command: "transport tempo", argv: ["128"], minutesIn: 2, into: repository, from: renamed,
    leaving: faster)
  return repository
}

/// What one trailer of one commit says.
private func trailer(
  _ name: String, of commit: String, in repository: SessionRepository
) throws -> String {
  let printed = try repository.git.run(
    ["show", "--no-patch", "--format=%(trailers:key=" + name + ",valueonly)", commit],
    in: repository.folder)
  return printed.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A person reads one step to learn what the project looked like before logicctl touched it and
/// what it looked like after. Those two hashes are the whole record of the change: a replay is
/// held to them, and a change nobody typed is found by them.
///
/// So the pair the command answers is held to the pair the commit carries. If the two disagreed,
/// the journal would prove nothing, because a reader could not tell which of them was the record
/// of what happened to the project.
@Test func showPrintsTheStateHashes() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try aSessionOfThreeSteps(root: root, git: git)

  let answer = Answer()
  let exitCode = Show.answer(
    step: 2, root: root, git: git, standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 0, "reading a step is not a failure")
  let step = try answer.step()
  let commit = try #require(step["commit"] as? String, "the answer names the commit of the step")

  let before = try #require(step["stateBefore"] as? String)
  let after = try #require(step["stateAfter"] as? String)
  let recordedBefore = try trailer("Logicctl-State-Before", of: commit, in: repository)
  let recordedAfter = try trailer("Logicctl-State-After", of: commit, in: repository)
  #expect(
    before == recordedBefore,
    "the state before the step is the state the commit of that step recorded")
  #expect(
    after == recordedAfter,
    "the state after the step is the state the commit of that step recorded")
  #expect(before != after, "the step changed the project, so the two hashes are not one hash")
}

/// The answer carries what a person asked for and what came back, under the names the mockup of
/// this command shows.
@Test func showPrintsWhatWasTypedAndWhatCameBack() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try aSessionOfThreeSteps(root: root, git: git)

  let answer = Answer()
  _ = Show.answer(
    step: 2, root: root, git: git, standardOutput: answer.write,
    standardError: answer.writeError)

  let step = try answer.step()
  #expect(step["seq"] as? Int == 2, "the step the person asked for")
  #expect(step["kind"] as? String == "command")
  #expect(step["command"] as? String == "tracks mute")
  #expect(step["argv"] as? [String] == ["--index", "1", "--on"], "the arguments as they were typed")
  #expect(step["exitCode"] as? Int == 0)
  #expect(step["startedAt"] as? String == "2023-11-14T22:14:20Z", "RFC 3339 in UTC")
  #expect(step["finishedAt"] as? String == "2023-11-14T22:14:21Z")
  #expect(step["session"] as? String == repository.session.id, "which session the step came from")

  let versions = step["versions"] as? [String: Any] ?? [:]
  #expect(versions["logicctl"] as? String == "0.1.0", "story J1 asks for the versions")
  #expect(versions["logic"] as? String == "12.3.1")
  #expect(versions["macos"] as? String == "15.0")
}

/// The answer names the picture of the window at a path inside the session repository, so a person
/// who reads a step can open the picture of that step without working out where it sits.
@Test func showNamesThePictureOfTheStep() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try aSessionOfThreeSteps(root: root, git: git, picture: Data("png".utf8))

  let answer = Answer()
  _ = Show.answer(
    step: 2, root: root, git: git, standardOutput: answer.write,
    standardError: answer.writeError)

  let named = try #require(answer.step()["screenshot"] as? String)
  #expect(named == "steps/000002/screenshot.png", "the path from the repository down to it")
  let picture = repository.folder.appendingPathComponent(named)
  #expect(
    FileManager.default.fileExists(atPath: picture.path),
    "and the picture is there, so the path a person is given opens a file")
}

/// A capture that failed leaves the step with no picture. The field is null and never a path to a
/// file that is not there.
@Test func aStepWithNoPictureNamesNone() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  _ = try aSessionOfThreeSteps(root: root, git: git)

  let answer = Answer()
  _ = Show.answer(
    step: 2, root: root, git: git, standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(try answer.step()["screenshot"] is NSNull)
}

/// `show` reads the journal and never Logic, so it names no session and no step in `meta`, the way
/// the data model asks of every command that does not talk to Logic.
@Test func showNamesNoSessionAndNoStepInItsMeta() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  _ = try aSessionOfThreeSteps(root: root, git: git)

  let answer = Answer()
  _ = Show.answer(
    step: 1, root: root, git: git, standardOutput: answer.write,
    standardError: answer.writeError)

  let meta = try answer.envelope()["meta"] as? [String: Any] ?? [:]
  #expect(meta["session"] is NSNull, "this command read no project")
  #expect(meta["step"] is NSNull, "it wrote nothing, so it recorded nothing")
  #expect(try answer.step()["seq"] as? Int == 1, "and it still answered the step it was asked for")
}

/// Two steps of one session are two different things. Each answer carries the step that was asked
/// for, and a reader that answered a neighbour would say that a change happened at a moment it
/// did not.
@Test func showReadsTheStepItWasAskedFor() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  _ = try aSessionOfThreeSteps(root: root, git: git)

  var answered: [String: [String: Any]] = [:]
  for sequence in [1, 2, 3] {
    let answer = Answer()
    _ = Show.answer(
      step: sequence, root: root, git: git, standardOutput: answer.write,
      standardError: answer.writeError)
    answered["\(sequence)"] = try answer.step()
  }

  #expect(
    ["1", "2", "3"].compactMap { answered[$0]?["command"] as? String } == [
      "tracks add", "tracks mute", "transport tempo",
    ],
    "each answer carries the command of its own step")
  let hashes = ["1", "2", "3"].compactMap { answered[$0]?["stateBefore"] as? String }
  #expect(Set(hashes).count == 3, "each step started from a project of its own")
  #expect(
    answered["1"]?["stateAfter"] as? String == answered["2"]?["stateBefore"] as? String,
    "a session is a chain, so what one step left is what the next one started from")
}

/// A number the session does not hold is a number a person typed wrong. Logic was never asked
/// anything and nothing changed, so the refusal is `invalid_argument`, and it says how many steps
/// the session does hold.
@Test func aStepTheSessionDoesNotHoldIsRefused() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  _ = try aSessionOfThreeSteps(root: root, git: git)

  let answer = Answer()
  let exitCode = Show.answer(
    step: 9, root: root, git: git, standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 2, "a wrong input is invalid_argument, code 2")
  #expect(try answer.failure()["code"] as? String == "invalid_argument")
  #expect(try answer.envelope()["data"] is NSNull, "a failure carries no step")
  let details = try answer.failure()["details"] as? [String: Any] ?? [:]
  #expect(details["step"] as? Int == 9)
  #expect(details["steps"] as? Int == 3, "and how many the session holds, so the person can look")
  #expect(answer.err.hasPrefix("logicctl: invalid_argument: "), "one line for a person")
}

/// Nothing was ever recorded on this Mac, so there is no step to read. The person still typed a
/// number that is not there, which is the same refusal.
@Test func noSessionAtAllRefusesTheStep() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let answer = Answer()
  let exitCode = Show.answer(
    step: 1, root: root, git: git, standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 2)
  #expect(try answer.failure()["code"] as? String == "invalid_argument")
}

/// The record of the step cannot be read. The command fails and says so, rather than answering a
/// step whose fields are empty, which reads exactly like a step that ran and did nothing.
@Test func aStepThatCannotBeReadFailsTheCommand() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let repository = try aSessionOfThreeSteps(root: root, git: git)

  let record =
    repository.folder
    .appendingPathComponent("steps")
    .appendingPathComponent(SessionRepository.stepFolderName(ofSequence: 2))
    .appendingPathComponent("step.json")
  try Data("{}".utf8).write(to: record, options: .atomic)

  let answer = Answer()
  let exitCode = Show.answer(
    step: 2, root: root, git: git, standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 70, "a damaged record is internal, code 70")
  #expect(try answer.failure()["code"] as? String == "internal")
  #expect(try answer.envelope()["data"] is NSNull)
  #expect(answer.err.hasPrefix("logicctl: internal: "), "a person reading along is told one line")
}

/// The command line reaches `show`. A subcommand that the root command does not hold is not there
/// at all, whatever the code behind it does, and every test above would still pass.
@Test func theCommandLineReachesShow() throws {
  let answer = Answer()
  let exitCode = Logicctl.run(
    arguments: ["show", "--help"], standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0, "the help of a command is not a failure")
  #expect(answer.out.contains("logicctl show"), "the help names the command a person types")
  #expect(answer.out.contains("<step>"), "and the step it takes")
}

/// A step counts from 1, the way Logic counts and the way `log` prints. A zero is refused before
/// anything is read, as a wrong argument is.
@Test func aStepBelowOneIsRefused() throws {
  let answer = Answer()
  let exitCode = Logicctl.run(
    arguments: ["show", "0"], standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 2, "a wrong argument is invalid_argument, code 2")
  #expect(try answer.failure()["code"] as? String == "invalid_argument")
}
