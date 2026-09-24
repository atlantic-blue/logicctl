import Foundation
import LogicctlCore
import LogicctlJournal

/// Who a project belongs to, and what logicctl may do to it on its own word.
///
/// `new-project` makes a project, and the session of that project records it. Every other project
/// belongs to a person: they wrote the work in it, and logicctl is a guest. So a command that
/// would change one of those stops before it acts, and the person goes again with `--confirm`.
struct ProjectGuard {
  /// The folder every session sits under.
  let root: URL

  /// Why the guard stopped a command.
  struct Refused: Error, Equatable {
    /// Where the project of the person sits.
    let path: String

    /// The failure the caller prints and exits with.
    var failure: Failure {
      Failure(
        code: .confirmRequired,
        message: "logicctl did not make this project, so a change to it needs --confirm.",
        details: .object(["project": .string(path)]))
    }
  }

  /// Stops a change to a project that logicctl did not make.
  ///
  /// A project that no session carries is a project logicctl never made, so it is guarded like
  /// any other project of a person. A project that was never saved sits at no path: it is the
  /// project `new-project` just made, and there is nothing of a person in it to protect.
  func check(theProjectAt path: String?) throws {
    guard let path else {
      return
    }
    let session = SessionIndex.session(atProjectPath: path, root: root)
    guard session?.project.createdByLogicctl != true else {
      return
    }
    throw Refused(path: path)
  }
}

extension Run {
  /// Runs one command that changes the project, through the guard.
  ///
  /// The guard reads the session of the open project before the command acts. A change to a
  /// project logicctl did not make stops there, with `confirm_required`, and `--confirm` is the
  /// only way past it. A refusal acts on nothing, so the project is as the person left it and
  /// their session gains no step.
  func run(change command: any LogicCommand, confirmed: Bool) -> Envelope {
    let started = now()
    if !confirmed {
      do {
        try ProjectGuard(root: root).check(theProjectAt: try driver.projectPath())
      } catch let refused as ProjectGuard.Refused {
        return Envelope.failure(
          refused.failure,
          meta: AnswerMeta.refusal(version: version, from: started, to: now()))
      } catch {
        return Envelope.failure(
          Run.failure(for: error),
          meta: AnswerMeta.refusal(version: version, from: started, to: now()))
      }
    }
    return run(command: command)
  }
}
