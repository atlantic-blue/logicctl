import Foundation
import LogicctlCore

/// One time as one text, RFC 3339 in UTC, as the output rules ask.
///
/// The form is fixed here and not left to a formatter, because a record must not move when the
/// machine reads another locale or another time zone.
enum Moment {
  static func text(of moment: Date) -> String {
    moment.formatted(
      Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .standard,
        timeSeparator: .colon,
        timeZoneSeparator: .omitted,
        includingFractionalSeconds: false,
        timeZone: .gmt))
  }
}

/// What `session.json` holds: the work of logicctl on one project.
public struct Session: Sendable, Equatable {
  /// The project the session belongs to.
  public struct Project: Sendable, Equatable {
    /// The name in the title of the Logic window.
    public var name: String

    /// Where the project sits, or null until the first save.
    public var path: String?

    /// True when `new-project` made it. A change to a project of a person needs `--confirm`.
    public var createdByLogicctl: Bool

    public init(name: String, path: String? = nil, createdByLogicctl: Bool = false) {
      self.name = name
      self.path = path
      self.createdByLogicctl = createdByLogicctl
    }

    /// This part of `session.json` as a JSON value.
    public var json: JSONValue {
      .object([
        "name": .string(name),
        "path": path.map { JSONValue.string($0) } ?? .null,
        "createdByLogicctl": .bool(createdByLogicctl),
      ])
    }
  }

  /// The session that `replay` read, for a session that `replay` wrote.
  public struct ReplayOf: Sendable, Equatable {
    /// The id of the session that was replayed.
    public var session: String

    /// The first commit that was replayed.
    public var from: String

    /// The last commit that was replayed.
    public var to: String

    public init(session: String, from: String, to: String) {
      self.session = session
      self.from = from
      self.to = to
    }

    /// This part of `session.json` as a JSON value.
    public var json: JSONValue {
      .object([
        "session": .string(session),
        "from": .string(from),
        "to": .string(to),
      ])
    }
  }

  /// The versions of everything that took part in the session.
  public struct Versions: Sendable, Equatable {
    /// The version of logicctl.
    public var logicctl: String

    /// The version of Logic.
    public var logic: String

    /// The version of macOS.
    public var macos: String

    public init(logicctl: String, logic: String, macos: String) {
      self.logicctl = logicctl
      self.logic = logic
      self.macos = macos
    }

    /// This part of `session.json` as a JSON value.
    public var json: JSONValue {
      .object([
        "logicctl": .string(logicctl),
        "logic": .string(logic),
        "macos": .string(macos),
      ])
    }
  }

  /// The version of the schema the session was written with.
  public var schema: Int

  /// The id of the session, a version 4 UUID.
  public var id: String

  /// When the session started.
  public var createdAt: Date

  /// The project the session belongs to.
  public var project: Project

  /// What this session replayed, or null when a person asked for the work.
  public var replayOf: ReplayOf?

  /// The versions of everything that took part.
  public var versions: Versions

  public init(
    schema: Int = 1,
    id: String = UUID().uuidString.lowercased(),
    createdAt: Date = Date(),
    project: Project,
    replayOf: ReplayOf? = nil,
    versions: Versions
  ) {
    self.schema = schema
    self.id = id
    self.createdAt = createdAt
    self.project = project
    self.replayOf = replayOf
    self.versions = versions
  }

  /// The first eight characters of the id. The folder name and `git log` carry this much.
  public var shortId: String {
    String(id.prefix(8))
  }

  /// The name of the folder of the session.
  ///
  /// A project name carries whatever a person typed, and a folder name cannot, so every character
  /// outside the letters, the digits, the hyphen and the underscore becomes an underscore.
  public var folderName: String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    let safe = String(project.name.map { allowed.contains($0) ? $0 : "_" })
    return safe + "-" + shortId
  }

  /// The session as `session.json` holds it.
  public var json: JSONValue {
    .object([
      "schema": .number(Double(schema)),
      "id": .string(id),
      "createdAt": .string(Moment.text(of: createdAt)),
      "project": project.json,
      "replayOf": replayOf?.json ?? .null,
      "versions": versions.json,
    ])
  }
}

/// One session as it sits on disk: a git repository whose history is the work on one project.
public struct SessionRepository: Sendable {
  /// The author of every commit in a session repository.
  public static let authorName = "logicctl"

  /// The address of that author. Nobody pushes a session repository, so it is a local address.
  public static let authorEmail = "logicctl@localhost"

  /// The name of the picture of a step, inside the folder of that step.
  public static let screenshotName = "screenshot.png"

  /// The author and the committer of every commit, given to git as its environment.
  static let authorEnvironment = [
    "GIT_AUTHOR_NAME": SessionRepository.authorName,
    "GIT_AUTHOR_EMAIL": SessionRepository.authorEmail,
    "GIT_COMMITTER_NAME": SessionRepository.authorName,
    "GIT_COMMITTER_EMAIL": SessionRepository.authorEmail,
  ]

  /// The folder of the repository.
  public let folder: URL

  /// What `session.json` holds.
  public let session: Session

  /// The git that writes the history.
  public let git: Git

  /// The lock that keeps a second writer out while a step is written.
  public let lock: Lock

  /// Where logicctl keeps its sessions when nobody names another folder.
  public static var defaultRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".logicctl")
  }

  /// The folder that every session of one root sits in.
  public static func sessionsFolder(underRoot root: URL) -> URL {
    root.appendingPathComponent("sessions")
  }

  /// The name of the folder of one step: the sequence as six digits.
  public static func stepFolderName(ofSequence sequence: Int) -> String {
    String(format: "%06d", sequence)
  }

  /// Starts a session repository and writes its first commit.
  ///
  /// The repository turns signing off in its own configuration, and the configuration of the
  /// operator stays as it is. A step is written by logicctl and not by a person, so a step must
  /// never wait for a key, fail for the want of one, or claim that a person signed it.
  public static func start(
    session: Session,
    root: URL = SessionRepository.defaultRoot,
    state: State? = nil,
    git: Git = Git(),
    lock: Lock = Lock()
  ) throws -> SessionRepository {
    let folder = sessionsFolder(underRoot: root).appendingPathComponent(session.folderName)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let repository = SessionRepository(folder: folder, session: session, git: git, lock: lock)

    try git.run(["init", "--quiet", "--initial-branch=main"], in: folder)
    try git.run(["config", "commit.gpgsign", "false"], in: folder)

    try repository.writeText(CanonicalJSON.text(of: session.json, indent: 2), to: "session.json")
    var staged = ["session.json"]
    if let state {
      try repository.writeText(CanonicalJSON.text(of: state, indent: 2), to: "state.json")
      staged.append("state.json")
    }
    try git.run(["add", "--"] + staged, in: folder)
    try repository.commit(subject: "session " + session.shortId, trailers: [])
    return repository
  }

  /// Writes one text into the repository. It ends with a newline, so git reads a whole line.
  func writeText(_ text: String, to relative: String) throws {
    try writeData(Data((text + "\n").utf8), to: relative)
  }

  /// Writes some bytes into the repository.
  func writeData(_ data: Data, to relative: String) throws {
    try data.write(to: folder.appendingPathComponent(relative), options: .atomic)
  }

  /// Commits what is staged, as logicctl, with the trailers on their own paragraph.
  ///
  /// The trailers go in one message and not in one each, because git reads a trailer only in the
  /// last paragraph of the message.
  func commit(subject: String, trailers: [String]) throws {
    var arguments = ["commit", "--quiet", "-m", subject]
    if !trailers.isEmpty {
      arguments.append("-m")
      arguments.append(trailers.joined(separator: "\n"))
    }
    try git.run(arguments, in: folder, environment: SessionRepository.authorEnvironment)
  }

  /// The commit the repository is on.
  func head() throws -> String {
    try git.run(["rev-parse", "HEAD"], in: folder)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
