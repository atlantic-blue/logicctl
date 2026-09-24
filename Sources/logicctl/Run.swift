import Foundation
import LogicctlCore
import LogicctlJournal

/// One command of logicctl that talks to Logic.
///
/// A command says what it is called and what a person typed, and it does one thing to Logic. It
/// does not take the lock, read the journal or build its own answer. The run does that for every
/// command, so no command can do it differently.
protocol LogicCommand {
  /// The subcommand, for example `tracks mute`.
  var name: String { get }

  /// The arguments after the subcommand, as a person typed them.
  var argv: [String] { get }

  /// What the command does to Logic, and what its answer carries when it worked.
  func act(through driver: any LogicDriver) throws -> JSONValue?
}

/// The one order that every command talking to Logic goes through.
///
/// Find the session of the open project, take its lock, read the state, write the change a person
/// made as a step of its own, act, read the state again, write the step of the command, release
/// the lock, and answer. A command that is refused before any of that reads nothing and records
/// nothing, and its answer carries no session and no step.
struct Run {
  /// What the run reads Logic through.
  let driver: any LogicDriver

  /// The folder every session sits under.
  let root: URL

  /// The version the answer carries.
  let version: String

  /// The clock the run reads.
  let now: () -> Date

  /// The git that writes a session.
  let git: Git

  /// The lock that keeps a second writer out of a session.
  let lock: Lock

  init(
    driver: any LogicDriver,
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    now: @escaping () -> Date = { Date() },
    git: Git = Git(),
    lock: Lock = Lock()
  ) {
    self.driver = driver
    self.root = root
    self.version = version
    self.now = now
    self.git = git
    self.lock = lock
  }

  /// Runs one command and answers the envelope logicctl prints.
  ///
  /// Nothing throws out of here. A failure of Logic or of the journal is an answer like any other,
  /// because a caller reads one envelope whatever happened.
  func run(command: any LogicCommand) -> Envelope {
    let started = now()
    do {
      return try record(command, from: started)
    } catch {
      return Envelope.failure(
        Run.failure(for: error),
        meta: AnswerMeta.refusal(version: version, from: started, to: now()))
    }
  }

  /// Runs one command and records it in the session of the project Logic has open.
  private func record(_ command: any LogicCommand, from started: Date) throws -> Envelope {
    guard let path = try driver.projectPath() else {
      // A project that was never saved has no path, and a session is found by the path of its
      // project. So there is nothing to write into yet, and the answer says so with a session of
      // null. `new-project` gives a project its session.
      let done = outcome(of: command)
      return envelope(
        of: done,
        meta: AnswerMeta.run(
          version: version, session: nil, step: nil, externalChange: nil, from: started,
          to: now()))
    }

    let repository = try session(ofProjectAt: path)
    return try repository.lock.holding(repository.folder) { () throws -> Envelope in
      let before = try driver.readState()
      let change = try changeMadeByHand(before: before, in: repository)
      let done = outcome(of: command)
      let after = try? driver.readState()
      let finished = now()

      // The record holds the envelope that was printed, so both carry one duration, measured
      // when the command ended. Only the commit of the step is added afterwards, because a
      // commit cannot name itself.
      let answer = envelope(
        of: done,
        meta: AnswerMeta.run(
          version: version, session: repository.session.id, step: nil, externalChange: change,
          from: started, to: finished))
      let step = Step(
        seq: repository.nextSequence(),
        kind: .command,
        command: command.name,
        argv: command.argv,
        startedAt: started,
        finishedAt: finished,
        exitCode: Int(answer.exitCode),
        envelope: answer.json,
        stateBefore: CanonicalJSON.sha256(of: before),
        stateAfter: after.map { CanonicalJSON.sha256(of: $0) })
      let commit = try repository.writeUnderTheLock(step, state: after)

      return envelope(
        of: done,
        meta: AnswerMeta.run(
          version: version, session: repository.session.id, step: commit, externalChange: change,
          from: started, to: finished))
    }
  }

  /// The change a person made in Logic since the session last recorded the project, written as a
  /// step of its own. It answers the commit of that step, or nothing when nobody changed anything.
  ///
  /// A session that carries no state yet records no change: there is nothing to compare, and the
  /// step of the command writes the first state.
  private func changeMadeByHand(before: State, in repository: SessionRepository) throws -> String? {
    guard let recorded = storedState(of: repository) else {
      return nil
    }
    let differences = StateDiff.between(recorded, before.json)
    guard !differences.isEmpty else {
      return nil
    }
    let moment = now()
    let step = Step(
      seq: repository.nextSequence(),
      kind: .externalChange,
      startedAt: moment,
      finishedAt: moment,
      exitCode: 0,
      stateBefore: CanonicalJSON.sha256(of: recorded),
      stateAfter: CanonicalJSON.sha256(of: before),
      differences: differences)
    return try repository.writeUnderTheLock(step, state: before)
  }

  /// The session of the project at one path. It starts one when no session carries that path.
  ///
  /// A session that starts here is named from the project Logic has open, so the state is read
  /// once for that. A project that already has a session is read once, under the lock, and not
  /// before it.
  private func session(ofProjectAt path: String) throws -> SessionRepository {
    let known = SessionIndex.session(atProjectPath: path, root: root)
    let starting: Session
    if let known {
      starting = known
    } else {
      starting = newSession(of: try driver.readState(), at: path)
    }
    let outcome = try SessionIndex.repository(
      forProjectPath: path, startingWith: starting, root: root, git: git, lock: lock)
    return outcome.repository
  }

  /// The session a project with no history starts with.
  private func newSession(of state: State, at path: String) -> Session {
    Session(
      createdAt: now(),
      project: Session.Project(name: state.project.name, path: path, createdByLogicctl: false),
      versions: Session.Versions(
        logicctl: version, logic: state.logic.version, macos: Run.macosVersion()))
  }

  /// The state the session recorded last, or nothing when it recorded none.
  private func storedState(of repository: SessionRepository) -> JSONValue? {
    let file = repository.folder.appendingPathComponent("state.json")
    guard let data = try? Data(contentsOf: file),
      let value = try? CanonicalJSON.value(of: String(decoding: data, as: UTF8.self))
    else {
      return nil
    }
    return value
  }

  /// What the command did: its answer, or the failure it stopped with.
  private func outcome(of command: any LogicCommand) -> (data: JSONValue?, failure: Failure?) {
    do {
      return (try command.act(through: driver), nil)
    } catch {
      return (nil, Run.failure(for: error))
    }
  }

  /// The envelope of what the command did.
  private func envelope(of done: (data: JSONValue?, failure: Failure?), meta: Meta) -> Envelope {
    guard let failure = done.failure else {
      return Envelope.success(data: done.data, meta: meta)
    }
    return Envelope.failure(failure, meta: meta)
  }

  /// The version of macOS the run is on.
  static func macosVersion() -> String {
    let running = ProcessInfo.processInfo.operatingSystemVersion
    return "\(running.majorVersion).\(running.minorVersion).\(running.patchVersion)"
  }

  /// The failure that an error stopped the command with.
  ///
  /// A driver names its refusal with the word the design system uses, so the two join here and a
  /// driver carries no code of its own.
  static func failure(for error: Error) -> Failure {
    if let refusal = error as? DriverRefusal, let code = ErrorCode(rawValue: refusal.rawValue) {
      return Failure(code: code, message: sentence(of: code))
    }
    if error is Git.Refusal || error is Lock.Refusal {
      return Failure(
        code: .journalFailed,
        message: "The session could not be written.",
        details: .object(["reason": .string(String(describing: error))]))
    }
    return Failure(
      code: .internalFailure,
      message: "The command stopped with a failure that logicctl has no code for.",
      details: .object(["reason": .string(String(describing: error))]))
  }

  /// One sentence a person can act on, for the codes a driver refuses with.
  static func sentence(of code: ErrorCode) -> String {
    switch code {
    case .logicNotRunning:
      return "Logic is not running, so there is no project to read."
    default:
      return "The command stopped with \(code.rawValue)."
    }
  }
}
