import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal

/// Prints one step of the current session in full.
///
/// `log` answers what happened and in what order. This command answers one of those steps: what
/// was typed, what came back, and the hash of the project before the step and after it. The two
/// hashes are what a replay is held to, and what makes a change nobody typed visible, so the
/// answer of the tool and the history git keeps must carry the same pair.
///
/// It reads the journal and never Logic. So it takes no lock, it writes no step, and its answer
/// carries no session and no step in `meta`, the way the data model asks. Which session the step
/// came from is in the answer itself.
struct Show: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Print one step of the current session.",
    discussion: """
      The step is the number `log` prints, counted from 1. The answer carries the command and its \
      arguments, the result, the hash of the state before the step and after it, and the picture \
      of the window, at a path inside the session repository.

      Example: logicctl show 2
      """)

  @Argument(help: "The step of the session, counted from 1.")
  var step: OneBasedIndex

  @OptionGroup var output: OutputOption

  func run() throws {
    let status = Show.answer(step: step.value, format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension Show {
  /// Reads one step of the current session, prints the envelope, and answers the number the
  /// process exits with.
  ///
  /// The root and the git are given, so a test reads a session it wrote in a folder of its own and
  /// never the sessions of the operator.
  static func answer(
    step: Int,
    root: URL = SessionRepository.defaultRoot,
    git: Git = Git(),
    format: OutputFormat = .compact,
    now: () -> Date = { Date() },
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    // This command reads no Logic, so it carries no session and no step in `meta`.
    func meta() -> Meta {
      AnswerMeta.refusal(version: Logicctl.version, from: started, to: now())
    }

    guard let repository = History.currentSession(underRoot: root, git: git) else {
      return printer.write(Envelope.failure(Show.missing(step: step, of: 0), meta: meta()))
    }

    let rows: [HistoryRow]
    do {
      rows = try History.rows(of: repository)
    } catch {
      return printer.write(Envelope.failure(Show.unreadable(error), meta: meta()))
    }

    guard let row = rows.first(where: { $0.seq == step }) else {
      return printer.write(
        Envelope.failure(Show.missing(step: step, of: rows.count), meta: meta()))
    }

    guard let data = Show.data(of: row, in: repository) else {
      let refusal = History.Refusal.unreadableStep(sequence: step)
      return printer.write(Envelope.failure(Show.unreadable(refusal), meta: meta()))
    }
    return printer.write(Envelope.success(data: data, meta: meta()))
  }

  /// What the command answers with: the step, as the record of it holds it.
  ///
  /// Nothing is answered from the row alone. The row comes from `git log` and carries what a
  /// listing needs, and the record beside it carries what was typed and what came back. A field
  /// that the record does not hold stops the read, because a step that prints with a field empty
  /// reads exactly like a step that happened that way.
  static func data(of row: HistoryRow, in repository: SessionRepository) -> JSONValue? {
    guard case .object(let record) = SaveLookup.record(ofSequence: row.seq, in: repository),
      case .array(let argv) = record["argv"] ?? .null,
      case .string(let startedAt) = record["startedAt"] ?? .null,
      case .string(let finishedAt) = record["finishedAt"] ?? .null
    else {
      return nil
    }

    var members: [String: JSONValue] = [:]
    members["seq"] = .number(Double(row.seq))
    members["kind"] = .string(row.kind.rawValue)
    members["command"] = row.command.map(JSONValue.string) ?? .null
    members["argv"] = .array(argv)
    members["exitCode"] = .number(Double(row.exitCode))
    // The hashes arrive in the next commit. This one answers none, so the scenario runs and
    // fails on the pair it reads back rather than on a build.
    members["stateBefore"] = .null
    members["stateAfter"] = .null
    members["screenshot"] = Show.picture(ofSequence: row.seq, in: record)
    members["commit"] = .string(row.commit)
    members["startedAt"] = .string(startedAt)
    members["finishedAt"] = .string(finishedAt)
    members["session"] = .string(repository.session.id)
    members["versions"] = repository.session.versions.json
    return .object(members)
  }

  /// Where the picture of one step sits, inside the session repository, or null when the capture
  /// failed.
  ///
  /// The record holds the name of the file alone, because every step names it the same. A person
  /// opening the picture needs to know which step it belongs to, so the answer carries the path
  /// from the repository down to it.
  static func picture(ofSequence sequence: Int, in record: [String: JSONValue]) -> JSONValue {
    guard case .string(let name) = record["screenshot"] ?? .null else {
      return .null
    }
    return .string("steps/" + SessionRepository.stepFolderName(ofSequence: sequence) + "/" + name)
  }

  /// The failure a step the session does not hold stops the command with.
  ///
  /// There is no code for a step that is not there. The number came from a person, Logic was never
  /// asked anything, and nothing changed, which is what `invalid_argument` is for.
  static func missing(step: Int, of held: Int) -> Failure {
    Failure(
      code: .invalidArgument,
      message: "The session has no step \(step).",
      details: .object([
        "step": .number(Double(step)),
        "steps": .number(Double(held)),
      ]))
  }

  /// The failure a step that cannot be read stops the command with.
  ///
  /// `journal_failed` is the code of a step that could not be written, and this command writes
  /// nothing, so what is left is `internal` with the cause in the message.
  static func unreadable(_ error: Error) -> Failure {
    Failure(
      code: .internalFailure,
      message: "The step could not be read.",
      details: .object(["reason": .string(String(describing: error))]))
  }
}
