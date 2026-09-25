import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-replay-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A git whose configuration signs every commit, with a signing program that always fails.
///
/// A session repository turns signing off for itself, so a commit of logicctl never waits for a
/// key. No test reads or writes the configuration of the operator.
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

/// A clock and a sleep the test moves itself, so a wait of any length costs the suite no time.
private final class Time {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
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

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// The `data` of the answer, or an empty object when it carries none.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }

  /// The `error` of the answer, or an empty object when it carries none.
  func failure() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }

  /// The `meta` of the answer.
  func meta() throws -> [String: Any] {
    try printed()["meta"] as? [String: Any] ?? [:]
  }

  /// The report of the replay, from wherever this answer carries it.
  func report() throws -> [String: Any] {
    if let clean = try printed()["data"] as? [String: Any], !clean.isEmpty {
      return clean
    }
    return try failure()["details"] as? [String: Any] ?? [:]
  }
}

/// When the session these tests replay was recorded.
private let aMoment = Date(timeIntervalSince1970: 1_700_000_000)

/// The project Logic opens for a replay: no tracks, as `new-project` leaves it.
private func anEmptyProject() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Untitled"),
    transport: Transport(tempo: 120),
    tracks: [])
}

/// The project with one track in it, which is what the recorded work built.
private func aProject(withTrackNamed name: String, muted: Bool = false) -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Untitled"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: name, type: .softwareInstrument, mute: muted)])
}

/// The session of the work that is replayed.
private func aRecordedSession() -> Session {
  Session(
    createdAt: aMoment,
    project: Session.Project(name: "Sketch", path: nil, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// The Logic a test drives: the chooser in front, and the project it opens behind it.
///
/// It starts where a person starts, with no project open at all, so the project a replay works in
/// is the project the route itself opened.
private final class Mac {
  /// What Logic shows in front.
  var showing: ProjectWindow? = .chooser

  /// The Logic the command reads the project through. It refuses until the project exists.
  let driver = FakeLogicDriver()

  /// The process this Logic runs as.
  let processID: Int32 = 981

  /// The chooser the command drives. Choosing the template opens the project, as Logic does.
  func chooser() -> ProjectChooser {
    ProjectChooser(
      read: { self.showing },
      press: { locator in
        guard locator.name == Locators.chooserChooseButton.name else {
          return
        }
        self.driver.state = anEmptyProject()
        self.driver.runningProcessID = self.processID
        self.showing = .emptyProject
      })
  }
}

/// A session of work that was recorded, as replay finds it on disk.
///
/// The test keeps the state each step left, so a runner can answer what a command of that step
/// would leave, and the assertions can name the state that a step differs from.
private final class Recording {
  /// Where the work sits.
  let repository: SessionRepository

  /// The state each step left, by the number of that step.
  var left: [Int: State] = [:]

  /// The commit of each step, by the number of that step.
  var commits: [Int: String] = [:]

  private var held: State?
  private var next = 1

  init(root: URL, git: Git, session: Session = aRecordedSession()) throws {
    repository = try SessionRepository.start(session: session, root: root, git: git)
  }

  /// The id of the session that was recorded.
  var id: String {
    repository.session.id
  }

  /// Writes one step of the recorded work, and answers the commit it became.
  @discardableResult
  func wrote(
    _ kind: Step.Kind, command: String?, argv: [String] = [], leaving state: State
  ) throws -> String {
    let sequence = next
    next += 1
    let moment = aMoment.addingTimeInterval(Double(sequence) * 60)
    let step = Step(
      seq: sequence,
      kind: kind,
      command: command,
      argv: argv,
      startedAt: moment,
      finishedAt: moment.addingTimeInterval(1),
      exitCode: 0,
      stateBefore: held.map { CanonicalJSON.sha256(of: $0) },
      stateAfter: CanonicalJSON.sha256(of: state))
    let commit = try repository.write(step, state: state)
    held = state
    left[sequence] = state
    commits[sequence] = commit
    return commit
  }

  /// A runner that repeats the work: each step leaves the project as the record says it was left.
  ///
  /// This is what a perfect replay of this session looks like. Everything a test then reads about
  /// skipped steps and differences comes from the engine and not from a runner that drifted.
  func aPerfectRunner() -> SessionReplay.Runner {
    { (step: RecordedStep) -> ReplayRun in
      guard let state = self.left[step.seq] else {
        return ReplayRun.noSuchCommand
      }
      return ReplayRun.ran(state)
    }
  }

  /// A runner that repeats the work, except for one step, which leaves another project.
  func aRunnerThatLeaves(_ other: State, atStep drifting: Int) -> SessionReplay.Runner {
    { (step: RecordedStep) -> ReplayRun in
      if step.seq == drifting {
        return ReplayRun.ran(other)
      }
      guard let state = self.left[step.seq] else {
        return ReplayRun.noSuchCommand
      }
      return ReplayRun.ran(state)
    }
  }
}

/// One JSON file of a session, read back.
private func readJSON(at file: URL) throws -> JSONValue {
  try CanonicalJSON.value(of: String(decoding: try Data(contentsOf: file), as: UTF8.self))
}

/// The members of a JSON object, or nothing when the value is not an object.
private func members(of value: JSONValue?) -> [String: JSONValue]? {
  guard case .object(let found) = value else {
    return nil
  }
  return found
}

/// Where one session of a root sits, or nothing when the root holds no session with that id.
private func folder(ofSessionWithId id: String, underRoot root: URL) -> URL? {
  guard let session = SessionIndex.sessions(underRoot: root).first(where: { $0.id == id }) else {
    return nil
  }
  return SessionRepository.sessionFolder(of: session, underRoot: root)
}

/// A change a person made in Logic cannot be run again, and a replay says so instead of passing
/// over it.
///
/// A person replays a session to learn one thing: whether the work in it is repeatable. Every step
/// logicctl wrote can be run again, because a command is a command. A change somebody made with
/// the mouse cannot, and the session holds it as a step of its own. A replay that walked past that
/// step quietly would answer that the session replayed cleanly, while the project it built is not
/// the project the session describes, and the difference is exactly the change nobody can repeat.
///
/// So the skip reaches the exit code. An agent reads the number, not the prose, and 15 is the
/// number that says a replay did not repeat the work. The report names the step by its number and
/// says why it was passed over, so the person knows which change to make by hand.
@Test func replaySkipsAChangeByHand() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try Recording(root: root, git: git)
  try recorded.wrote(
    .command, command: "tracks add", argv: ["--type", "software-instrument"],
    leaving: aProject(withTrackNamed: "Inst 1"))
  try recorded.wrote(
    .externalChange, command: nil, leaving: aProject(withTrackNamed: "Inst 1", muted: true))
  try recorded.wrote(
    .command, command: "tracks rename", argv: ["--index", "1", "--name", "Bass"],
    leaving: aProject(withTrackNamed: "Bass", muted: true))
  try recorded.wrote(
    .command, command: "tracks mute", argv: ["--index", "1", "--off"],
    leaving: aProject(withTrackNamed: "Bass"))

  let typed = try Logicctl.parseAsRoot(["replay", recorded.id])
  #expect(typed is Replay, "a person can type logicctl replay <session>")

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    chooser: logic.chooser(),
    driver: logic.driver,
    runner: recorded.aPerfectRunner(),
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 15, "a replay that passed over a step exits with replay_differences")
  let failure = try answer.failure()
  #expect(failure["code"] as? String == "replay_differences")
  #expect(
    failure["message"] as? String == "Replay skipped 1 step and found 0 differences",
    "the answer says how much of the session was not repeated")
  #expect(
    answer.err == "logicctl: replay_differences: Replay skipped 1 step and found 0 differences\n",
    "and the person reading along is told the same thing on one line")
  #expect(try answer.printed()["data"] is NSNull, "a failure carries no data")

  let report = try #require(
    failure["details"] as? [String: Any], "the whole report is in error.details")
  let skipped = try #require(report["skipped"] as? [[String: Any]])
  #expect(skipped.count == 1, "the change made by hand is the one step replay could not run")
  #expect(skipped.first?["seq"] as? Int == 2, "it names the step of the session it passed over")
  #expect(skipped.first?["reason"] as? String == "cannot_repeat_a_change_by_hand")
  #expect(report["stepsRun"] as? Int == 3, "every command of the session ran again")
  #expect(
    (report["differences"] as? [[String: Any]])?.isEmpty == true,
    "and each one left the project as the record says it was left")
  #expect(report["source"] as? String == recorded.id, "the report names the session it read")
}

/// A session whose every step is a command of logicctl replays, and the answer says so.
///
/// This is the other half of the promise. A replay that reported a difference for work that was
/// repeated would be worth as little as one that hid a difference, so a clean run exits 0 and
/// carries the report under `data`, where the answer of a command that worked belongs.
@Test func aCleanSessionReplaysWithoutADifference() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try Recording(root: root, git: git)
  let first = try recorded.wrote(
    .command, command: "tracks add", argv: ["--type", "software-instrument"],
    leaving: aProject(withTrackNamed: "Inst 1"))
  let last = try recorded.wrote(
    .command, command: "tracks mute", argv: ["--index", "1", "--on"],
    leaving: aProject(withTrackNamed: "Inst 1", muted: true))

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    chooser: logic.chooser(),
    driver: logic.driver,
    runner: recorded.aPerfectRunner(),
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 0, "a replay that repeated the work exits 0")
  #expect(answer.err.isEmpty, "standard error is empty on success")
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and a newline")
  #expect(try answer.printed()["error"] is NSNull)

  let report = try answer.data()
  #expect((report["skipped"] as? [[String: Any]])?.isEmpty == true, "nothing was passed over")
  #expect((report["differences"] as? [[String: Any]])?.isEmpty == true, "and nothing differed")
  #expect(report["stepsRun"] as? Int == 2, "both steps ran again")
  #expect(report["from"] as? String == first, "the report names the first step it read")
  #expect(report["to"] as? String == last, "and the last one")

  let meta = try answer.meta()
  let session = try #require(report["session"] as? String, "the report names its own session")
  #expect(meta["session"] as? String == session, "which is the session of the answer")
  #expect(meta["step"] as? String != nil, "and the last step replay wrote")
  #expect(session != recorded.id, "a replay records its work in a session of its own")
}

/// The work of a replay is a session, and that session says which session it came from.
///
/// A replay builds a second project, and a person compares the two histories afterwards. So the
/// new session carries the id it replayed and the commits it read, and each check it wrote holds
/// the command that ran and what the comparison found.
@Test func theReplaySessionSaysWhatItReplayed() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try Recording(root: root, git: git)
  let first = try recorded.wrote(
    .command, command: "tracks add", argv: ["--type", "software-instrument"],
    leaving: aProject(withTrackNamed: "Inst 1"))
  let last = try recorded.wrote(
    .command, command: "tracks mute", argv: ["--index", "1", "--on"],
    leaving: aProject(withTrackNamed: "Inst 1", muted: true))

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    chooser: logic.chooser(),
    driver: logic.driver,
    runner: recorded.aPerfectRunner(),
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 0)
  let answered = try answer.data()
  let session = try #require(answered["session"] as? String)
  let replayed = try #require(
    folder(ofSessionWithId: session, underRoot: root), "the replay wrote a session of its own")

  let written = try readJSON(at: replayed.appending(path: "session.json"))
  let onDisk = try #require(Session(json: written))
  #expect(onDisk.replayOf?.session == recorded.id, "the new session names the work it repeated")
  #expect(onDisk.replayOf?.from == first, "and the first step commit it read")
  #expect(onDisk.replayOf?.to == last, "and the last one")
  #expect(onDisk.project.createdByLogicctl, "replay made this project")

  let history = try git.run(["log", "--format=%s"], in: replayed)
    .split(whereSeparator: \.isNewline)
    .map(String.init)
  #expect(history.count == 3, "the session was started, and replay wrote one check for each step")
  #expect(history.first == "2 tracks mute", "the check of the last step is the commit on top")

  let check = try readJSON(at: replayed.appending(path: "steps/000001/step.json"))
  let fields = try #require(members(of: check))
  #expect(fields["kind"] == JSONValue.string("replay_check"))
  #expect(fields["command"] == JSONValue.string("tracks add"), "the check names the command")
  #expect(
    fields["argv"] == JSONValue.array([.string("--type"), .string("software-instrument")]),
    "and what was typed with it")
  #expect(fields["differences"] == JSONValue.array([]), "this step left the project as recorded")
  #expect(fields["screenshot"] == JSONValue.null, "a check of a state takes no picture")
  let added = CanonicalJSON.sha256(of: aProject(withTrackNamed: "Inst 1"))
  #expect(
    fields["stateAfter"] == JSONValue.string(added),
    "and it records the project the step left")
}

/// A step that left another project is the difference the replay was run to find.
///
/// The record of a step holds the hash of the state, so a replay that only compared hashes could
/// say that something differs and never which field. A person needs the field: it is the
/// difference between reading "the replay failed" and reading that the track came back muted.
@Test func aStepThatLeavesAnotherProjectIsADifference() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try Recording(root: root, git: git)
  try recorded.wrote(
    .command, command: "tracks add", argv: ["--type", "software-instrument"],
    leaving: aProject(withTrackNamed: "Inst 1"))
  try recorded.wrote(
    .command, command: "tracks rename", argv: ["--index", "1", "--name", "Bass"],
    leaving: aProject(withTrackNamed: "Bass"))

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    chooser: logic.chooser(),
    driver: logic.driver,
    runner: recorded.aRunnerThatLeaves(aProject(withTrackNamed: "Bass", muted: true), atStep: 2),
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 15)
  #expect(
    try answer.failure()["message"] as? String
      == "Replay skipped 0 steps and found 1 differences",
    "no step was passed over, and one field of the project is not what the session recorded")

  let report = try answer.report()
  #expect((report["skipped"] as? [[String: Any]])?.isEmpty == true)
  #expect(report["stepsRun"] as? Int == 2, "both steps ran, and the second one differed")
  let differences = try #require(report["differences"] as? [[String: Any]])
  #expect(differences.count == 1, "one step of the session differs")
  #expect(differences.first?["seq"] as? Int == 2)
  let fields = try #require(differences.first?["differences"] as? [[String: Any]])
  #expect(fields.count == 1, "and one field of it")
  #expect(fields.first?["path"] as? String == "/tracks/0/mute", "which field, as a pointer")
  #expect(fields.first?["before"] as? Bool == false, "what the session recorded")
  #expect(fields.first?["after"] as? Bool == true, "and what the replay left")
}

/// A command that this build of logicctl does not have is reported, and never quietly passed over.
///
/// The tool grows one command at a time, so a session recorded by a later build can hold a command
/// this one cannot run. A replay that ignored those would answer 0 differences after running
/// almost nothing. It reports each one as a skipped step, so the number of steps that ran and the
/// steps that did not are both in the report, and the replay fails.
@Test func aCommandThisBuildDoesNotHaveIsSkipped() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try Recording(root: root, git: git)
  try recorded.wrote(.command, command: "new-project", leaving: anEmptyProject())
  try recorded.wrote(
    .command, command: "tracks add", argv: ["--type", "software-instrument"],
    leaving: aProject(withTrackNamed: "Inst 1"))

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    chooser: logic.chooser(),
    driver: logic.driver,
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 15, "a replay that could not run a step of the session exits 15")
  let report = try answer.report()
  #expect(report["stepsRun"] as? Int == 1, "the new project is the step this build can repeat")
  let skipped = try #require(report["skipped"] as? [[String: Any]])
  #expect(skipped.count == 1)
  #expect(skipped.first?["seq"] as? Int == 2)
  #expect(skipped.first?["reason"] as? String == "no_such_command")
  #expect(
    (report["differences"] as? [[String: Any]])?.isEmpty == true,
    "the step that ran left the project the session recorded")
}

/// A session nobody recorded cannot be replayed, and the refusal names what was typed.
@Test func aSessionThatIsNotThereIsRefused() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: "6f0a1b2c-3d4e-4f50-8a9b-0c1d2e3f4a5b",
    chooser: logic.chooser(),
    driver: logic.driver,
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 2, "invalid_argument exits 2")
  let failure = try answer.failure()
  #expect(failure["code"] as? String == "invalid_argument")
  #expect(
    (failure["details"] as? [String: Any])?["session"] as? String
      == "6f0a1b2c-3d4e-4f50-8a9b-0c1d2e3f4a5b")
  let meta = try answer.meta()
  #expect(meta["session"] is NSNull, "nothing was replayed, so no session was written")
  #expect(meta["step"] is NSNull)
  #expect(logic.showing == ProjectWindow.chooser, "and Logic was left as it was")
}
