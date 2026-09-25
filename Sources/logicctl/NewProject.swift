import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// Makes a new empty project and starts the session that records the work on it.
///
/// This is the first command of logicctl that writes into the journal, and it is the only command
/// that may write into a project without `--confirm`, because it is the command that made the
/// project. Every project that logicctl did not make belongs to a person, and the guard stops a
/// change to one of those. The field that tells the two apart is `createdByLogicctl` in
/// `session.json`, and this command is the only thing that ever sets it.
struct NewProject: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "new-project",
    abstract: "Make a new empty project and start the session that records it.",
    discussion: """
      Logic shows the project chooser while no project is open. The command takes the empty \
      project template, and answers once Logic shows a project with no tracks.

      Example: logicctl new-project
      """)

  @OptionGroup var output: OutputOption

  @OptionGroup var wait: TimeoutOption

  /// The limit of every wait this command makes, in milliseconds.
  var limitMs: Int {
    wait.timeout.milliseconds
  }

  func run() throws {
    let status = NewProject.answer(
      chooser: ProjectChooser.live(),
      driver: NewProject.liveDriver(),
      limitMs: limitMs,
      format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension NewProject {
  /// Takes Logic to an empty project, prints the envelope, and answers the number the process
  /// exits with.
  ///
  /// The chooser and the driver are given rather than reached for, so the pipeline drives the
  /// same command against a Logic of its own.
  static func answer(
    chooser: ProjectChooser,
    driver: any LogicDriver,
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    limitMs: Int = Wait.defaultLimitMs,
    format: OutputFormat = .compact,
    argv: [String] = [],
    now: () -> Date = { Date() },
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds,
    git: Git = Git(),
    lock: Lock = Lock(),
    capturer: any WindowCapturer = WindowCapture(),
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    do {
      let empty = try NewProject.emptyProject(
        through: chooser, and: driver, limitMs: limitMs, clock: clock, sleeper: sleeper)
      let path = try driver.projectPath()
      let session = NewProject.session(of: empty, at: path, version: version, startedAt: started)
      let repository = try SessionRepository.start(
        session: session, root: root, git: git, lock: lock)
      let taken = NewProject.picture(ofTheLogicOf: driver, through: capturer)
      let finished = now()

      // The record holds the envelope that was printed, so both carry one duration. Only the
      // commit of the step is added afterwards, because a commit cannot name itself.
      let answer = Envelope.success(
        data: NewProject.answered(empty, at: path, session: session, in: repository.folder),
        meta: AnswerMeta.run(
          version: version, session: session.id, step: nil, externalChange: nil, from: started,
          to: finished, details: taken.details))
      let step = Step(
        seq: repository.nextSequence(),
        kind: .command,
        command: "new-project",
        argv: argv,
        startedAt: started,
        finishedAt: finished,
        exitCode: Int(answer.exitCode),
        envelope: answer.json,
        stateAfter: CanonicalJSON.sha256(of: empty))
      let commit = try repository.write(step, state: empty, screenshot: taken.bytes)

      return printer.write(
        Envelope.success(
          data: NewProject.answered(empty, at: path, session: session, in: repository.folder),
          meta: AnswerMeta.run(
            version: version, session: session.id, step: commit, externalChange: nil,
            from: started, to: finished, details: taken.details)))
    } catch {
      return printer.write(
        Envelope.failure(
          NewProject.failure(of: error),
          meta: AnswerMeta.run(
            version: version, session: nil, step: nil, externalChange: nil, from: started,
            to: now())))
    }
  }

  /// The empty project Logic has open once the chooser is answered.
  ///
  /// The window is read first, and the tracks after it. Logic puts the sheet that asks for a track
  /// on a project the moment it makes one, and the tracks of the project are what say whether it
  /// is empty, so both have to hold before the project is the one this command promises.
  static func emptyProject(
    through chooser: ProjectChooser,
    and driver: any LogicDriver,
    limitMs: Int,
    clock: @escaping Wait.Clock,
    sleeper: @escaping Wait.Sleeper
  ) throws -> State {
    try chooser.reachAnEmptyProject(limitMs: limitMs, clock: clock, sleeper: sleeper)
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      try driver.readState().tracks.isEmpty
    }
    return try driver.readState()
  }

  /// The project of the answer: what Logic calls it, and where it sits.
  static func project(of state: State, path: String? = nil) -> JSONValue {
    .object([
      "name": .string(state.project.name),
      "path": path.map(JSONValue.string) ?? .null,
    ])
  }


  /// The session of the project this command made.
  ///
  /// It is the one session logicctl writes with `createdByLogicctl` true. Every other session is
  /// started for a project a person made, and the guard reads that field before it lets a command
  /// change one of those.
  static func session(of state: State, at path: String?, version: String, startedAt: Date)
    -> Session
  {
    Session(
      createdAt: startedAt,
      project: Session.Project(name: state.project.name, path: path, createdByLogicctl: true),
      versions: Session.Versions(
        logicctl: version, logic: state.logic.version, macos: Run.macosVersion()))
  }

  /// What the command answers: the project Logic opened, the session that records it, and where
  /// that session sits.
  static func answered(_ state: State, at path: String?, session: Session, in folder: URL)
    -> JSONValue
  {
    .object([
      "project": NewProject.project(of: state, path: path),
      "session": .string(session.id),
      "repository": .string(NewProject.shortForm(of: folder)),
    ])
  }

  /// The folder of a session, with the home folder of the person written as a tilde, which is how
  /// a person writes that path and how they read it back.
  static func shortForm(of folder: URL) -> String {
    (folder.path as NSString).abbreviatingWithTildeInPath
  }

  /// The picture of the window of Logic that the step carries, and what `meta` says when it
  /// carries none.
  ///
  /// A picture is evidence and not a gate. A Mac with no Screen Recording grant does not change
  /// what the command did, so the step records no picture and the answer says why.
  static func picture(ofTheLogicOf driver: any LogicDriver, through capturer: any WindowCapturer)
    -> (bytes: Data?, details: JSONValue?)
  {
    do {
      return (try capturer.picture(ofLogicRunningAs: try driver.processID()), nil)
    } catch {
      let said = "No picture of the window of Logic was taken: " + Run.reason(of: error)
      return (nil, .object(["screenshot": .string(said)]))
    }
  }

  /// What the command stopped with.
  ///
  /// A walk that found no element, and a Logic that never reached the project, each carry their
  /// own failure already, so this joins them to the envelope rather than writing a second one.
  static func failure(of error: Error) -> Failure {
    if let refusal = error as? LocatorResolver.Refusal {
      return refusal.failure
    }
    if let ranOut = error as? Wait.RanOut {
      return ranOut.failure
    }
    if let refusal = error as? ProjectChooser.Refusal {
      return refusal.failure
    }
    return Run.failure(for: error)
  }

  /// What this command reads the state of Logic through on this Mac.
  ///
  /// Nothing in logicctl reads the whole state of Logic yet, so there is no driver over the real
  /// Logic to give here. The part that reads the tracks brings one, and this command is written
  /// against the protocol so that it needs no change when it arrives.
  static func liveDriver() -> any LogicDriver {
    NoDriverYet()
  }
}

/// The driver of a Logic that logicctl cannot read yet.
///
/// It refuses every read with the reason, rather than answering a state that nobody measured. A
/// driver that made one up would write a journal that says Logic held something it never held.
private struct NoDriverYet: LogicDriver {
  /// One sentence a person can act on.
  static let reason =
    "logicctl cannot read the state of Logic yet, so new-project cannot record its session on "
    + "this Mac."

  func readState() throws -> State {
    throw ProjectChooser.Refusal(reason: NoDriverYet.reason, code: .internalFailure)
  }

  func projectPath() throws -> String? {
    throw ProjectChooser.Refusal(reason: NoDriverYet.reason, code: .internalFailure)
  }

  func processID() throws -> Int32 {
    throw ProjectChooser.Refusal(reason: NoDriverYet.reason, code: .internalFailure)
  }

  func modalDialog() throws -> ModalDialog? {
    throw ProjectChooser.Refusal(reason: NoDriverYet.reason, code: .internalFailure)
  }
}
