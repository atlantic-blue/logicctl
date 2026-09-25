import Foundation
import LogicctlCore

/// One session, as a listing of the journal answers it.
///
/// The row carries what a person needs to pick one session out of many: which project it belongs
/// to, where that project sits, and how much work it holds. The count of steps is the part that
/// says a session carries work at all, because a session is started by the first command that
/// touches a project and a session that was started and left holds nothing.
public struct SessionRow: Sendable, Equatable {
  /// The id of the session.
  public var id: String

  /// The name of the project the session belongs to.
  public var project: String

  /// Where the project sits, or nothing until the first save.
  public var path: String?

  /// How many steps the session holds.
  public var steps: Int

  public init(id: String, project: String, path: String? = nil, steps: Int) {
    self.id = id
    self.project = project
    self.path = path
    self.steps = steps
  }

  /// The row as `sessions` prints it. A field that is not there is null and never absent.
  public var json: JSONValue {
    .object([
      "id": .string(id),
      "project": .string(project),
      "path": path.map(JSONValue.string) ?? .null,
      "steps": .number(Double(steps)),
    ])
  }
}

/// Reads every session logicctl recorded under one root.
///
/// The steps of a session are its commits, so the count comes from git and not from the folders
/// under `steps/`. A folder is a listing of what is on disk, and a step is a commit; the two can
/// differ, and the commit is the record.
public enum SessionList {
  /// What listing the sessions can refuse.
  public enum Refusal: Error, Equatable {
    /// The history of one session cannot be read, so its count of steps is not known.
    case unreadableHistory(session: String)
  }

  /// Every session under one root, newest first.
  ///
  /// A session whose history cannot be read stops the whole listing. A count that fell back to
  /// zero would read exactly like a session that was started and never used, and a person reading
  /// the listing to find their work would pass over the one session that holds it.
  public static func rows(
    underRoot root: URL = SessionRepository.defaultRoot,
    git: Git = Git()
  ) throws -> [SessionRow] {
    let newestFirst = SessionIndex.sessions(underRoot: root)
      .sorted { $0.createdAt > $1.createdAt }
    var rows: [SessionRow] = []
    for session in newestFirst {
      let held = try steps(of: session, underRoot: root, git: git)
      rows.append(
        SessionRow(
          id: session.id,
          project: session.project.name,
          path: session.project.path,
          steps: held))
    }
    return rows
  }

  /// How many steps one session holds.
  ///
  /// The subject of a step starts with its number. The first commit of a session names the session
  /// and carries no number, because it started the work and did nothing to Logic, so it is not a
  /// step and it is not counted.
  static func steps(of session: Session, underRoot root: URL, git: Git) throws -> Int {
    let folder = SessionRepository.sessionFolder(of: session, underRoot: root)
    do {
      _ = try git.run(["log", "--format=%s"], in: folder)
    } catch {
      throw Refusal.unreadableHistory(session: session.id)
    }
    // The count arrives in the next commit. This one answers none, so the scenario runs and fails
    // on the counts it reads back rather than on a build.
    return 0
  }
}
