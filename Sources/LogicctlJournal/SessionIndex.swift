import Foundation
import LogicctlCore

/// How a command finds the session of the project that is open in Logic.
///
/// A `.logicx` carries no id, so logicctl knows a project by its path. Every session records the
/// path of its project, and a lookup reads those records. A project that no session carries
/// starts one, so no command of logicctl is ever unrecorded.
public enum SessionIndex {
  /// The answer of a lookup: the repository to write into, and which of the two things happened.
  public enum Outcome: Sendable {
    /// A session already carried the path, so the work goes on in that one.
    case found(SessionRepository)

    /// No session carried the path, so this session started.
    case started(SessionRepository)

    /// The repository to write the step into, whichever of the two happened.
    public var repository: SessionRepository {
      switch self {
      case .found(let repository):
        return repository
      case .started(let repository):
        return repository
      }
    }

    /// True when the lookup started the session.
    public var didStart: Bool {
      switch self {
      case .found:
        return false
      case .started:
        return true
      }
    }
  }

  /// The repository of the project at one path. It starts a session when none carries the path.
  ///
  /// A session that starts here takes the path it was looked up by, so the next command on the
  /// same project finds this session instead of starting a second one.
  public static func repository(
    forProjectPath path: String,
    startingWith newSession: Session,
    root: URL = SessionRepository.defaultRoot,
    state: State? = nil,
    git: Git = Git(),
    lock: Lock = Lock()
  ) throws -> Outcome {
    if let found = session(atProjectPath: path, root: root) {
      let folder = SessionRepository.sessionFolder(of: found, underRoot: root)
      return .found(SessionRepository(folder: folder, session: found, git: git, lock: lock))
    }
    var starting = newSession
    starting.project.path = path
    let started = try SessionRepository.start(
      session: starting, root: root, state: state, git: git, lock: lock)
    return .started(started)
  }

  /// The session of the project at one path, or nothing when no session carries it.
  ///
  /// Two sessions can carry one path, because `sessions --relink` points a session at a project
  /// that another session already recorded. The newest one wins, so the work goes on in the
  /// session that was started last.
  public static func session(
    atProjectPath path: String,
    root: URL = SessionRepository.defaultRoot
  ) -> Session? {
    sessions(underRoot: root)
      .filter { $0.project.path == path }
      .max { $0.createdAt < $1.createdAt }
  }

  /// Every session under one root, read from the `session.json` of each folder.
  ///
  /// A folder with nothing readable in it is passed over and not reported, because a folder a
  /// command is still writing must not stop the command that comes next.
  public static func sessions(underRoot root: URL = SessionRepository.defaultRoot) -> [Session] {
    let folder = SessionRepository.sessionsFolder(underRoot: root)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.sorted().compactMap { name in
      let file = folder.appendingPathComponent(name).appendingPathComponent("session.json")
      guard let data = try? Data(contentsOf: file),
        let read = try? CanonicalJSON.value(of: String(decoding: data, as: UTF8.self))
      else {
        return nil
      }
      return Session(json: read)
    }
  }
}
