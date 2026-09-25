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

  /// The tracks the project has when Logic opens it.
  let tracksOnOpening: [Track]

  init(tracksOnOpening: [Track] = []) {
    self.tracksOnOpening = tracksOnOpening
  }

  /// The chooser the command drives. Choosing the template opens the project, as Logic does.
  func chooser() -> ProjectChooser {
    ProjectChooser(
      read: { self.showing },
      press: { locator in
        self.pressed.append(locator.name)
        guard locator.name == Locators.chooserChooseButton.name else {
          return
        }
        self.driver.state = State(
          logic: LogicVersion(version: "12.3.1"),
          project: Project(name: "Untitled"),
          transport: Transport(tempo: 120),
          tracks: self.tracksOnOpening)
        self.showing = .emptyProject
      })
  }
}

/// A person or an agent gets a new, empty project with one command, and everything they do to it
/// from that moment is written down.
///
/// The project has no tracks, so the work that follows starts from nothing and a replay of the
/// session gives the same result. The session is the record of that work: it exists before the
/// first change, so no command of logicctl on this project is ever unrecorded, and its first
/// commit says `createdByLogicctl` true. That one field is what lets every later command change
/// this project without `--confirm`, and it is what makes the same command stop on a project a
/// person made. The answer carries the session and the folder it sits in, so a person reads the
/// history of their work without going to look for it.
///
/// A Logic that opens something other than an empty project is the other half of the promise. The
/// command reads the project back rather than trusting the press, so a project that came up with a
/// track in it fails with `timeout`, which exits 6, and no session is started for it. A session
/// that recorded a project as empty when it was not would replay into a different project.
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
    logic.pressed == [Locators.chooserEmptyProjectTile.name, Locators.chooserChooseButton.name],
    "the command took the empty project template and opened it, and pressed nothing else")

  let state = try logic.driver.readState()
  #expect(state.tracks.isEmpty, "the project a person is left with has no tracks")

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
    tracks == JSONValue.array([]), "the session recorded the project as it is, with no tracks")

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

  // A Logic that opens a project with a track in it is not the project this command promises.
  let otherRoot = try temporaryFolder()
  let otherGit = try gitThatSigns(inside: otherRoot)
  let busy = Mac(tracksOnOpening: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
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
  #expect(none["session"] is NSNull, "a project that is not empty starts no session")
  #expect(none["step"] is NSNull)
  let sessions = SessionRepository.sessionsFolder(underRoot: otherRoot)
  let left = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
  #expect(left.isEmpty, "and nothing was written for it")
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
/// pressed, and a project with no tracks is the answer the command was asked for. A title would
/// say neither in a Logic of another language, and the name of a project a person opened could say
/// anything at all. So each of the three is read from an element the window carries, and these are
/// the trees that Logic wrote for each one.
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
