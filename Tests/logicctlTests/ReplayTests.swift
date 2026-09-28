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

/// A folder that stands in for the home folder of the person who runs a replay.
///
/// The suite never writes into the home folder of this Mac, and the fake Save panel walks the
/// folders of the disk, so the stand in is a folder of the test that is really there.
private func aHomeFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-home-\(UUID().uuidString)")
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

/// The project a replay starts in: one track, as `new-project` leaves it.
///
/// `new-project` answers the sheet that asks for the first track, so the project it makes holds
/// that track, and a replay starts in the same place. The steps of the recorded session are what
/// put the rest of the work back.
private func theProjectAReplayStartsIn() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Untitled"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// The track `new-project` leaves in the project it makes.
private let theFirstTrack = Track(index: 1, name: "Inst 1", type: .softwareInstrument)

/// The track that `tracks add --type software-instrument` makes beside it.
private let theSecondTrack = Track(index: 2, name: "Inst 2", type: .softwareInstrument)

/// The project that holds these tracks, open in Logic.
private func aProject(with tracks: [Track]) -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Untitled"),
    transport: Transport(tempo: 120),
    tracks: tracks)
}

/// The project Logic has open before the sheet is answered, which holds no track at all.
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

/// When the record of the work was saved, and when the replay of it saved a project of its own.
///
/// Two moments, because the project of a replay is saved while the replay runs. These are the two
/// the live run of phase 7 read: the record of the phase 2 session against a replay of it.
private let whenTheRecordWasSaved = Date(timeIntervalSince1970: 1_790_551_390)
private let whenTheReplaySaved = Date(timeIntervalSince1970: 1_790_552_640)

/// The project with one track in it, saved at one moment.
private func aProject(withTrackNamed name: String, savedAt moment: Date) -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Untitled", savedAt: moment),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: name, type: .softwareInstrument)])
}

/// What Logic called the new project when the work was recorded, and when it was replayed.
///
/// Logic names a new project "Untitled" and the first number the music folder has not taken, so
/// two runs on one Mac read two names for the same command. These are the two names the live run
/// of phase 7 read: the record of the phase 2 session against a replay of it.
private let theNameTheRecordRead = "Untitled 2"
private let theNameTheReplayRead = "Untitled 4"

/// The project a new project leaves, under one name.
private func aProject(named name: String) -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: name),
    transport: Transport(tempo: 120),
    tracks: [theFirstTrack])
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

  /// True while Logic shows the panel that asks where the project goes.
  var showsThePanel = false

  /// The folders the save route opened, from the root of the start up disk down.
  var walked: [String] = []

  /// What the save route wrote into each field of the panel.
  var written: [String: String] = [:]

  /// Every path this Logic wrote a project to.
  var savedTo: [String] = []

  /// The track whose header was pressed last, counted from 0.
  ///
  /// Logic removes the track that is selected, and nothing in the state of a project says which
  /// track that is, so the press on the header is the only record of it.
  var selected: Int?

  /// The chooser the command drives. Choosing the template opens the project and Logic asks for the
  /// first track of it, and Create answers that sheet, as Logic does.
  func chooser() -> ProjectChooser {
    ProjectChooser(
      read: { self.showing },
      press: { locator in
        if locator.name == Locators.chooserChooseButton.name {
          self.driver.state = anEmptyProject()
          self.driver.runningProcessID = self.processID
          self.showing = .emptyProject
          return
        }
        guard locator.name == Locators.newTrackCreateButton.name else {
          return
        }
        self.driver.state = theProjectAReplayStartsIn()
        self.showing = .project
      })
  }

  /// What makes, renames, mutes, solos and removes a track in this Logic.
  ///
  /// The mute and the solo buttons of a track header are check boxes, so a click turns the state
  /// over rather than setting it, which is what Logic 12.3.1 does with them.
  func actions() -> TrackActions {
    TrackActions(
      press: { locator in
        let made = NewTrackType.allCases.first {
          locator.name == TrackActions.menuItem(for: $0).name
        }
        if let made {
          self.addATrack(of: made)
          return
        }
        guard locator.name == TrackActions.deleteTrack.name else {
          return
        }
        self.removeTheSelectedTrack()
      },
      pressInWindow: { locator in
        self.selected = self.theTrack(withHeader: locator)
      },
      click: { locator in
        self.turnOver(locator)
      },
      write: { locator, text in
        self.write(text, into: locator)
      })
  }

  /// The Save panel this Logic shows.
  ///
  /// Pressing Save is what puts a file on disk, as it is in Logic, and it lands where the walk of
  /// the columns points with the name the field holds. So a test that reads the path afterwards
  /// reads what the press did, and a Logic that took the name alone would write every project to
  /// one folder.
  func panel() -> SaveDialog {
    SaveDialog(
      openTheMenuItem: { self.showsThePanel = true },
      showsThePanel: { self.showsThePanel },
      write: { locator, text in self.written[locator.name] = text },
      press: { locator in
        guard locator.name == Locators.saveButton.name else {
          return
        }
        let to = self.pathOfTheWalk(named: self.written[Locators.saveNameField.name] ?? "")
        try Data("the project of logicctl".utf8).write(
          to: URL(fileURLWithPath: to), options: .atomic)
        self.savedTo.append(to)
        self.showsThePanel = false
        self.driver.path = to
      },
      resolve: { $0 },
      namesInColumn: { number in
        try FileManager.default.contentsOfDirectory(atPath: self.folderOfTheWalk(cutTo: number))
      },
      openFolder: { number, name in
        self.walked = Array(self.walked.prefix(number)) + [name]
      },
      folderShown: { self.walked.last ?? "" },
      pressItem: { _ in self.walked = [] },
      startUpDisk: { "A Disk Of Its Own" },
      scroll: { _, _ in })
  }

  /// Adds one track under the tracks the project holds, as Logic does when the item is pressed.
  private func addATrack(of type: NewTrackType) {
    guard var state = driver.state else {
      return
    }
    let number = state.tracks.count + 1
    state.tracks.append(Track(index: number, name: "Inst \(number)", type: type.kind))
    driver.state = state
  }

  /// Removes the track whose header was pressed, and numbers what is left again, the way Logic
  /// numbers the tracks from the top of the window.
  private func removeTheSelectedTrack() {
    guard var state = driver.state, let number = selected,
      state.tracks.indices.contains(number)
    else {
      return
    }
    state.tracks.remove(at: number)
    for place in state.tracks.indices {
      state.tracks[place].index = place + 1
    }
    driver.state = state
    selected = nil
  }

  /// Turns the mute or the solo of one track over, whichever check box the click reached.
  private func turnOver(_ locator: Locator) {
    guard var state = driver.state else {
      return
    }
    for number in state.tracks.indices {
      if locator.name == Locators.trackMuteButton(number: number).name {
        state.tracks[number].mute.toggle()
      } else if locator.name == Locators.trackSoloButton(number: number).name {
        state.tracks[number].solo.toggle()
      } else {
        continue
      }
      driver.state = state
      return
    }
  }

  /// Gives one track the name the rename wrote into the field of its header.
  private func write(_ text: String, into locator: Locator) {
    guard var state = driver.state,
      let number = state.tracks.indices.first(where: {
        locator.name == Locators.trackNameField(number: $0).name
      })
    else {
      return
    }
    state.tracks[number].name = text
    driver.state = state
  }

  /// The track one header belongs to, counted from 0.
  private func theTrack(withHeader locator: Locator) -> Int? {
    guard let state = driver.state else {
      return nil
    }
    return state.tracks.indices.first { locator.name == Locators.trackHeader(number: $0).name }
  }

  /// The folder the walk reached, cut to the first folders of it.
  private func folderOfTheWalk(cutTo number: Int) -> String {
    "/" + walked.prefix(number).joined(separator: "/")
  }

  /// Where the panel writes the project: the folder the walk reached, and the name in the field.
  private func pathOfTheWalk(named name: String) -> String {
    folderOfTheWalk(cutTo: walked.count) + (walked.isEmpty ? "" : "/") + name
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

  /// A runner that repeats the work on a project of its own, which it saves at another moment.
  ///
  /// The project of a replay is made while the replay runs, so the time of its save is the moment
  /// of the replay and never the moment the record carries. `leaving` names one step that also
  /// leaves another track name, which is work that differs and not a clock.
  func aRunnerThatSaves(
    at moment: Date, leaving name: String? = nil, atStep drifting: Int = 0
  ) -> SessionReplay.Runner {
    { (step: RecordedStep) -> ReplayRun in
      guard var state = self.left[step.seq] else {
        return ReplayRun.noSuchCommand
      }
      state.project.savedAt = moment
      if let name, step.seq == drifting {
        state.tracks[0].name = name
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
  try recorded.wrote(
    .command, command: "new-project", leaving: theProjectAReplayStartsIn())
  try recorded.wrote(
    .command, command: "midi notes", argv: ["--track", "1", "--region", "1"],
    leaving: theProjectAReplayStartsIn())

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

/// A replay answers on the work a person did, and never on the clock.
///
/// `project.savedAt` is the time Logic last wrote the project file. A replay builds a second
/// project and saves that one while it runs, so the time it reads is the moment of the replay,
/// while the record carries the moment of the work. The two are never the same. A comparison that
/// read the field would answer a difference at every step of every session, so a person who
/// replays a session to learn whether the work repeats would be told no every time, about the one
/// field nobody changed.
///
/// So the save time is out of the comparison, on both sides, and nothing else is. A track that
/// came back with another name is the answer a replay exists to give, and it still fails the
/// replay with the field named. The journal keeps the time: every state records it and every hash
/// reads it, because a person who compares the two histories afterwards needs to know when each
/// project was saved.
@Test func replayLeavesTheSaveTimeOutOfTheComparison() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try Recording(root: root, git: git)
  try recorded.wrote(
    .command, command: "tracks add", argv: ["--type", "software-instrument"],
    leaving: aProject(withTrackNamed: "Inst 1", savedAt: whenTheRecordWasSaved))
  try recorded.wrote(
    .command, command: "tracks rename", argv: ["--index", "1", "--name", "Bass"],
    leaving: aProject(withTrackNamed: "Bass", savedAt: whenTheRecordWasSaved))

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    chooser: logic.chooser(),
    driver: logic.driver,
    runner: recorded.aRunnerThatSaves(at: whenTheReplaySaved),
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 0, "the work repeated, so the replay exits 0 whatever the clock says")
  #expect(answer.err.isEmpty, "and nobody is told about a difference")
  let report = try answer.data()
  #expect(
    (report["differences"] as? [[String: Any]])?.isEmpty == true,
    "the time of a save is not a field of the work")
  #expect((report["skipped"] as? [[String: Any]])?.isEmpty == true, "nothing was passed over")
  #expect(report["stepsRun"] as? Int == 2, "both steps of the session ran again")

  let session = try #require(report["session"] as? String)
  let written = try #require(folder(ofSessionWithId: session, underRoot: root))
  let recordedState = try readJSON(at: written.appending(path: "state.json"))
  let held = try #require(State(json: recordedState))
  #expect(
    held.project.savedAt == whenTheReplaySaved,
    "and the state the replay recorded still carries the time it read")
  let wrote = try readJSON(at: written.appending(path: "steps/000001/step.json"))
  let check = try #require(members(of: wrote))
  #expect(
    check["differences"] == JSONValue.array([]),
    "so the check of that step records the nothing the comparison found")

  let anotherMac = Mac()
  let laterClock = Time()
  let drifted = Answer()

  let failed = Replay.answer(
    session: recorded.id,
    chooser: anotherMac.chooser(),
    driver: anotherMac.driver,
    runner: recorded.aRunnerThatSaves(at: whenTheReplaySaved, leaving: "Lead", atStep: 2),
    root: root,
    limitMs: 500,
    clock: laterClock.read,
    sleeper: laterClock.sleep,
    git: git,
    standardOutput: drifted.write,
    standardError: drifted.writeError)

  #expect(failed == 15, "a track that came back with another name still fails the replay")
  #expect(
    try drifted.failure()["message"] as? String
      == "Replay skipped 0 steps and found 1 differences",
    "and the count is of the work that differs, not of the saves")
  let secondReport = try drifted.report()
  let found = try #require(secondReport["differences"] as? [[String: Any]])
  #expect(found.count == 1, "one step of the session left another project")
  #expect(found.first?["seq"] as? Int == 2, "the step that renamed the track")
  let fields = try #require(found.first?["differences"] as? [[String: Any]])
  #expect(fields.count == 1, "and one field of it, the name and not the save")
  #expect(fields.first?["path"] as? String == "/tracks/0/name", "which field, as a pointer")
  #expect(fields.first?["before"] as? String == "Bass", "what the session recorded")
  #expect(fields.first?["after"] as? String == "Lead", "and what the replay left")
}

/// A replay repeats the work of a session, and the work of a session is its commands.
///
/// This is the promise of a replay, and a runner that repeated one command of the tool never kept
/// it. The phase 2 session holds five steps: the new project, a save, two readings of the tracks
/// and the track it added. Four of those came back as `no_such_command`, so the replay exited 15
/// and said that a session of ordinary work could not be repeated. Nothing was wrong with the
/// work.
///
/// So every command the record can carry runs again, with the arguments the record carries, on the
/// project the replay made. A person replays a morning of work and reads one answer about the
/// whole of it.
///
/// A recorded save is the one command that is not repeated as it was typed. The path in the record
/// is the project of a person, and hours of work sit in it that nothing brings back, so the replay
/// saves into a folder of its own and keeps the file name alone. The project of the record is
/// never opened, never written to, and never removed.
@Test func replayRunsTheTrackCommandsAndSave() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let home = try aHomeFolder()
  defer { try? FileManager.default.removeItem(at: home) }
  let git = try gitThatSigns(inside: root)

  let recorded = try Recording(root: root, git: git)
  try recorded.wrote(.command, command: "new-project", leaving: theProjectAReplayStartsIn())
  try recorded.wrote(
    .command, command: "save", argv: ["--path", "/some/where/Phase2.logicx"],
    leaving: theProjectAReplayStartsIn())
  try recorded.wrote(.command, command: "tracks list", leaving: theProjectAReplayStartsIn())
  try recorded.wrote(
    .command, command: "tracks add", argv: ["--type", "software-instrument"],
    leaving: aProject(with: [theFirstTrack, theSecondTrack]))
  try recorded.wrote(
    .command, command: "tracks list", leaving: aProject(with: [theFirstTrack, theSecondTrack]))

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    chooser: logic.chooser(),
    driver: logic.driver,
    actions: logic.actions(),
    dialog: logic.panel(),
    home: home,
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 0, "every step of the phase 2 session ran again and repeated the work")
  #expect(answer.err.isEmpty, "so nobody is told that a step was passed over")
  let report = try answer.report()
  #expect((report["skipped"] as? [[String: Any]])?.isEmpty == true, "nothing was passed over")
  #expect((report["differences"] as? [[String: Any]])?.isEmpty == true, "and nothing differed")
  #expect(report["stepsRun"] as? Int == 5, "the five steps of the session ran")
  let built = try logic.driver.readState()
  #expect(
    built.tracks == [theFirstTrack, theSecondTrack],
    "and the track the session added is in the project the replay built")

  let saved = try #require(logic.savedTo.first, "the recorded save ran")
  #expect(logic.savedTo.count == 1, "once, because the session holds one save")
  #expect(saved.hasPrefix(home.path + "/"), "the replay saved under a folder of its own")
  #expect(
    URL(fileURLWithPath: saved).lastPathComponent == "Phase2.logicx",
    "under the file name the record carries")
  #expect(FileManager.default.fileExists(atPath: saved), "and the project is on disk there")
  #expect(
    !FileManager.default.fileExists(atPath: "/some/where/Phase2.logicx"),
    "and nothing was written where the record points")

  let renamed = Track(index: 2, name: "Bass", type: .softwareInstrument)
  let muted = Track(index: 2, name: "Bass", type: .softwareInstrument, mute: true)
  let soloed = Track(index: 1, name: "Inst 1", type: .softwareInstrument, solo: true)

  let more = try Recording(root: root, git: git)
  try more.wrote(.command, command: "new-project", leaving: theProjectAReplayStartsIn())
  try more.wrote(
    .command, command: "tracks add", argv: ["--type", "software-instrument"],
    leaving: aProject(with: [theFirstTrack, theSecondTrack]))
  try more.wrote(
    .command, command: "tracks rename", argv: ["--index", "2", "--name", "Bass"],
    leaving: aProject(with: [theFirstTrack, renamed]))
  try more.wrote(
    .command, command: "tracks mute", argv: ["--index", "2", "--on"],
    leaving: aProject(with: [theFirstTrack, muted]))
  try more.wrote(
    .command, command: "tracks solo", argv: ["--index", "1", "--on"],
    leaving: aProject(with: [soloed, muted]))
  try more.wrote(
    .command, command: "tracks delete", argv: ["--index", "2"],
    leaving: aProject(with: [soloed]))

  let secondMac = Mac()
  let secondClock = Time()
  let secondAnswer = Answer()

  let ranTheRest = Replay.answer(
    session: more.id,
    chooser: secondMac.chooser(),
    driver: secondMac.driver,
    actions: secondMac.actions(),
    dialog: secondMac.panel(),
    home: home,
    root: root,
    limitMs: 500,
    clock: secondClock.read,
    sleeper: secondClock.sleep,
    git: git,
    standardOutput: secondAnswer.write,
    standardError: secondAnswer.writeError)

  #expect(ranTheRest == 0, "the rename, the mute, the solo and the delete run again too")
  let rest = try secondAnswer.report()
  #expect((rest["skipped"] as? [[String: Any]])?.isEmpty == true, "none of them was passed over")
  #expect((rest["differences"] as? [[String: Any]])?.isEmpty == true)
  #expect(rest["stepsRun"] as? Int == 6, "the six steps of that session ran")
  let left = try secondMac.driver.readState()
  #expect(left.tracks == [soloed], "and the project the replay built holds what the work left")

  let later = try Recording(root: root, git: git)
  try later.wrote(.command, command: "new-project", leaving: theProjectAReplayStartsIn())
  try later.wrote(
    .command, command: "midi notes", argv: ["--track", "1", "--region", "1"],
    leaving: theProjectAReplayStartsIn())

  let thirdMac = Mac()
  let thirdClock = Time()
  let thirdAnswer = Answer()

  let skippedOne = Replay.answer(
    session: later.id,
    chooser: thirdMac.chooser(),
    driver: thirdMac.driver,
    actions: thirdMac.actions(),
    dialog: thirdMac.panel(),
    home: home,
    root: root,
    limitMs: 500,
    clock: thirdClock.read,
    sleeper: thirdClock.sleep,
    git: git,
    standardOutput: thirdAnswer.write,
    standardError: thirdAnswer.writeError)

  #expect(skippedOne == 15, "a command this build does not have still fails the replay")
  let held = try thirdAnswer.report()
  let passedOver = try #require(held["skipped"] as? [[String: Any]])
  #expect(passedOver.count == 1, "and it is the one step of that session")
  #expect(passedOver.first?["seq"] as? Int == 2)
  #expect(passedOver.first?["reason"] as? String == "no_such_command")
  #expect(held["stepsRun"] as? Int == 1, "the new project is what this build repeated")

  let odd = try Recording(root: root, git: git)
  try odd.wrote(.command, command: "new-project", leaving: theProjectAReplayStartsIn())
  try odd.wrote(
    .command, command: "tracks add", argv: ["--type", "drummer"],
    leaving: theProjectAReplayStartsIn())

  let fourthMac = Mac()
  let fourthClock = Time()
  let fourthAnswer = Answer()

  let stopped = Replay.answer(
    session: odd.id,
    chooser: fourthMac.chooser(),
    driver: fourthMac.driver,
    actions: fourthMac.actions(),
    dialog: fourthMac.panel(),
    home: home,
    root: root,
    limitMs: 500,
    clock: fourthClock.read,
    sleeper: fourthClock.sleep,
    git: git,
    standardOutput: fourthAnswer.write,
    standardError: fourthAnswer.writeError)

  #expect(stopped == 70, "a recorded argument this build cannot read stops the replay")
  #expect(
    try fourthAnswer.failure()["code"] as? String == "internal",
    "and it is named as a failure of logicctl, never as a clean run")
}

/// A replay of a session that holds a save can finish.
///
/// The Save panel of Logic walks the folders of the path one column at a time, and it lists no
/// column for `/var`. The temporary folder of macOS is under `/var`, so a save that points there
/// stops with `timeout` and writes nothing. The live run of the journal read exactly that: the
/// replay made its project, then the recorded save waited for a column that names `var` and never
/// got one.
///
/// So a replay saves under the home folder, which the first column of the panel lists, in a folder
/// named for the replay. Two replays still never write to one path, because the name of that
/// folder is the id of the session the replay records its own work in. Nothing else of the save
/// changes: the path of the record is never written to, and the file name of the record is kept.
@Test func replaySavesIntoAFolderTheSavePanelLists() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let home = try aHomeFolder()
  defer { try? FileManager.default.removeItem(at: home) }
  let git = try gitThatSigns(inside: root)

  let recorded = try Recording(root: root, git: git)
  try recorded.wrote(.command, command: "new-project", leaving: theProjectAReplayStartsIn())
  try recorded.wrote(
    .command, command: "save", argv: ["--path", "/some/where/Phase2.logicx"],
    leaving: theProjectAReplayStartsIn())

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    chooser: logic.chooser(),
    driver: logic.driver,
    actions: logic.actions(),
    dialog: logic.panel(),
    home: home,
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 0, "the recorded save ran again and the replay repeated the work")
  let meta = try answer.meta()
  let replaySession = try #require(
    meta["session"] as? String, "the answer names the session the replay wrote")
  let saved = try #require(logic.savedTo.first, "and Logic wrote a project")
  #expect(logic.savedTo.count == 1, "once, because the session holds one save")

  let replays = home.appendingPathComponent("logicctl-replays")
  let folder = replays.appendingPathComponent(replaySession)
  #expect(
    saved == folder.appendingPathComponent("Phase2.logicx").path,
    "under the home folder, which the Save panel lists, in a folder named for the replay")
  #expect(FileManager.default.fileExists(atPath: saved), "and the project is on disk there")

  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-replay-" + replaySession)
  #expect(
    !FileManager.default.fileExists(atPath: temporary.path),
    "nothing went under the temporary folder, where the panel cannot walk: \(temporary.path)")
  #expect(
    !FileManager.default.fileExists(atPath: "/some/where/Phase2.logicx"),
    "and nothing was written where the record points")
}

/// A replay answers on the work a person did, and never on the name Logic picked for a new project.
///
/// Logic names a new project "Untitled" and the first number the music folder has not taken. The
/// number depends on what that folder holds at the moment the project is made, so the record of a
/// morning reads "Untitled 2" and a replay of it reads "Untitled 4". Nobody did anything
/// different. A comparison that read the name after a new project would answer a difference at
/// the first step of every session, and a person who replays a session to learn whether the work
/// repeats would be told no every time, about a number the music folder chose.
///
/// So the name is out of the comparison after a new project, on both sides, and after nothing
/// else. After a save the name is the name of the file, which is work: a project that came back
/// under another name there means the save did not put it where the record says, and that still
/// fails the replay with the field named. The journal keeps the name: every state records it and
/// every hash reads it.
@Test func replayLeavesTheNameOfANewProjectOutOfTheComparison() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)

  let recorded = try Recording(root: root, git: git)
  try recorded.wrote(
    .command, command: "new-project", leaving: aProject(named: theNameTheRecordRead))
  try recorded.wrote(
    .command, command: "save", argv: ["--path", "/some/where/Phase2.logicx"],
    leaving: aProject(named: "Phase2"))

  let logic = Mac()
  let time = Time()
  let answer = Answer()

  let exited = Replay.answer(
    session: recorded.id,
    chooser: logic.chooser(),
    driver: logic.driver,
    runner: recorded.aRunnerThatLeaves(aProject(named: theNameTheReplayRead), atStep: 1),
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 0, "the work repeated, so the replay exits 0 whatever the music folder holds")
  #expect(answer.err.isEmpty, "and nobody is told about a difference")
  let report = try answer.data()
  #expect(
    (report["differences"] as? [[String: Any]])?.isEmpty == true,
    "the number Logic put after Untitled is not a field of the work")
  #expect((report["skipped"] as? [[String: Any]])?.isEmpty == true, "nothing was passed over")
  #expect(report["stepsRun"] as? Int == 2, "both steps of the session ran again")

  let session = try #require(report["session"] as? String)
  let written = try #require(folder(ofSessionWithId: session, underRoot: root))
  let recordedState = try readJSON(at: written.appending(path: "state.json"))
  let held = try #require(State(json: recordedState))
  #expect(
    held.project.name == "Phase2",
    "and the state the replay recorded still carries the name it read")
  let wrote = try readJSON(at: written.appending(path: "steps/000001/step.json"))
  let check = try #require(members(of: wrote))
  #expect(
    check["differences"] == JSONValue.array([]),
    "so the check of the new project records the nothing the comparison found")

  let anotherMac = Mac()
  let laterClock = Time()
  let drifted = Answer()

  let failed = Replay.answer(
    session: recorded.id,
    chooser: anotherMac.chooser(),
    driver: anotherMac.driver,
    runner: recorded.aRunnerThatLeaves(aProject(named: theNameTheReplayRead), atStep: 2),
    root: root,
    limitMs: 500,
    clock: laterClock.read,
    sleeper: laterClock.sleep,
    git: git,
    standardOutput: drifted.write,
    standardError: drifted.writeError)

  #expect(failed == 15, "a project that came back under another name after a save fails the replay")
  #expect(
    try drifted.failure()["message"] as? String
      == "Replay skipped 0 steps and found 1 differences",
    "and the count is of the work that differs, not of the new project")
  let secondReport = try drifted.report()
  let found = try #require(secondReport["differences"] as? [[String: Any]])
  #expect(found.count == 1, "one step of the session left another project")
  #expect(found.first?["seq"] as? Int == 2, "the step that saved it")
  let fields = try #require(found.first?["differences"] as? [[String: Any]])
  #expect(fields.count == 1, "and one field of it, the name after the save")
  #expect(fields.first?["path"] as? String == "/project/name", "which field, as a pointer")
  #expect(fields.first?["before"] as? String == "Phase2", "what the session recorded")
  #expect(fields.first?["after"] as? String == theNameTheReplayRead, "and what the replay left")
}
