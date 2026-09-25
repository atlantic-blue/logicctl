import Foundation
import LogicctlCore

/// One step of a session, as a reader of its history answers it.
///
/// The row carries the number of the step and the commit that holds it. The number is what `show`
/// takes, and the commit is what `git log` prints, so the answer of logicctl and the history git
/// holds can be read against each other.
public struct HistoryRow: Sendable, Equatable {
  /// The number of the step, from 1, with no gap inside a session.
  public var seq: Int

  /// The commit that holds the step.
  public var commit: String

  /// What wrote the step.
  public var kind: Step.Kind

  /// The subcommand, for example `tracks mute`. Nothing for a step that no command wrote.
  public var command: String?

  /// When the step started.
  public var startedAt: Date

  /// The number the step exited with.
  public var exitCode: Int

  public init(
    seq: Int,
    commit: String,
    kind: Step.Kind,
    command: String? = nil,
    startedAt: Date,
    exitCode: Int
  ) {
    self.seq = seq
    self.commit = commit
    self.kind = kind
    self.command = command
    self.startedAt = startedAt
    self.exitCode = exitCode
  }

  /// The row as `log` prints it. A field that is not there is null and never absent.
  public var json: JSONValue {
    .object([
      "step": .number(Double(seq)),
      "commit": .string(commit),
      "kind": .string(kind.rawValue),
      "command": command.map(JSONValue.string) ?? .null,
      "time": .string(Moment.text(of: startedAt)),
      "exitCode": .number(Double(exitCode)),
    ])
  }
}

/// Reads the history of one session.
///
/// The order comes from git and not from a sort written here. A session is one line of commits, so
/// `git log` answers newest first, and a reader that took the folders under `steps/` instead would
/// be answering from a listing that has its own order and no commits in it at all.
public enum History {
  /// What reading a history can refuse.
  public enum Refusal: Error, Equatable {
    /// A commit names a step whose record cannot be read.
    case unreadableStep(sequence: Int)
  }

  /// The steps of one session, newest first.
  ///
  /// A commit whose record cannot be read stops the whole read. The steps of a session are its
  /// history, and a history with one step quietly left out reads exactly like a history that never
  /// held it.
  public static func rows(of repository: SessionRepository) throws -> [HistoryRow] {
    let printed = try repository.git.run(["log", "--reverse", "--format=%H %s"], in: repository.folder)
    var rows: [HistoryRow] = []
    for line in printed.split(separator: "\n") {
      let fields = line.split(separator: " ", maxSplits: 1)
      // The subject of a step starts with its number. The first commit of a session names the
      // session and carries no number, because it started the work and did nothing to Logic.
      guard fields.count == 2, let sequence = Int(fields[1].prefix(while: \.isNumber)) else {
        continue
      }
      guard let row = row(ofSequence: sequence, commit: String(fields[0]), in: repository) else {
        throw Refusal.unreadableStep(sequence: sequence)
      }
      rows.append(row)
    }
    return rows
  }

  /// The session logicctl worked in last, or nothing when no session was ever started.
  ///
  /// `log` reads the journal and never Logic, so it cannot ask which project Logic has open. The
  /// session that was started last is the one the work is in.
  public static func currentSession(
    underRoot root: URL = SessionRepository.defaultRoot,
    git: Git = Git(),
    lock: Lock = Lock()
  ) -> SessionRepository? {
    guard
      let newest = SessionIndex.sessions(underRoot: root).max(by: { $0.createdAt < $1.createdAt })
    else {
      return nil
    }
    let folder = SessionRepository.sessionFolder(of: newest, underRoot: root)
    return SessionRepository(folder: folder, session: newest, git: git, lock: lock)
  }

  /// One row from the record of one step, or nothing when the record does not hold a step.
  static func row(
    ofSequence sequence: Int, commit: String, in repository: SessionRepository
  ) -> HistoryRow? {
    guard case .object(let members) = SaveLookup.record(ofSequence: sequence, in: repository),
      case .string(let kind) = members["kind"] ?? .null,
      let written = Step.Kind(rawValue: kind),
      case .string(let startedAt) = members["startedAt"] ?? .null,
      let moment = Moment.moment(of: startedAt),
      case .number(let exitCode) = members["exitCode"] ?? .null
    else {
      return nil
    }
    var command: String?
    if case .string(let named) = members["command"] ?? .null {
      command = named
    }
    return HistoryRow(
      seq: sequence,
      commit: commit,
      kind: written,
      command: command,
      startedAt: moment,
      exitCode: Int(exitCode))
  }
}
