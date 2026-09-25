import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal

/// Prints every session logicctl recorded on this Mac.
///
/// `log` and `show` read one session, the one the work is in. This command answers which sessions
/// there are. A person who worked on several projects finds the one they want by its project and
/// its path, and the count of steps says how much of the work each session holds, so a session
/// that was started and left is told apart from the session that carries the work.
///
/// It reads the journal and never Logic. So it takes no lock, it writes no step, and its answer
/// carries no session and no step in `meta`, the way the data model asks.
struct Sessions: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sessions",
    abstract: "Print every session logicctl recorded on this Mac.",
    discussion: """
      Each session carries its id, the project it belongs to, where that project sits and how \
      many steps it holds. A project that was never saved carries no path. The newest session \
      comes first.

      A project that moved is pointed at its new path with --relink, which takes the id of the \
      session and then the path. The work goes on in the session that already holds it.

      Example: logicctl sessions --pretty
      """)

  @Option(
    parsing: .upToNextOption,
    help: "Point a session at a project that moved: its id, then the new path.")
  var relink: [String] = []

  @OptionGroup var output: OutputOption

  /// Refuses a --relink that is not a session and a path, before anything is read or written.
  func validate() throws {
    guard relink.isEmpty || relink.count == Sessions.relinkValues else {
      throw ValidationError("Give --relink the session and the new path, in that order.")
    }
  }

  func run() throws {
    let status = Sessions.answer(relink: relink, format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension Sessions {
  /// Reads every session under one root, or relinks one of them, prints the envelope, and answers
  /// the number the process exits with.
  ///
  /// The root and the git are given, so a test reads sessions it wrote in a folder of its own and
  /// never the sessions of the operator.
  static func answer(
    relink: [String] = [],
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

    guard relink.isEmpty else {
      return Sessions.relinked(relink, root: root, git: git, printer: printer, meta: meta)
    }

    do {
      let rows = try SessionList.rows(underRoot: root, git: git)
      return printer.write(Envelope.success(data: Sessions.data(of: rows), meta: meta()))
    } catch {
      return printer.write(Envelope.failure(Sessions.failure(for: error), meta: meta()))
    }
  }

  /// What the command answers with: one row for each session.
  ///
  /// Nothing recorded on this Mac yet is an empty list and not a failure. The question "which
  /// sessions are there" has an answer, and the answer is none.
  static func data(of rows: [SessionRow]) -> JSONValue {
    .object(["sessions": .array(rows.map(\.json))])
  }

  /// The failure a session that cannot be read stops the command with.
  ///
  /// There is no code for a journal that is damaged. `journal_failed` is the code of a step that
  /// could not be written, and this command writes nothing, so what is left is `internal` with the
  /// cause in the message.
  static func failure(for error: Error) -> Failure {
    Failure(
      code: .internalFailure,
      message: "The sessions could not be read.",
      details: .object(["reason": .string(String(describing: error))]))
  }
}
