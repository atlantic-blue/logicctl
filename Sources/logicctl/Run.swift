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
  func run(command: any LogicCommand) -> Envelope {
    let started = now()
    do {
      _ = try driver.projectPath()
      let data = try command.act(through: driver)
      return Envelope.success(
        data: data,
        meta: AnswerMeta.run(
          version: version, session: nil, step: nil, externalChange: nil, from: started,
          to: now()))
    } catch {
      return Envelope.failure(
        Run.failure(for: error),
        meta: AnswerMeta.refusal(version: version, from: started, to: now()))
    }
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
