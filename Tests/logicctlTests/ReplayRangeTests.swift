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
    .appendingPathComponent("logicctl-replay-range-\(UUID().uuidString)")
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

  /// The `details` of the failure the answer carries, or an empty object when it carries none.
  func details() throws -> [String: Any] {
    try failure()["details"] as? [String: Any] ?? [:]
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
/// is the project the route itself opened. A refusal that never reached Logic leaves the chooser in
/// front, and a test reads that to know nothing was opened.
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
  /// This is what a perfect replay of this session looks like. So everything a test then reads
  /// about the steps that ran comes from the command and not from a runner that drifted.
  func aPerfectRunner() -> SessionReplay.Runner {
    { (step: RecordedStep) -> ReplayRun in
      guard let state = self.left[step.seq] else {
        return ReplayRun.noSuchCommand
      }
      return ReplayRun.ran(state)
    }
  }
}

/// The four steps of work every test here replays part of.
///
/// Step 3 and step 4 are the same command with another flag, so a test that reads the checks a
/// replay wrote can tell the two apart and name which one ran.
private func aSessionOfFourSteps(root: URL, git: Git) throws -> Recording {
  let recorded = try Recording(root: root, git: git)
  try recorded.wrote(
    .command, command: "tracks add", argv: ["--type", "software-instrument"],
    leaving: aProject(withTrackNamed: "Inst 1"))
  try recorded.wrote(
    .command, command: "tracks rename", argv: ["--index", "1", "--name", "Bass"],
    leaving: aProject(withTrackNamed: "Bass"))
  try recorded.wrote(
    .command, command: "tracks mute", argv: ["--index", "1", "--on"],
    leaving: aProject(withTrackNamed: "Bass", muted: true))
  try recorded.wrote(
    .command, command: "tracks mute", argv: ["--index", "1", "--off"],
    leaving: aProject(withTrackNamed: "Bass"))
  return recorded
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

/// The record of one check a replay wrote, by the number of that check.
private func check(_ number: Int, of session: URL) throws -> [String: JSONValue] {
  let folder = "steps/" + SessionRepository.stepFolderName(ofSequence: number) + "/step.json"
  return members(of: try readJSON(at: session.appending(path: folder))) ?? [:]
}

/// A person replays part of a session, and only that part runs.
///
/// A session holds a morning of work, and the piece somebody wants to test again is two steps in
/// the middle of it. So they name the range. What they get back has to be the range they named: a
/// replay that quietly ran the whole session would report a success for work nobody asked it to
/// repeat, and it would carry the project far past the step they stopped at.
///
/// The report is the only place that says what ran. Nobody watches a replay, and the project it
/// built is thrown away afterwards, so `stepsRun` and the two commits are the whole answer to "what
/// did you do". A count that said four for a range of two would be worse than a refusal, because an
/// agent reads the count and moves on.
@Test func replayRunsOnlyTheRange() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try aSessionOfFourSteps(root: root, git: git)
  let second = try #require(recorded.commits[2])
  let third = try #require(recorded.commits[3])

  let typed = try Logicctl.parseAsRoot(["replay", recorded.id, "--from", "2", "--to", "3"])
  #expect(typed is Replay, "a person can type logicctl replay <session> --from 2 --to 3")

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    from: 2,
    to: 3,
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

  #expect(exited == 0, "the two steps of the range repeated the work, so the replay worked")
  #expect(answer.err.isEmpty, "standard error is empty on success")

  let report = try answer.data()
  #expect(report["stepsRun"] as? Int == 2, "the range holds two steps, and two steps ran")
  #expect(report["from"] as? String == second, "the report names the first step of the range")
  #expect(report["to"] as? String == third, "and the last step of it")
  #expect((report["skipped"] as? [[String: Any]])?.isEmpty == true, "nothing was passed over")
  #expect((report["differences"] as? [[String: Any]])?.isEmpty == true, "and nothing differed")

  let id = try #require(report["session"] as? String, "the report names its own session")
  let replayed = try #require(
    folder(ofSessionWithId: id, underRoot: root), "the replay wrote a session of its own")
  let written = try readJSON(at: replayed.appending(path: "session.json"))
  let onDisk = try #require(Session(json: written))
  #expect(onDisk.replayOf?.from == second, "the new session says where the range started")
  #expect(onDisk.replayOf?.to == third, "and where it ended")

  let history = try git.run(["log", "--format=%s"], in: replayed)
    .split(whereSeparator: \.isNewline)
    .map(String.init)
  #expect(history.count == 3, "the session was started, and one check was written for each step")

  let first = try check(1, of: replayed)
  #expect(
    first["command"] == JSONValue.string("tracks rename"),
    "the first check is step 2 of the session, so step 1 was left out")
  let last = try check(2, of: replayed)
  #expect(last["command"] == JSONValue.string("tracks mute"))
  #expect(
    last["argv"] == JSONValue.array([.string("--index"), .string("1"), .string("--on")]),
    "the last check is step 3, so step 4, which is the same command, was left out")
}

/// A range with one end runs to the end of the session it left open.
///
/// Somebody who wants everything after the point where the work went wrong types one flag, and a
/// replay that needed both would make them count the steps to the end of a session first.
@Test func aRangeWithOneEndRunsToTheEndOfTheSession() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try aSessionOfFourSteps(root: root, git: git)
  let third = try #require(recorded.commits[3])
  let fourth = try #require(recorded.commits[4])

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    from: 3,
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
  let report = try answer.data()
  #expect(report["stepsRun"] as? Int == 2, "step 3 and step 4 ran")
  #expect(report["from"] as? String == third, "the range starts where the person said")
  #expect(report["to"] as? String == fourth, "and ends at the last step of the session")
}

/// A range that ends before it starts holds no step, and logicctl says so before it opens Logic.
///
/// The person meant something by it, and nobody can say what, so a replay that guessed would build
/// a project out of a range nobody asked for. It costs a new project and the time of a whole
/// session to find out. So the refusal comes first, and Logic is never asked anything.
@Test func aRangeThatEndsBeforeItStartsIsRefused() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try aSessionOfFourSteps(root: root, git: git)
  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    from: 3,
    to: 2,
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

  #expect(exited == 2, "invalid_argument exits 2")
  #expect(try answer.failure()["code"] as? String == "invalid_argument")
  #expect(try answer.details()["from"] as? Int == 3, "the refusal names the range that was typed")
  #expect(try answer.details()["to"] as? Int == 2)
  #expect(logic.showing == ProjectWindow.chooser, "and Logic was left as it was")
  #expect(
    SessionIndex.sessions(underRoot: root).count == 1,
    "so the only session under the root is the one that was recorded")

  let line = Answer()
  let refused = Logicctl.run(
    arguments: ["replay", recorded.id, "--from", "3", "--to", "2"],
    standardOutput: line.write,
    standardError: line.writeError)
  #expect(refused == 2, "and the command line refuses it before it reaches the project")
  #expect(try line.failure()["code"] as? String == "invalid_argument")
}

/// A range that names a step the session does not hold is refused, and the refusal says how many
/// steps there are.
///
/// A person reads `log`, types the number of a step of another session, and gets back the count of
/// the session they named. That is the number they needed to pick a range in the first place.
@Test func aRangeBeyondTheLastStepIsRefused() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try aSessionOfFourSteps(root: root, git: git)
  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    from: 2,
    to: 9,
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

  #expect(exited == 2, "invalid_argument exits 2")
  #expect(try answer.failure()["code"] as? String == "invalid_argument")
  #expect(try answer.details()["step"] as? Int == 9, "the refusal names the step that is not there")
  #expect(try answer.details()["steps"] as? Int == 4, "and how many the session holds")
  #expect(logic.showing == ProjectWindow.chooser, "and Logic was left as it was")
}

/// A step number starts at 1, so there is no step 0 to replay from.
@Test func aStepNumberStartsAtOne() throws {
  let answer = Answer()

  let exited = Logicctl.run(
    arguments: ["replay", "6f0a1b2c-3d4e-4f50-8a9b-0c1d2e3f4a5b", "--from", "0"],
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 2)
  #expect(try answer.failure()["code"] as? String == "invalid_argument")
}

/// The help of replay names both flags, and it says what a range that starts after step 1 does.
///
/// replay always opens a new project, so a range that starts in the middle runs on a project that
/// misses the work of every step before it, and logicctl gives no warning. A person who reads that
/// in the help picks a range that starts at 1, or knows what they are looking at.
@Test func theHelpOfReplayNamesTheRange() throws {
  let answer = Answer()

  let exited = Logicctl.run(
    arguments: ["replay", "--help"], standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 0, "the help of a command is not a failure")
  #expect(answer.out.contains("--from"), "the help names the flags a person types")
  #expect(answer.out.contains("--to"))
  #expect(answer.out.contains("warning"), "and says that a range from the middle gets none")
}
