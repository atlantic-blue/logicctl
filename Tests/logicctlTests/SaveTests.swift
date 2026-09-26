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
    .appendingPathComponent("logicctl-save-\(UUID().uuidString)")
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

  /// The `error` of the answer, or an empty object when it carries none.
  func failure() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }

  /// The `meta` of the answer.
  func meta() throws -> [String: Any] {
    try printed()["meta"] as? [String: Any] ?? [:]
  }
}

/// A picture of the window of Logic, which the pipeline has no window server to take.
private struct APicture: WindowCapturer {
  let bytes = Data("a window".utf8)

  func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    bytes
  }
}

/// The Logic a test drives: the panel it shows, and the project it has open behind it.
///
/// Pressing Save is what writes the project, as it is in Logic. Nothing else in the route puts a
/// file on disk, so a test that reads the path afterwards is reading what the press did. The
/// project lands where the walk of the columns points, plus the name in the field, because that is
/// how the panel decides: a Logic that took the name alone would write every project to one folder.
///
/// The columns are the folders of this Mac. Column 1 lists the root of the start up disk, and each
/// column to the right lists what the folder opened before it holds, so a test that saves into a
/// temporary folder drives the whole walk down to it.
private final class Mac {
  /// True while Logic shows the panel that asks where the project goes.
  var showsThePanel = false

  /// The folders the route opened, from the root of the start up disk down.
  var walked: [String] = []

  /// What the route did, in the order it did it.
  var asked: [String] = []

  /// What the route wrote into each field.
  var written: [String: String] = [:]

  /// Every path Logic wrote the project to.
  var savedTo: [String] = []

  /// The bytes Logic writes for a project.
  var bytesOfTheProject = Data("the project of logicctl".utf8)

  /// True when this Logic presses Save and leaves the project where it was.
  var leavesTheProjectWhereItWas = false

  /// The dialog Logic opens after the panel closes.
  var opensAfterwards: ModalDialog?

  /// The Logic the command reads the project through.
  let driver: FakeLogicDriver

  init(projectNamed name: String = "Untitled", at path: String? = nil) {
    driver = FakeLogicDriver(
      state: State(
        logic: LogicVersion(version: "12.3.1"),
        project: Project(name: name),
        transport: Transport(tempo: 120),
        tracks: []),
      processID: 981,
      path: path)
  }

  /// The panel the command drives.
  func panel() -> SaveDialog {
    SaveDialog(
      openTheMenuItem: {
        self.asked.append("File, Save As")
        self.showsThePanel = true
      },
      showsThePanel: { self.showsThePanel },
      write: { locator, text in
        self.asked.append("write " + locator.name)
        self.written[locator.name] = text
      },
      press: { locator in
        self.asked.append("press " + locator.name)
        guard locator.name == Locators.saveButton.name else {
          return
        }
        let to = self.pathOfTheWalk(named: self.written[Locators.saveNameField.name] ?? "")
        try self.bytesOfTheProject.write(to: URL(fileURLWithPath: to), options: .atomic)
        self.savedTo.append(to)
        self.showsThePanel = false
        self.driver.dialog = self.opensAfterwards
        guard !self.leavesTheProjectWhereItWas else {
          return
        }
        self.driver.path = to
      },
      resolve: { $0 },
      namesInColumn: { number in
        try FileManager.default.contentsOfDirectory(atPath: self.folderOfTheWalk(cutTo: number))
      },
      openFolder: { number, name in
        self.asked.append("open " + name)
        self.walked = Array(self.walked.prefix(number)) + [name]
      },
      folderShown: { self.walked.last ?? "" })
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

/// A session of a project that logicctl made and has not saved anywhere yet.
private func sessionOfANewProject(
  named name: String = "Untitled",
  at path: String? = nil,
  madeByLogicctl: Bool = true,
  root: URL,
  git: Git
) throws -> Session {
  let session = Session(
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    project: Session.Project(name: name, path: path, createdByLogicctl: madeByLogicctl),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0.0"))
  _ = try SessionRepository.start(session: session, root: root, git: git)
  return session
}

/// A `session.json` that does not read back as a session.
private struct NotASession: Error {}

/// The session as it reads back from its own `session.json`.
private func sessionOnDisk(_ session: Session, underRoot root: URL) throws -> Session {
  let file = SessionRepository.sessionFolder(of: session, underRoot: root)
    .appendingPathComponent("session.json")
  let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
  guard let read = Session(json: try CanonicalJSON.value(of: text)) else {
    throw NotASession()
  }
  return read
}

/// The files one commit of a session changed.
private func filesOfTheLastCommit(
  of session: Session, underRoot root: URL, git: Git
) throws -> [String] {
  let folder = SessionRepository.sessionFolder(of: session, underRoot: root)
  let printed = try git.run(["show", "--name-only", "--format=", "HEAD"], in: folder)
  return printed.split(whereSeparator: \.isNewline).map(String.init).sorted()
}

/// How many commits a session carries.
private func commits(of session: Session, underRoot root: URL, git: Git) throws -> Int {
  let folder = SessionRepository.sessionFolder(of: session, underRoot: root)
  return try git.run(["log", "--format=%H"], in: folder)
    .split(whereSeparator: \.isNewline).count
}

/// A person keeps the work they already have.
///
/// A Logic project holds hours that nothing brings back, and a path is one word in a command. So a
/// `save` that finds something at the path it was given writes nothing at all: it does not ask
/// Logic to save, it names what is in the way, and it exits 9 so that a script stops there too.
/// The bytes at the path are the bytes that were there before. The person then decides, and
/// `--confirm` is how they say it, at which point the same command writes the project and the
/// session records where the project now sits.
///
/// This is the whole of the promise of the command. A save that wrote over a path because it was
/// typed twice would destroy work no later command can recover, and no other guard in logicctl
/// stands between a person and that.
@Test func saveStopsWhenThePathExists() throws {
  let typed = try Logicctl.parseAsRoot(["save", "--path", "Test.logicx"])
  #expect(typed is Save, "a person can type logicctl save --path")

  let root = try temporaryFolder()
  let git = try gitThatSigns(inside: root)
  let work = try temporaryFolder()
  let path = work.appendingPathComponent("Test.logicx").path

  let theirs = Data("the work a person already has".utf8)
  try theirs.write(to: URL(fileURLWithPath: path), options: .atomic)

  let logic = Mac()
  let session = try sessionOfANewProject(root: root, git: git)
  let time = Time()
  let refused = Answer()

  let stopped = Save.answer(
    toPath: path,
    confirmed: false,
    dialog: logic.panel(),
    driver: logic.driver,
    root: root,
    limitMs: 500,
    argv: ["--path", path],
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    capturer: APicture(),
    standardOutput: refused.write,
    standardError: refused.writeError)

  #expect(stopped == 9, "the number the design system gives path_exists")
  #expect(try refused.failure()["code"] as? String == "path_exists")
  #expect(try refused.printed()["data"] is NSNull, "a failure carries no data")
  let named = try refused.failure()["details"] as? [String: Any]
  #expect(named?["path"] as? String == path, "the failure names what is in the way")
  #expect(
    refused.err.split(whereSeparator: \.isNewline).count == 1,
    "standard error carries one line for the person reading along")
  #expect(refused.err.hasPrefix("logicctl: path_exists: "))

  #expect(
    try Data(contentsOf: URL(fileURLWithPath: path)) == theirs,
    "the work that was at the path is the work that is at the path")
  #expect(logic.asked.isEmpty, "Logic was asked to save nothing")
  #expect(try refused.meta()["session"] is NSNull, "nothing was recorded, so no session")
  #expect(try refused.meta()["step"] is NSNull, "and no step")
  #expect(
    try commits(of: session, underRoot: root, git: git) == 1,
    "the session gained no step from a command that acted on nothing")
  #expect(
    try sessionOnDisk(session, underRoot: root).project.path == nil,
    "the project is still where it was, which is nowhere")

  // The person reads what is in the way, and says the word.
  let saved = Answer()
  let wrote = Save.answer(
    toPath: path,
    confirmed: true,
    dialog: logic.panel(),
    driver: logic.driver,
    root: root,
    limitMs: 500,
    argv: ["--path", path, "--confirm"],
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    capturer: APicture(),
    standardOutput: saved.write,
    standardError: saved.writeError)

  #expect(wrote == 0, "--confirm writes over what is there")
  #expect(saved.err.isEmpty, "standard error is empty on success")
  #expect(saved.out.filter(\.isNewline).count == 1, "one JSON object and a newline")
  let project = try saved.data()["project"] as? [String: Any]
  #expect(project?["path"] as? String == path, "the answer says where the project now sits")
  #expect(project?["name"] as? String == "Untitled")
  #expect(logic.savedTo == [path], "Logic wrote the project to the path, once")
  #expect(
    try Data(contentsOf: URL(fileURLWithPath: path)) == logic.bytesOfTheProject,
    "the project of the person is at the path now")

  let meta = try saved.meta()
  #expect(meta["session"] as? String == session.id, "the save went into the session of the project")
  let step = try #require(meta["step"] as? String, "and it wrote its own step")
  #expect(!step.isEmpty)
  #expect(
    try sessionOnDisk(session, underRoot: root).project.path == path,
    "the session records where the project sits, so the next command finds it by that path")
  #expect(
    try filesOfTheLastCommit(of: session, underRoot: root, git: git)
      == ["session.json", "state.json", "steps/000001/screenshot.png", "steps/000001/step.json"],
    "the new path and the step of the save are one commit")
}

/// Logic is walked to the folder, told the name, and then told to write the project.
///
/// The panel takes no path in its name field. A value written there is read as a name, so a whole
/// path becomes one project called `:Users:someone:Free.logicx` in whatever folder the panel was
/// showing. The command walks the columns of the panel to the folder instead, and the field takes
/// the name of the project on its own.
@Test func theSaveCommandWalksToTheFolderAndWritesTheProjectThere() throws {
  let root = try temporaryFolder()
  let git = try gitThatSigns(inside: root)
  let work = try temporaryFolder()
  let path = work.appendingPathComponent("Free.logicx").path

  let logic = Mac()
  _ = try sessionOfANewProject(root: root, git: git)
  let time = Time()
  let answered = Answer()

  let exited = Save.answer(
    toPath: path,
    confirmed: false,
    dialog: logic.panel(),
    driver: logic.driver,
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    capturer: APicture(),
    standardOutput: answered.write,
    standardError: answered.writeError)

  let folders = work.path.split(separator: "/").map(String.init)

  #expect(exited == 0, "a path that is free needs no confirmation")
  #expect(logic.asked.first == "File, Save As", "the command opened the panel first")
  #expect(
    logic.asked.filter { $0.hasPrefix("open ") } == folders.map { "open " + $0 },
    "it opened one folder of the path per column, down to the folder the project goes in")
  #expect(
    Array(logic.asked.suffix(2)) == [
      "write " + Locators.saveNameField.name,
      "press " + Locators.saveButton.name,
    ],
    "then it wrote the name and pressed Save")
  #expect(
    logic.asked.filter { $0.hasPrefix("press ") } == ["press " + Locators.saveButton.name],
    "and it pressed nothing else, so the panel was never cancelled")
  let typed = try #require(logic.written[Locators.saveNameField.name])
  #expect(typed == "Free.logicx", "the name of the project went into the field, and not the path")
  #expect(!typed.contains("/"), "a path in that field is read as a name")
  #expect(logic.savedTo == [path], "the project is at the path the walk and the name make together")
  #expect(!logic.showsThePanel, "the command waited for Logic to close the panel")
}

/// A Logic that did not put the project where it was told fails the command.
///
/// A press that returns success proves nothing, so the command reads Logic back. A project that is
/// still where it was is a save that did not happen, and the session must not record a path that
/// nothing is at: the next command would look for the project there and find nothing.
@Test func aSaveThatDidNotMoveTheProjectFailsWithTimeout() throws {
  let root = try temporaryFolder()
  let git = try gitThatSigns(inside: root)
  let work = try temporaryFolder()
  let path = work.appendingPathComponent("Nowhere.logicx").path

  let logic = Mac()
  logic.leavesTheProjectWhereItWas = true
  let session = try sessionOfANewProject(root: root, git: git)
  let time = Time()
  let answered = Answer()

  let exited = Save.answer(
    toPath: path,
    confirmed: false,
    dialog: logic.panel(),
    driver: logic.driver,
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    capturer: APicture(),
    standardOutput: answered.write,
    standardError: answered.writeError)

  #expect(exited == 6, "the number the design system gives timeout")
  #expect(try answered.failure()["code"] as? String == "timeout")
  #expect(
    try sessionOnDisk(session, underRoot: root).project.path == nil,
    "the session records no path, because the project did not move")
}

/// Logic asks something of its own after the save, and logicctl answers nothing.
///
/// Logic takes nothing else while a dialog is open, so the state past one says nothing and any
/// answer the command gave would be a guess. The panel that asks where the project goes is the
/// expected answer to the menu item and is not one of these. Every other modal window is.
@Test func aDialogThatLogicOpensAfterTheSaveStopsTheCommand() throws {
  let root = try temporaryFolder()
  let git = try gitThatSigns(inside: root)
  let work = try temporaryFolder()
  let path = work.appendingPathComponent("Asked.logicx").path

  let logic = Mac()
  logic.opensAfterwards = ModalDialog(
    text: "Also import tempo information?", buttons: ["No", "Import Tempo", "Cancel"])
  _ = try sessionOfANewProject(root: root, git: git)
  let time = Time()
  let answered = Answer()

  let exited = Save.answer(
    toPath: path,
    confirmed: false,
    dialog: logic.panel(),
    driver: logic.driver,
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    capturer: APicture(),
    standardOutput: answered.write,
    standardError: answered.writeError)

  #expect(exited == 16, "the number the design system gives dialog_open")
  #expect(try answered.failure()["code"] as? String == "dialog_open")
  let details = try answered.failure()["details"] as? [String: Any]
  #expect(
    details?["text"] as? String == "Also import tempo information?",
    "a person reads what Logic asked without opening Logic")
  #expect(details?["buttons"] as? [String] == ["No", "Import Tempo", "Cancel"])
}

/// A project a person made is theirs, and a save writes into it.
///
/// So the guard that stands in front of every change stands in front of this one. The person goes
/// again with `--confirm`, which is the only way past it.
@Test func savingAProjectOfAPersonNeedsConfirm() throws {
  let root = try temporaryFolder()
  let git = try gitThatSigns(inside: root)
  let work = try temporaryFolder()
  let theirs = work.appendingPathComponent("Theirs.logicx").path
  let path = work.appendingPathComponent("Copy.logicx").path

  let logic = Mac(projectNamed: "Their Song", at: theirs)
  _ = try sessionOfANewProject(
    named: "Their Song", at: theirs, madeByLogicctl: false, root: root, git: git)
  let time = Time()
  let answered = Answer()

  let exited = Save.answer(
    toPath: path,
    confirmed: false,
    dialog: logic.panel(),
    driver: logic.driver,
    root: root,
    limitMs: 500,
    clock: time.read,
    sleeper: time.sleep,
    git: git,
    capturer: APicture(),
    standardOutput: answered.write,
    standardError: answered.writeError)

  #expect(exited == 7, "the number the design system gives confirm_required")
  #expect(try answered.failure()["code"] as? String == "confirm_required")
  #expect(logic.asked.isEmpty, "Logic was asked to save nothing")
  #expect(
    !FileManager.default.fileExists(atPath: path),
    "a refusal writes nothing, so the path it was given is still free")
}

/// A person types a path the way they type one anywhere else on this Mac.
///
/// A tilde is their home folder, and a path with no leading slash is from the folder they are
/// standing in. Both reach Logic as one absolute path, because the name field of the panel takes
/// one and a journal that recorded a relative path could not be read from anywhere else.
@Test func aTypedPathBecomesOneAbsolutePath() throws {
  let home = NSHomeDirectory()
  #expect(
    Save.absolutePath(of: "~/Music/Logic/Test.logicx", from: "/tmp")
      == home + "/Music/Logic/Test.logicx")
  #expect(Save.absolutePath(of: "Test.logicx", from: "/tmp/work") == "/tmp/work/Test.logicx")
  #expect(Save.absolutePath(of: "../Test.logicx", from: "/tmp/work") == "/tmp/Test.logicx")
  #expect(
    Save.absolutePath(of: "/tmp/work/Test.logicx", from: "/elsewhere") == "/tmp/work/Test.logicx")
}

/// A path is what the command is for, so a command with nothing in it stops before Logic.
@Test func saveWithAnEmptyPathIsRefusedBeforeLogic() throws {
  let answered = Answer()
  let exited = Logicctl.run(
    arguments: ["save", "--path", "  "],
    standardOutput: answered.write,
    standardError: answered.writeError)

  #expect(exited == 2, "the number the design system gives invalid_argument")
  #expect(try answered.failure()["code"] as? String == "invalid_argument")
}
