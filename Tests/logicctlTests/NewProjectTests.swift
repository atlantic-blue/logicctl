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
    .appendingPathComponent("logicctl-new-project-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A git whose configuration signs every commit, with a signing program that always fails.
///
/// A session repository turns signing off for itself, so a commit of logicctl never waits for a
/// key and never claims that a person signed it. No test reads or writes the configuration of the
/// operator.
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

  /// The `meta` of the answer.
  func meta() throws -> [String: Any] {
    try printed()["meta"] as? [String: Any] ?? [:]
  }
}

/// A picture of the window of Logic, which the pipeline has no window server to take.
private struct APicture: WindowCapturer {
  let bytes: Data

  func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    bytes
  }
}

/// The track the sheet makes for its own defaults, which are one Software Instrument track.
private func theTrackTheSheetMakes() -> Track {
  Track(index: 1, name: "Inst 1", type: .softwareInstrument)
}

/// The Logic a test drives: what it shows, and what it has open behind that.
///
/// It starts where a person starts, with the chooser in front and no project open at all, so every
/// read the command makes of the project is a read of what the route itself produced.
private final class Mac {
  /// What Logic shows in front.
  var showing: ProjectWindow? = .chooser

  /// The elements the command pressed, in the order it pressed them.
  var pressed: [String] = []

  /// The Logic the command reads the project through. It refuses until the project exists.
  let driver = FakeLogicDriver()

  /// The tracks the sheet makes when Create is pressed.
  let tracksCreateMakes: [Track]

  /// The process this Logic runs as, which is the Logic the picture is taken of.
  let processID: Int32 = 981

  init(tracksCreateMakes: [Track] = [theTrackTheSheetMakes()]) {
    self.tracksCreateMakes = tracksCreateMakes
  }

  /// The chooser the command drives. Choosing the template opens the project and Logic asks for the
  /// first track of it, and Create answers that sheet, as Logic does.
  func chooser() -> ProjectChooser {
    ProjectChooser(
      read: { self.showing },
      press: { locator in
        self.pressed.append(locator.name)
        if locator.name == Locators.chooserChooseButton.name {
          self.driver.state = self.project(holding: [])
          self.driver.runningProcessID = self.processID
          self.showing = .emptyProject
          return
        }
        guard locator.name == Locators.newTrackCreateButton.name else {
          return
        }
        self.driver.state = self.project(holding: self.tracksCreateMakes)
        self.showing = self.tracksCreateMakes.isEmpty ? .emptyProject : .project
      })
  }

  /// The project Logic has open, holding these tracks.
  private func project(holding tracks: [Track]) -> State {
    State(
      logic: LogicVersion(version: "12.3.1"),
      project: Project(name: "Untitled"),
      transport: Transport(tempo: 120),
      tracks: tracks)
  }
}

/// A person or an agent gets a new project with one command, and everything they do to it from that
/// moment is written down.
///
/// Logic asks for the first track of a project it has just made, and it refuses Save until that
/// sheet is answered. So the command answers it: the project a person is left with holds the one
/// Software Instrument track the sheet makes, and Logic will save it. The session is the record of
/// the work: it exists before the first change, so no command of logicctl on this project is ever
/// unrecorded, and its first commit says `createdByLogicctl` true. That one field is what lets
/// every later command change this project without `--confirm`, and it is what makes the same
/// command stop on a project a person made. The answer carries the session and the folder it sits
/// in, so a person reads the history of their work without going to look for it.
///
/// A Logic that never reaches that project is the other half of the promise. The command reads the
/// project back rather than trusting the press, so a Create that makes no track fails with
/// `timeout`, which exits 6, and no session is started for it. A session that recorded a project
/// with a track it does not have would replay into a different project.
@Test func newProjectStartsASession() throws {
  let typed = try Logicctl.parseAsRoot(["new-project"])
  #expect(typed is NewProject, "a person can type logicctl new-project")

  let root = try temporaryFolder()
  let git = try gitThatSigns(inside: root)
  let logic = Mac()
  let time = Time()
  let made = Answer()

  let exited = NewProject.answer(
    chooser: logic.chooser(),
    driver: logic.driver,
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    capturer: APicture(bytes: Data("a window".utf8)),
    standardOutput: made.write,
    standardError: made.writeError)

  #expect(exited == 0)
  #expect(made.err.isEmpty, "standard error is empty on success")
  #expect(made.out.filter(\.isNewline).count == 1, "one JSON object and a newline")
  #expect(
    logic.pressed == [
      Locators.chooserEmptyProjectTile.name, Locators.chooserChooseButton.name,
      Locators.newTrackCreateButton.name,
    ],
    "the command opened the empty project template, answered the sheet, and pressed nothing else")

  let state = try logic.driver.readState()
  #expect(
    state.tracks == [theTrackTheSheetMakes()],
    "the project a person is left with holds the track the sheet makes")

  let answered = try made.data()
  let project = answered["project"] as? [String: Any]
  #expect(project?["name"] as? String == "Untitled")
  #expect(project?["path"] is NSNull, "a project has no path until it is saved")

  let session = try #require(answered["session"] as? String, "the answer names the session")
  let folder = try #require(answered["repository"] as? String, "and where it sits")
  let meta = try made.meta()
  #expect(meta["session"] as? String == session)
  let step = try #require(meta["step"] as? String, "the command wrote its own step")
  #expect(meta["externalChange"] is NSNull, "nothing was changed by hand before the first command")

  let repository = URL(fileURLWithPath: folder)
  let onDisk = try readJSON(at: repository.appendingPathComponent("session.json"))
  let recorded = try #require(Session(json: onDisk))
  #expect(recorded.id == session, "the session of the answer is the session on disk")
  #expect(recorded.project.createdByLogicctl, "logicctl made this project")
  #expect(recorded.project.name == "Untitled")
  #expect(recorded.project.path == nil, "the project has not been saved anywhere yet")

  let history = try git.run(["log", "--format=%H %s"], in: repository)
    .split(whereSeparator: \.isNewline)
    .map(String.init)
  #expect(history.count == 2, "the session was started, and the command wrote one step")
  #expect(history.first?.hasPrefix(step) == true, "the step of the answer is the commit on top")
  #expect(history.first?.hasSuffix("1 new-project") == true)
  #expect(history.last?.hasSuffix("session " + recorded.shortId) == true)

  let written = try readJSON(at: repository.appendingPathComponent("state.json"))
  let tracks = members(of: written)?["tracks"]
  #expect(
    tracks == JSONValue.array([theTrackTheSheetMakes().json]),
    "the session recorded the project as it is, with the track the sheet made")

  let kept = repository.appendingPathComponent("steps/000001")
  let wrote = try readJSON(at: kept.appendingPathComponent("step.json"))
  let fields = try #require(members(of: wrote))
  #expect(fields["command"] == JSONValue.string("new-project"))
  #expect(fields["kind"] == JSONValue.string("command"))
  #expect(fields["exitCode"] == JSONValue.number(0))
  #expect(fields["stateBefore"] == JSONValue.null, "there was no project before this command")
  #expect(fields["stateAfter"] == JSONValue.string(CanonicalJSON.sha256(of: state)))
  #expect(
    fields["screenshot"] == JSONValue.string("screenshot.png"), "every step keeps a picture")
  #expect(
    FileManager.default.fileExists(atPath: kept.appendingPathComponent("screenshot.png").path),
    "and the picture is in the commit")

  #expect(
    stepNamedInTheRecordedEnvelope(fields["envelope"]) == nil,
    "the step keeps the envelope that was printed, and a commit cannot name itself")

  // A Logic where Create makes no track never reaches the project this command promises.
  let otherRoot = try temporaryFolder()
  let otherGit = try gitThatSigns(inside: otherRoot)
  let busy = Mac(tracksCreateMakes: [])
  let otherTime = Time()
  let refused = Answer()

  let failed = NewProject.answer(
    chooser: busy.chooser(),
    driver: busy.driver,
    root: otherRoot,
    limitMs: 200,
    clock: otherTime.read,
    sleeper: otherTime.sleep,
    git: otherGit,
    capturer: APicture(bytes: Data("a window".utf8)),
    standardOutput: refused.write,
    standardError: refused.writeError)

  #expect(failed == 6, "timeout exits 6")
  #expect(refused.err.hasPrefix("logicctl: timeout: "))
  let stopped = try refused.printed()
  #expect(stopped["data"] is NSNull)
  #expect((stopped["error"] as? [String: Any])?["code"] as? String == "timeout")
  let none = try refused.meta()
  #expect(none["session"] is NSNull, "a project with no track starts no session")
  #expect(none["step"] is NSNull)
  let sessions = SessionRepository.sessionsFolder(underRoot: otherRoot)
  let left = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
  #expect(left.isEmpty, "and nothing was written for it")
}

/// The Logic of a person: a project they made, open in front, with their work in it.
///
/// This is the Mac the measured run of 2026-09-27 found. Logic shows a project, so the route of
/// the chooser has nothing to press, and everything the command reads is the project of the person
/// rather than a project it made.
private func theLogicOfAPerson(savedAt path: String?) -> Mac {
  let logic = Mac()
  logic.showing = .project
  logic.driver.state = State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "F-T13"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Deluxe Classic", type: .softwareInstrument)])
  logic.driver.path = path
  logic.driver.runningProcessID = logic.processID
  return logic
}

/// A project a person made stays theirs, and `new-project` never takes it over.
///
/// `createdByLogicctl` is the one field that tells a project logicctl made from a project a person
/// made, and it is the field the guard reads before any later command changes a project without
/// `--confirm`. This command is the only thing that ever writes it true. So a `new-project` that
/// found the work of a person already open, and started a session over it, would hand logicctl the
/// run of that work from the first command they typed, and say nothing about it.
///
/// The command reads what Logic shows before it presses anything. A project in front is a refusal.
/// It names the project, and the path when the project has one, so the person reads which project
/// it means and quits it. It presses nothing, so Logic is as they left it, and it writes no
/// session, so nothing on disk claims their work. A project they never saved is refused the same
/// way, because a session over one of those is the same claim over the same work.
///
/// The refusal takes nothing from the route this command exists for. A Logic showing the chooser
/// still gets a project, a first track, and a session that says logicctl made it.
@Test func newProjectRefusesWhileLogicShowsAProject() throws {
  let root = try temporaryFolder()
  let git = try gitThatSigns(inside: root)
  let theirs = theLogicOfAPerson(savedAt: "/private/tmp/F-T13.logicx")
  let time = Time()
  let refused = Answer()

  let exited = NewProject.answer(
    chooser: theirs.chooser(),
    driver: theirs.driver,
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    capturer: APicture(bytes: Data("a window".utf8)),
    standardOutput: refused.write,
    standardError: refused.writeError)

  #expect(exited == 2, "invalid_argument exits 2")
  #expect(
    refused.err.hasPrefix("logicctl: invalid_argument: "),
    "standard error carries the one line a person reads")
  let stopped = try refused.printed()
  #expect(stopped["data"] is NSNull, "the command answered no project, because it made none")
  let failure = try #require(stopped["error"] as? [String: Any])
  #expect(failure["code"] as? String == "invalid_argument")
  let said = try #require(failure["message"] as? String)
  #expect(said.contains("F-T13"), "the refusal names the project the person has open")
  #expect(said.contains("/private/tmp/F-T13.logicx"), "and where it sits, so they know which")
  let details = failure["details"] as? [String: Any]
  #expect(
    details?["project"] as? String == "/private/tmp/F-T13.logicx",
    "the path is in the details too, for whatever reads the answer")

  #expect(theirs.pressed.isEmpty, "nothing was pressed, so their project is as they left it")
  #expect(theirs.showing == ProjectWindow.project, "and it is still what Logic shows")

  let none = try refused.meta()
  #expect(none["session"] is NSNull, "no session was started over a project logicctl did not make")
  #expect(none["step"] is NSNull)
  let sessions = SessionRepository.sessionsFolder(underRoot: root)
  let left = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
  #expect(left.isEmpty, "and nothing on disk claims it")

  // A project a person never saved is the same work under the same claim, so it is refused too.
  let unsavedRoot = try temporaryFolder()
  let unsavedGit = try gitThatSigns(inside: unsavedRoot)
  let unsaved = theLogicOfAPerson(savedAt: nil)
  let unsavedTime = Time()
  let alsoRefused = Answer()

  let stoppedToo = NewProject.answer(
    chooser: unsaved.chooser(),
    driver: unsaved.driver,
    root: unsavedRoot,
    limitMs: 500,
    clock: unsavedTime.read,
    sleeper: unsavedTime.sleep,
    git: unsavedGit,
    capturer: APicture(bytes: Data("a window".utf8)),
    standardOutput: alsoRefused.write,
    standardError: alsoRefused.writeError)

  #expect(stoppedToo == 2, "a project they never saved is refused the same way")
  let answeredAgain = try alsoRefused.printed()
  let refusal = try #require(answeredAgain["error"] as? [String: Any])
  #expect(refusal["code"] as? String == "invalid_argument")
  #expect(
    (refusal["message"] as? String)?.contains("F-T13") == true,
    "a project with no path is still named by what Logic calls it")
  #expect(unsaved.pressed.isEmpty)
  let overThere = SessionRepository.sessionsFolder(underRoot: unsavedRoot)
  let wrote = (try? FileManager.default.contentsOfDirectory(atPath: overThere.path)) ?? []
  #expect(wrote.isEmpty, "and no session was written for that one either")

  // The refusal takes nothing away from the route this command exists for.
  let ownRoot = try temporaryFolder()
  let ownGit = try gitThatSigns(inside: ownRoot)
  let waiting = Mac()
  let ownTime = Time()
  let made = Answer()

  let answered = NewProject.answer(
    chooser: waiting.chooser(),
    driver: waiting.driver,
    root: ownRoot,
    limitMs: 500,
    clock: ownTime.read,
    sleeper: ownTime.sleep,
    git: ownGit,
    capturer: APicture(bytes: Data("a window".utf8)),
    standardOutput: made.write,
    standardError: made.writeError)

  #expect(answered == 0, "a Logic showing the chooser still gets a project")
  #expect(
    waiting.pressed == [
      Locators.chooserEmptyProjectTile.name, Locators.chooserChooseButton.name,
      Locators.newTrackCreateButton.name,
    ],
    "by the route it always took")
  let gained = try made.data()
  let folder = try #require(gained["repository"] as? String, "the answer says where it sits")
  let onDisk = try readJSON(
    at: URL(fileURLWithPath: folder).appendingPathComponent("session.json"))
  let recorded = try #require(Session(json: onDisk))
  #expect(recorded.project.createdByLogicctl, "logicctl made this one, and the session says so")
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

/// The commit that the envelope kept in a step names as its own step.
private func stepNamedInTheRecordedEnvelope(_ envelope: JSONValue?) -> String? {
  guard let meta = members(of: members(of: envelope)?["meta"]) else {
    return nil
  }
  guard case .string(let step) = meta["step"] ?? JSONValue.null else {
    return nil
  }
  return step
}

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

/// logicctl reads what Logic shows from the window, and never from its title.
///
/// The route of `new-project` turns on that one reading: a chooser gets the empty project template
/// pressed, a project with the sheet on it gets Create pressed, and a project with tracks is the
/// answer the command was asked for. A title would say none of the three in a Logic of another
/// language, and the name of a project a person opened could say anything at all. So each one is
/// read from an element the window carries, and these are the trees that Logic wrote for each one.
@Test func theWindowOfLogicSaysWhatItShows() throws {
  #expect(try whatLogicShows(in: "project-chooser.json") == ProjectWindow.chooser)
  #expect(
    try whatLogicShows(in: "new-project-sheet.json") == ProjectWindow.emptyProject,
    "Logic asks for a track on the project it has just made, and that project has none")
  #expect(
    try whatLogicShows(in: "empty.json") == ProjectWindow.emptyProject,
    "and it asks again once the last track of a project is deleted")
  #expect(try whatLogicShows(in: "one-track.json") == ProjectWindow.project)
  #expect(try whatLogicShows(in: "region.json") == ProjectWindow.project)
}

/// What one recorded tree of Logic shows.
private func whatLogicShows(in file: String) throws -> ProjectWindow {
  let tree = try RecordedTree(contentsOf: fixtureFolder.appending(path: file))
  return ProjectChooser.window(showing: tree.root)
}
