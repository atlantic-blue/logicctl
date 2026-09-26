import Foundation
import LogicctlCore
import Testing

/// The flow of phase 1 of the stories: launch, status, new-project, save, save again and quit.
///
/// Phase 1 is the first phase that makes a project, writes it and closes it, so it is the first
/// place an acceptance run can damage the work of a person. Two guards hold over the whole flow.
/// Every save goes into a folder of the run under the temporary folder of this Mac, and a save that
/// would land under the music folder stops the walk before the first command. Logic writes a
/// project of its own under the music folder when it makes one, so the flow reads the names there
/// before it starts and again at the end, and it prints every new name. It removes nothing and it
/// fails on nothing it finds: what happens to that project is for the operator to say.
///
/// The six commands are one flow and not six. `new-project` needs the Logic that `launch` started,
/// `save` needs the project `new-project` made, and `quit` closes that project. So the walk runs
/// them in order, records what each one answered, and stops at the first command that did not
/// answer what phase 1 says. A walk that stopped leaves every later step with no answer to read,
/// which is what makes a run that drove nothing read as a failure instead of as a pass.
enum PhaseOne {
  /// What the flow calls the project it makes and saves.
  static let projectName = "PhaseOne.logicx"

  /// The folder Logic keeps the projects it makes for itself in, under the music folder.
  static let logicFolder = "Logic"

  /// Runs one logicctl command and answers what it printed.
  typealias Runs = (_ arguments: [String]) throws -> LiveHarness.Answer

  /// One command of the flow, and the envelope it printed.
  struct Asked: Sendable {
    /// The step of the flow, as phase 1 names it.
    let step: String

    /// The command, as a person types it after the name of the binary.
    let command: String

    /// The number logicctl exited with.
    let status: Int32

    /// The envelope, as logicctl printed it.
    let printed: String

    /// What the command answered, or nothing when it failed.
    let data: Payload?

    /// Why the command failed, or nothing when it did not.
    let error: Refused?

    /// What `meta` carries of the session, the step and the picture.
    let meta: Meta?

    /// What the command said, in words a failure can print.
    var said: String {
      if let error {
        return "\(error.code): \(error.message), exit \(status)"
      }
      return "exit \(status), \(printed)"
    }

    /// What `meta.details` said about the picture of the window, when it said anything.
    ///
    /// A Mac that granted logicctl no Screen Recording takes no picture, and the command says so
    /// here and carries on. RUN-10 makes that a note and never a failure, so the flow reads the
    /// note, prints it, and asserts nothing about it.
    var screenshot: String? {
      meta?.details?.screenshot
    }

    /// Whether the answer carries the session, its folder and the first commit of it.
    ///
    /// `new-project` is the command that starts a session, so its answer is where the journal of
    /// phase 1 begins. A `new-project` that answered a project and wrote no commit would leave
    /// every later command writing into a session that records nothing.
    var startedASession: Bool {
      guard let session = data?.session, !session.isEmpty else {
        return false
      }
      guard let folder = data?.repository, !folder.isEmpty else {
        return false
      }
      guard let commit = meta?.step, !commit.isEmpty else {
        return false
      }
      return session == meta?.session
    }
  }

  /// What a command of phase 1 answers, in the fields the flow reads.
  struct Payload: Decodable, Sendable {
    /// Whether Logic runs, as `launch`, `status` and `quit` each answer it.
    let running: Bool?

    /// The process id of the Logic that `launch` started.
    let pid: Double?

    /// The version of Logic that `status` read.
    let version: String?

    /// The session `new-project` started.
    let session: String?

    /// The folder that session sits in.
    let repository: String?

    /// The project the command answered about.
    let project: Project?
  }

  /// The project a command answers: what Logic calls it, and where it sits.
  struct Project: Decodable, Sendable {
    /// What Logic calls the project.
    let name: String?

    /// Where the project sits, or nothing while Logic has not written it anywhere.
    let path: String?
  }

  /// Why a command failed.
  struct Refused: Decodable, Sendable {
    /// The code of the design system, for example `path_exists`.
    let code: String

    /// The line a person reads.
    let message: String
  }

  /// What `meta` carries of the session, the step and the picture.
  struct Meta: Decodable, Sendable {
    /// The session the command wrote into.
    let session: String?

    /// The commit of the step it wrote.
    let step: String?

    /// What the command has to say beyond its answer.
    let details: Details?
  }

  /// What `meta.details` says about the picture of the window.
  struct Details: Decodable, Sendable {
    /// Why no picture was taken, when none was.
    let screenshot: String?
  }

  /// The envelope of one command, in the three keys every command prints.
  struct Envelope: Decodable {
    /// What the command answered.
    let data: Payload?

    /// Why it failed.
    let error: Refused?

    /// What it carries beyond the answer.
    let meta: Meta?
  }

  /// What one walk of phase 1 did.
  struct Run: Sendable {
    /// Every command the walk asked, in the order it asked them.
    let asked: [Asked]

    /// The names that appeared under the Logic folder of the music folder while it ran.
    let newMusicEntries: [String]

    /// What stopped the walk, or nothing when every command answered what phase 1 says.
    let stopped: String?

    /// What one step of the flow answered, or nothing when the walk never reached it.
    func answer(of step: String) -> Asked? {
      asked.first { $0.step == step }
    }

    /// What the walk did, in words a failure can print.
    var report: String {
      let steps = asked.map(\.step).joined(separator: ", ")
      let did = stopped ?? "nothing"
      return "it asked \(steps.isEmpty ? "nothing" : steps), and stopped with \(did)"
    }
  }

  /// What stopped a walk of phase 1.
  enum Stopped: Error, CustomStringConvertible {
    /// The project the flow would save is under the music folder of this Mac.
    case theSaveWouldBeUnderTheMusicFolder(String)

    /// One command answered something phase 1 does not allow.
    case theCommandAnsweredWrongly(step: String, said: String)

    /// One command printed something no envelope reads back.
    case theCommandPrintedNothingToReadBack(step: String, printed: String)

    /// `save` answered a path, and nothing is there.
    case theProjectIsNotAtThePath(String)

    var description: String {
      switch self {
      case .theSaveWouldBeUnderTheMusicFolder(let path):
        return """
          the flow would save at \(path), under the music folder of this Mac, so it stops before \
          the first command
          """
      case .theCommandAnsweredWrongly(let step, let said):
        return "\(step) did not answer what phase 1 says: \(said)"
      case .theCommandPrintedNothingToReadBack(let step, let printed):
        return "\(step) printed no envelope this flow reads back: \(printed)"
      case .theProjectIsNotAtThePath(let path):
        return "save answered that the project is at \(path), and nothing is there"
      }
    }
  }
}

extension PhaseOne {
  /// Walks the flow of phase 1 and records what every command answered.
  ///
  /// The walk reads the music folder before the first command and again after the last one,
  /// whichever way the flow went, so a project Logic wrote for itself is reported even by a run
  /// that stopped early.
  static func walk(
    savingInto folder: URL,
    musicFolder: URL = LiveHarness.musicFolder,
    fileManager: FileManager = .default,
    runs: Runs
  ) -> Run {
    var asked: [Asked] = []
    let saveTo = folder.appending(path: projectName)
    let logicOfTheMusicFolder = musicFolder.appending(path: logicFolder)
    let before = names(directlyUnder: logicOfTheMusicFolder, fileManager)

    func ask(_ step: String, _ arguments: [String]) throws -> Asked {
      let answer = try runs(arguments)
      guard let envelope = PhaseOne.envelope(of: answer) else {
        throw Stopped.theCommandPrintedNothingToReadBack(step: step, printed: answer.printed)
      }
      let record = Asked(
        step: step,
        command: arguments.joined(separator: " "),
        status: answer.status,
        printed: answer.printed,
        data: envelope.data,
        error: envelope.error,
        meta: envelope.meta)
      if let note = record.screenshot {
        print("screenshot: \(step): \(note)")
      }
      asked.append(record)
      return record
    }

    var stopped: String?
    do {
      guard !LiveHarness.isUnder(musicFolder, saveTo) else {
        throw Stopped.theSaveWouldBeUnderTheMusicFolder(saveTo.path)
      }

      let launched = try ask("launch", ["launch"])
      let itStartedLogic = launched.data?.running == true && (launched.data?.pid ?? 0) > 0
      guard launched.status == 0, itStartedLogic else {
        throw Stopped.theCommandAnsweredWrongly(step: "launch", said: launched.said)
      }

      let read = try ask("status", ["status"])
      let itReadLogic = read.data?.running == true && read.data?.version == LiveHarness.logicVersion
      guard read.status == 0, itReadLogic else {
        throw Stopped.theCommandAnsweredWrongly(step: "status", said: read.said)
      }

      let made = try ask("new-project", ["new-project"])
      guard made.status == 0, made.startedASession else {
        throw Stopped.theCommandAnsweredWrongly(step: "new-project", said: made.said)
      }

      let saved = try ask("save", ["save", "--path", saveTo.path])
      guard saved.status == 0, saved.data?.project?.path == saveTo.path else {
        throw Stopped.theCommandAnsweredWrongly(step: "save", said: saved.said)
      }
      guard fileManager.fileExists(atPath: saveTo.path) else {
        throw Stopped.theProjectIsNotAtThePath(saveTo.path)
      }

      let again = try ask("save again", ["save", "--path", saveTo.path])
      let itRefusedThePath =
        again.error?.code == ErrorCode.pathExists.rawValue
        && again.status == ErrorCode.pathExists.exitCode
      guard itRefusedThePath else {
        throw Stopped.theCommandAnsweredWrongly(step: "save again", said: again.said)
      }

      let closed = try ask("quit", ["quit"])
      guard closed.status == 0, closed.data?.running == false else {
        throw Stopped.theCommandAnsweredWrongly(step: "quit", said: closed.said)
      }
    } catch {
      stopped = String(describing: error)
    }

    let after = names(directlyUnder: logicOfTheMusicFolder, fileManager)
    let appeared = after.filter { !before.contains($0) }
    for name in appeared {
      print("music folder: new entry \(name)")
    }
    return Run(asked: asked, newMusicEntries: appeared, stopped: stopped)
  }

  /// One walk of phase 1 against the Logic this Mac runs, through the signed binary.
  static func walkTheRealLogic() -> Run {
    do {
      let folder = try LiveHarness.temporaryFolder()
      print("phase 1 saves into: \(folder.path)")
      return walk(savingInto: folder) { arguments in
        try LiveHarness.logicctl(arguments)
      }
    } catch {
      return Run(asked: [], newMusicEntries: [], stopped: String(describing: error))
    }
  }

  /// The envelope one command printed, or nothing when it printed none.
  static func envelope(of answer: LiveHarness.Answer) -> Envelope? {
    guard let bytes = answer.printed.data(using: .utf8) else {
      return nil
    }
    return try? JSONDecoder().decode(Envelope.self, from: bytes)
  }
}

/// Phase 1 of the stories, against the Logic that runs on this Mac.
///
/// The pipeline drives every one of these commands against a driver of its own, over a tree that
/// `inspect` recorded from Logic 12.3.1. That says nothing about whether the presses still land on
/// the running application: a locator that moved, a sheet Logic now puts up, a window that is not
/// where it was. These six scenarios are where phase 1 is answered, and `make accept PART=1` is
/// how a person runs them.
///
/// They run one at a time, because one Logic runs on this Mac, and they read one walk of the flow
/// rather than walking it each. Six walks would make six projects and leave Logic in a state the
/// next scenario did not expect.
@Suite(.serialized, .enabled(if: LiveHarness.runsLive()))
struct Phase1LiveScenarios {
  /// The one walk of phase 1, made the first time a scenario reads it.
  static let walked = PhaseOne.walkTheRealLogic()

  /// The answer of one step of that walk, or a failure naming what the walk did instead.
  static func answer(of step: String) throws -> PhaseOne.Asked {
    let walk = Phase1LiveScenarios.walked
    return try #require(walk.answer(of: step), "the flow reached \(step): \(walk.report)")
  }

  /// `launch` starts Logic and answers once Logic shows a window (story S1.1).
  @Test func launchStartsLogicAndWaitsForItsWindow() throws {
    LiveHarness.liveScenario("launchStartsLogicAndWaitsForItsWindow")

    let launched = try Phase1LiveScenarios.answer(of: "launch")

    #expect(launched.status == 0, "launch waited for the window of Logic: \(launched.said)")
    #expect(launched.data?.running == true, "and it answers the Logic it started")
    #expect((launched.data?.pid ?? 0) > 0, "with the process id of that Logic")
  }

  /// `status` reads the Logic of this Mac as a state (story S1.1).
  @Test func statusReadsTheLogicOfThisMac() throws {
    LiveHarness.liveScenario("statusReadsTheLogicOfThisMac")

    let read = try Phase1LiveScenarios.answer(of: "status")

    #expect(read.status == 0, "status read the running Logic: \(read.said)")
    #expect(read.data?.running == true, "it reads that Logic runs")
    #expect(
      read.data?.version == LiveHarness.logicVersion,
      "and the version this suite drives: \(read.data?.version ?? "no version")")
  }

  /// `new-project` reaches an empty project and starts the session that records it (story S1.3).
  ///
  /// The commit the answer names is the first commit of that session, and the proof of this phase
  /// is that commit and the picture of the empty project. A Mac that granted no Screen Recording
  /// takes no picture, so the note in `meta` is printed and nothing here fails on it.
  @Test func newProjectStartsASessionWithItsFirstCommit() throws {
    LiveHarness.liveScenario("newProjectStartsASessionWithItsFirstCommit")

    let made = try Phase1LiveScenarios.answer(of: "new-project")

    #expect(made.status == 0, "new-project reached an empty project: \(made.said)")
    #expect(made.startedASession, "and it started the session that records it: \(made.printed)")
    #expect(made.data?.project?.name?.isEmpty == false, "the answer names the project Logic made")
  }

  /// `save --path` writes the project into the folder of the run (story S1.4).
  @Test func saveWritesTheProjectIntoTheFolderOfTheRun() throws {
    LiveHarness.liveScenario("saveWritesTheProjectIntoTheFolderOfTheRun")

    let saved = try Phase1LiveScenarios.answer(of: "save")
    let path = saved.data?.project?.path ?? ""

    #expect(saved.status == 0, "save wrote the project: \(saved.said)")
    #expect(path.hasSuffix(PhaseOne.projectName), "at the path the run gave it: \(path)")
    #expect(
      LiveHarness.isUnder(LiveHarness.musicFolder, URL(fileURLWithPath: path)) == false,
      "and never under the music folder of this Mac: \(path)")
  }

  /// A second `save` to the same path stops with `path_exists` (story S1.4).
  @Test func saveRefusesThePathItAlreadyWrote() throws {
    LiveHarness.liveScenario("saveRefusesThePathItAlreadyWrote")

    let again = try Phase1LiveScenarios.answer(of: "save again")

    #expect(
      again.error?.code == ErrorCode.pathExists.rawValue,
      "a path that is taken stops the save: \(again.said)")
    #expect(
      again.status == ErrorCode.pathExists.exitCode,
      "with the number the design system gives that code: exit \(again.status)")
  }

  /// `quit` closes the project it saved, and Logic goes (story S1.2).
  @Test func quitClosesTheProjectItSaved() throws {
    LiveHarness.liveScenario("quitClosesTheProjectItSaved")

    let closed = try Phase1LiveScenarios.answer(of: "quit")

    #expect(closed.status == 0, "quit closed a project with nothing to lose: \(closed.said)")
    #expect(closed.data?.running == false, "and Logic is gone when the command answers")
  }
}

/// An acceptance run of phase 1 reports a pass only when every command of it drove the real Logic.
///
/// Phase 1 is the first phase that makes a project, writes it and closes it. `make accept PART=1`
/// is the only run in which those six commands meet the application, and its output is the evidence
/// that the tool works at all: the project Logic made, the first commit of its session, the picture
/// of the window, and a second save that refuses a path it already wrote. A run that reported a
/// pass while one of those commands never ran, or ran and answered a failure, would ship a tool
/// that cannot make a project, and nobody reads six envelopes by hand to catch that.
///
/// So the flow is one walk that stops at the first command that did not answer what phase 1 says.
/// This scenario walks it here, where there is no Logic, against a logicctl that answers the
/// envelopes of the contracts, and it reads four things: the six commands run in the order the flow
/// needs and every save goes to the folder of the run, a command that answers a failure stops the
/// walk before the next one, a second save that does not refuse the path is not accepted, and a
/// flow that would save under the music folder asks nothing at all.
///
/// The music folder is the one place this run can do damage that no undo brings back. Logic writes
/// a project of its own there when it makes one, so the walk reads the names before and after and
/// reports every new one. It never removes one, and a new name fails nothing: the operator decides
/// what happens to that project.
@Test func phaseOneAgainstLogic() throws {
  let folder = try LiveHarness.temporaryFolder()
  defer { try? FileManager.default.removeItem(at: folder) }

  let music = folder.appending(path: "Music")
  let logicOfTheMusicFolder = music.appending(path: PhaseOne.logicFolder)
  try FileManager.default.createDirectory(
    at: logicOfTheMusicFolder, withIntermediateDirectories: true)

  let saveTo = folder.appending(path: PhaseOne.projectName)
  let untitled = logicOfTheMusicFolder.appending(path: "Untitled.logicx")

  let logic = FakeLogic(saveTo: saveTo, untitled: untitled)
  let walked = PhaseOne.walk(savingInto: folder, musicFolder: music) { try logic.run($0) }

  #expect(
    walked.stopped == nil,
    "every command of phase 1 answered as phase 1 says: \(walked.report)")
  #expect(
    logic.asked == [
      "launch",
      "status",
      "new-project",
      "save --path \(saveTo.path)",
      "save --path \(saveTo.path)",
      "quit",
    ],
    "the six commands ran in the order the flow needs, and both saves go to the folder of the run")

  let made = try #require(walked.answer(of: "new-project"), "the walk reached new-project")
  #expect(made.meta?.step == FakeLogic.firstCommit, "the answer carries the first commit")
  #expect(made.screenshot == FakeLogic.noPicture, "and what meta says about the picture")
  #expect(
    walked.newMusicEntries == ["Untitled.logicx"],
    "the project Logic wrote for itself is reported: \(walked.newMusicEntries)")
  #expect(
    FileManager.default.fileExists(atPath: untitled.path),
    "and it is left where Logic put it, for the operator to decide about")

  let refusing = FakeLogic(saveTo: saveTo, refuses: ["status": .logicNotRunning])
  let itStopped = PhaseOne.walk(savingInto: folder, musicFolder: music) { try refusing.run($0) }

  #expect(
    itStopped.stopped?.contains(ErrorCode.logicNotRunning.rawValue) == true,
    "a command that answers a failure stops the walk: \(itStopped.report)")
  #expect(
    refusing.asked == ["launch", "status"],
    "and the flow asks nothing after it, so no project is made and nothing is saved")
  #expect(
    itStopped.answer(of: "quit") == nil,
    "the scenario of a command that never ran has no answer to read")

  let lenient = FakeLogic(saveTo: saveTo, theSecondSaveWorks: true)
  let notAccepted = PhaseOne.walk(savingInto: folder, musicFolder: music) { try lenient.run($0) }

  #expect(
    notAccepted.stopped != nil,
    "a save over a path that is taken must stop with path_exists: \(notAccepted.report)")
  #expect(notAccepted.answer(of: "quit") == nil, "so the walk stops there and quit never runs")

  let intoTheMusicFolder = FakeLogic(saveTo: logicOfTheMusicFolder)
  let refused = PhaseOne.walk(savingInto: logicOfTheMusicFolder, musicFolder: music) {
    try intoTheMusicFolder.run($0)
  }

  #expect(
    refused.stopped?.contains(logicOfTheMusicFolder.path) == true,
    "a flow that would save under the music folder stops and names the path: \(refused.report)")
  #expect(intoTheMusicFolder.asked.isEmpty, "before it asks the first command")
}

/// A logicctl that answers the envelopes of phase 1, so the flow can be walked with no Logic.
///
/// The envelopes are built from the contracts of phase 1 and from `design-system.json`. They are
/// not recorded from Logic. They are how the pipeline drives this flow at all: the machine that
/// runs it has no Logic, no project and no grant.
private final class FakeLogic {
  /// The commit this logicctl answers as the first commit of the session.
  static let firstCommit = "9a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b"

  /// What it says about the picture, as a Mac with no Screen Recording grant says it.
  static let noPicture =
    "No picture of the window of Logic was taken: screencapture ended with status 1"

  /// The session it answers.
  static let session = "75bb7987-4e06-4623-be45-e1f8833a9598"

  /// Where the flow saves the project.
  private let saveTo: URL

  /// The project Logic writes for itself, or nothing when this run writes none.
  private let untitled: URL?

  /// The code one command answers instead of an answer, by the name of that command.
  private let refuses: [String: ErrorCode]

  /// Whether the second save answers as though the path were free.
  private let theSecondSaveWorks: Bool

  /// Every command it was asked, in the order it was asked them.
  private(set) var asked: [String] = []

  /// How many saves it was asked.
  private var saves = 0

  init(
    saveTo: URL,
    untitled: URL? = nil,
    refuses: [String: ErrorCode] = [:],
    theSecondSaveWorks: Bool = false
  ) {
    self.saveTo = saveTo
    self.untitled = untitled
    self.refuses = refuses
    self.theSecondSaveWorks = theSecondSaveWorks
  }

  /// Answers one command of phase 1 the way Logic 12.3.1 leads logicctl to answer it.
  func run(_ arguments: [String]) throws -> LiveHarness.Answer {
    let name = arguments.first ?? ""
    asked.append(arguments.joined(separator: " "))

    if let code = refuses[name] {
      return failure(code)
    }

    switch name {
    case "launch":
      return success("""
        {"running":true,"pid":4321}
        """)
    case "status":
      return success("""
        {"frontmost":true,"running":true,"version":"12.3.1","window":"Untitled - Tracks"}
        """)
    case "new-project":
      write(untitled)
      return success(
        """
        {"project":{"name":"Untitled","path":null},\
        "repository":"~/.logicctl/sessions/untitled-75bb7987",\
        "session":"\(FakeLogic.session)"}
        """,
        session: FakeLogic.session,
        step: FakeLogic.firstCommit,
        screenshot: FakeLogic.noPicture)
    case "save":
      saves += 1
      guard saves == 1 || theSecondSaveWorks else {
        return failure(.pathExists)
      }
      write(saveTo)
      return success(
        """
        {"project":{"name":"PhaseOne","path":"\(saveTo.path)"}}
        """,
        session: FakeLogic.session,
        step: FakeLogic.firstCommit)
    case "quit":
      return success("""
        {"running":false}
        """)
    default:
      return failure(.invalidArgument)
    }
  }

  /// One envelope of a command that worked.
  private func success(
    _ data: String,
    session: String? = nil,
    step: String? = nil,
    screenshot: String? = nil
  ) -> LiveHarness.Answer {
    let meta = """
      {"details":\(details(screenshot)),"durationMs":12,"externalChange":null,\
      "session":\(json(session)),"step":\(json(step)),"version":"0.1.0"}
      """
    let printed = """
      {"data":\(data),"error":null,"meta":\(meta)}
      """
    return LiveHarness.Answer(status: 0, printed: printed, complained: "")
  }

  /// One envelope of a command that stopped, with the number that code exits with.
  private func failure(_ code: ErrorCode) -> LiveHarness.Answer {
    let printed = """
      {"data":null,"error":{"code":"\(code.rawValue)","details":null,\
      "message":"this logicctl answers \(code.rawValue)"},"meta":{"details":null,\
      "durationMs":3,"externalChange":null,"session":null,"step":null,"version":"0.1.0"}}
      """
    return LiveHarness.Answer(
      status: code.exitCode,
      printed: printed,
      complained: "logicctl: \(code.rawValue): this logicctl answers \(code.rawValue)")
  }

  /// Writes a project folder where Logic would write one.
  private func write(_ project: URL?) {
    guard let project else {
      return
    }
    try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  }
}

/// One value of an envelope, as JSON: the text in quotes, or null when there is none.
private func json(_ value: String?) -> String {
  guard let value else {
    return "null"
  }
  return """
    "\(value)"
    """
}

/// What `meta.details` carries, as JSON: the note about the picture, or null when there is none.
private func details(_ screenshot: String?) -> String {
  guard let screenshot else {
    return "null"
  }
  return """
    {"screenshot":"\(screenshot)"}
    """
}

/// The names directly under one folder, sorted, and none when the folder is not there.
private func names(directlyUnder folder: URL, _ fileManager: FileManager) -> [String] {
  let found = try? fileManager.contentsOfDirectory(atPath: folder.path)
  return (found ?? []).sorted()
}
