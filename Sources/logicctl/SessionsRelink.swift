import Foundation
import LogicctlCore
import LogicctlJournal

/// `sessions --relink <session> <path>`: the session that holds the work follows the project file.
///
/// The listing answers which sessions there are. This is the one thing the command changes, and
/// it changes it because logicctl knows a project by where it sits. A person who moves a project
/// file would otherwise come back to a second session, started by the next command, with the work
/// of one project in two histories.
extension Sessions {
  /// How many values `--relink` takes: the session, then the new path.
  static let relinkValues = 2

  /// Points one session at a project that moved, prints the envelope, and answers the number the
  /// process exits with.
  ///
  /// The printer and the meta come from the command, so a relink and a listing answer in the one
  /// envelope and with the one layout a person asked for.
  static func relinked(
    _ values: [String],
    root: URL,
    git: Git,
    printer: EnvelopePrinter,
    meta: () -> Meta
  ) -> Int32 {
    guard values.count == Sessions.relinkValues else {
      return printer.write(Envelope.failure(Sessions.malformedRelink(values), meta: meta()))
    }
    do {
      let done = try Relink.session(
        withId: values[0], toPath: values[1], underRoot: root, git: git)
      return printer.write(Envelope.success(data: done.json, meta: meta()))
    } catch let refusal as Relink.Refusal {
      return printer.write(Envelope.failure(Sessions.refused(refusal), meta: meta()))
    } catch {
      return printer.write(Envelope.failure(Sessions.notRelinked(error), meta: meta()))
    }
  }

  /// The failure a `--relink` that is not a session and a path stops the command with.
  static func malformedRelink(_ values: [String]) -> Failure {
    Failure(
      code: .invalidArgument,
      message: "Give --relink the session and the new path, in that order.",
      details: .object(["values": .number(Double(values.count))]))
  }

  /// The failure a relink that cannot be done stops the command with.
  ///
  /// Both are `invalid_argument`: a person named a session or a path, Logic was never asked
  /// anything, and nothing was written. A relink to the path the session already carries is
  /// refused here rather than written, because nothing would change and git refuses a commit that
  /// carries no change, so the person would read a failure of git instead of a sentence.
  static func refused(_ refusal: Relink.Refusal) -> Failure {
    switch refusal {
    case .noSuchSession(let id):
      return Failure(
        code: .invalidArgument,
        message: "No session has the id \(id).",
        details: .object(["session": .string(id)]))
    case .alreadyAtThatPath(let id, let path):
      return Failure(
        code: .invalidArgument,
        message: "That session already carries that path.",
        details: .object(["session": .string(id), "path": .string(path)]))
    }
  }

  /// The failure a relink that could not be written stops the command with.
  ///
  /// `journal_failed` and not `internal`: this command does write, and what failed is the write.
  static func notRelinked(_ error: Error) -> Failure {
    Failure(
      code: .journalFailed,
      message: "The new path could not be written.",
      details: .object(["reason": .string(String(describing: error))]))
  }
}
