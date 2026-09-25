import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal

/// Prints what logicctl did to a project, newest first.
///
/// Every command of logicctl that touches Logic is one commit in the session of that project, and
/// every change a person made by hand is one too. So the history is already there, in git. This
/// command reads it back as the JSON every other command answers in, so a person or an agent reads
/// what happened without opening a repository, and `show` then reads one step of it in full.
///
/// It reads the journal and never Logic. So it takes no lock, it writes no step, and its answer
/// carries no session and no step in `meta`, the way the data model asks. Which session the rows
/// came from is in the answer itself.
struct Log: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "log",
    abstract: "Print the steps of the current session, newest first.",
    discussion: """
      Each step carries its number, the commit that holds it, the time it started, the command \
      that ran and the number it exited with. A step that no command wrote carries no command.

      Example: logicctl log --pretty
      """)

  @OptionGroup var output: OutputOption

  func run() throws {
    let status = Log.answer(format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension Log {
  /// Reads the history of the current session, prints the envelope, and answers the number the
  /// process exits with.
  ///
  /// The root and the git are given, so a test reads a session it wrote in a folder of its own and
  /// never the sessions of the operator.
  static func answer(
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
      // Nothing has been recorded on this Mac yet. That is an empty history and not a failure:
      // the question "what did logicctl do" has an answer, and the answer is nothing.
      return printer.write(Envelope.success(data: Log.data(of: [], session: nil), meta: meta()))
    }

    do {
      let rows = try History.rows(of: repository)
      return printer.write(
        Envelope.success(
          data: Log.data(of: rows, session: repository.session.id), meta: meta()))
    } catch {
      return printer.write(Envelope.failure(Log.failure(for: error), meta: meta()))
    }
  }

  /// What the command answers with: the session the rows came from, and the rows.
  static func data(of rows: [HistoryRow], session: String?) -> JSONValue {
    .object([
      "session": session.map(JSONValue.string) ?? .null,
      "steps": .array(rows.map(\.json)),
    ])
  }

  /// The failure a history that could not be read stops the command with.
  ///
  /// There is no code for a history that is damaged. `journal_failed` is the code of a step that
  /// could not be written, and this command writes nothing, so what is left is `internal` with the
  /// cause in the message.
  static func failure(for error: Error) -> Failure {
    Failure(
      code: .internalFailure,
      message: "The history of the session could not be read.",
      details: .object(["reason": .string(String(describing: error))]))
  }
}
