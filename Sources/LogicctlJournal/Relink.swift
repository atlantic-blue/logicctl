import Foundation
import LogicctlCore

/// What a relink changed: the session that moved, where its project sat, and where it sits now.
public struct Relinked: Sendable, Equatable {
  /// The id of the session that was relinked.
  public var session: String

  /// Where the project sat before, or nothing when the session carried no path.
  public var pathBefore: String?

  /// Where the project sits now.
  public var pathAfter: String

  /// The commit that carries the change.
  public var commit: String

  public init(session: String, pathBefore: String?, pathAfter: String, commit: String) {
    self.session = session
    self.pathBefore = pathBefore
    self.pathAfter = pathAfter
    self.commit = commit
  }

  /// The relink as `sessions --relink` prints it. A field that is not there is null and never
  /// absent.
  public var json: JSONValue {
    .object([
      "session": .string(session),
      "pathBefore": pathBefore.map(JSONValue.string) ?? .null,
      "pathAfter": .string(pathAfter),
      "commit": .string(commit),
    ])
  }
}

/// Points a session at a project that moved.
///
/// logicctl knows a project by where it sits, because a `.logicx` carries no id. A project that
/// moved therefore reads as a project nobody recorded, and the next command starts a second
/// session for it. A relink writes the new path into the session that already holds the work, so
/// one project keeps one history across a move.
public enum Relink {
  /// What a relink can refuse.
  public enum Refusal: Error, Equatable {
    /// No session under the root carries that id.
    case noSuchSession(id: String)

    /// The session already carries that path, so there is nothing to write.
    case alreadyAtThatPath(id: String, path: String)
  }

  /// Writes the new path of one session, and answers what changed.
  ///
  /// The session is named by the whole id, the one that `sessions` prints. A folder name carries
  /// the first eight characters, and two sessions can share those, so a short id would move a
  /// session a person did not name.
  @discardableResult
  public static func session(
    withId id: String,
    toPath path: String,
    underRoot root: URL = SessionRepository.defaultRoot,
    git: Git = Git(),
    lock: Lock = Lock()
  ) throws -> Relinked {
    guard let found = SessionIndex.sessions(underRoot: root).first(where: { $0.id == id }) else {
      throw Refusal.noSuchSession(id: id)
    }
    guard found.project.path != path else {
      throw Refusal.alreadyAtThatPath(id: id, path: path)
    }
    let repository = SessionRepository(
      folder: SessionRepository.sessionFolder(of: found, underRoot: root),
      session: found,
      git: git,
      lock: lock)
    let commit = try repository.writeRelink(to: path)
    return Relinked(
      session: found.id, pathBefore: found.project.path, pathAfter: path, commit: commit)
  }
}

extension SessionRepository {
  /// Writes the new path of the project into `session.json` as one commit, and answers the id of
  /// that commit.
  ///
  /// The subject carries no number. A listing reads a commit as a step when its subject starts
  /// with one, and a project that moved is nothing that was done to Logic, so a number here would
  /// add a step to the count of every session that ever moved.
  ///
  /// The writer holds the lock of the session, because a command or the watcher may be writing a
  /// step into the same repository, and a repository has one index.
  func writeRelink(to path: String) throws -> String {
    try lock.holding(folder) { () throws -> String in
      var moved = session
      moved.project.path = path
      try writeText(CanonicalJSON.text(of: moved.json, indent: 2), to: "session.json")
      try git.run(["add", "--", "session.json"], in: folder)
      try commit(subject: "relink " + session.shortId, trailers: [])
      return try head()
    }
  }
}
