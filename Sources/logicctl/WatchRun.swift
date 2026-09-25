import ArgumentParser
import Dispatch
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// The watcher itself, which launchd runs and nobody types.
///
/// Every other command writes a step because a person asked for something. A save is the one
/// change that happens without a command: somebody moves a knob, presses Command S, and the
/// project on disk changes while the history says nothing. This records that, so the journal
/// carries what a person did to the sound and names the plugin they changed.
///
/// It is hidden from the help because it is not a command of the grammar. `watch start` writes the
/// launch agent that runs it, and `watch stop` takes that agent away.
struct WatchRun: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Record a save a person makes in Logic.",
    discussion: """
      The launch agent of `logicctl watch start` runs this. It does not end on its own.

      Example: logicctl watch run
      """,
    shouldDisplay: false)

  func run() throws {
    let watcher = SaveWatcher()
    try watcher.watch()
    dispatchMain()
  }
}

/// What the watcher writes down about itself: one JSON object per line.
///
/// A launch agent has no terminal, so a person who asks what the watcher has been doing reads this
/// file. It is not the journal. A save that was recorded is a step in a session, and the line here
/// says which commit holds it; a save that was not recorded is only here, with the reason.
struct WatchLog: Sendable {
  /// The name of the file, under the folder logicctl keeps its sessions in.
  static let fileName = "watch.log"

  /// Where the lines go.
  let file: URL

  /// Writes one line, with the time the watcher read.
  func wrote(_ members: [String: JSONValue], at moment: Date) {
    var line = members
    line["time"] = .string(WatchLog.text(of: moment))
    append(CanonicalJSON.text(of: .object(line)) + "\n")
  }

  /// Adds one line to the end of the file, and makes the file when there is none.
  ///
  /// Nothing here throws. The watcher runs with nobody reading, so a log that cannot be written
  /// must not stop a save from being recorded.
  private func append(_ line: String) {
    let files = FileManager.default
    if !files.fileExists(atPath: file.path) {
      try? files.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      _ = files.createFile(atPath: file.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: file) else {
      return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
  }

  /// One time as one text, RFC 3339 in UTC, as the output rules ask.
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

/// Watches the project of every session, and writes one step for every save.
///
/// It reads no Logic. Logic may not even be running by the time this reads the file, so the state
/// it writes is the state the session recorded with the new plugin hashes over it, and nothing
/// else. A watcher that claimed a tempo or a track it never read would put drift in the history
/// rather than take it out.
final class SaveWatcher: @unchecked Sendable {
  /// What one save did to the journal.
  enum Recording: Equatable {
    /// The save is a step now, and this is its commit.
    case written(commit: String, differences: Int)

    /// Nothing was written, and this is why.
    case notRecorded(reason: String)
  }

  /// One plugin of the recorded state, in the order the state holds it.
  struct RecordedPlugin: Equatable {
    /// The place of the track in the state, from 0, which is what a pointer carries.
    let track: Int

    /// The place of the plugin in the channel strip, from 0.
    let slot: Int

    /// The name the state carries, or nothing when it carries none.
    let name: String?
  }

  /// What the named chunks of a saved project say about the plugins of the state.
  struct Mapping: Equatable {
    /// One hash for each plugin of the state, in the order the state holds them. Empty when the
    /// file and the state do not agree about the plugins.
    let hashes: [String]

    /// Why they do not agree, or nothing when they do.
    let reason: String?
  }

  /// The folder every session sits under.
  let root: URL

  /// What tells the watcher that a file changed.
  let source: any FileChangeSource

  /// Where the watcher writes down what it did.
  let log: WatchLog

  /// The clock the watcher reads.
  let now: @Sendable () -> Date

  /// The git that writes a session.
  let git: Git

  /// The lock that keeps the watcher and a command out of one session at once.
  let lock: Lock

  /// Keeps the two threads apart: this one, and the one macOS reports a change on.
  private let guardian = NSLock()

  /// The folders the source covers now.
  private var watching: [URL] = []

  /// Where a watch is started again, which is never the thread a change is reported on.
  private let work = DispatchQueue(label: "com.atlantic-blue.logicctl.watch.work")

  init(
    root: URL = SessionRepository.defaultRoot,
    source: any FileChangeSource = FileSystemEvents(),
    log: WatchLog? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    git: Git = Git(),
    lock: Lock = Lock()
  ) {
    self.root = root
    self.source = source
    self.log = log ?? WatchLog(file: root.appendingPathComponent(WatchLog.fileName))
    self.now = now
    self.git = git
    self.lock = lock
  }

  /// Starts watching every project a session carries.
  func watch() throws {
    try? FileManager.default.createDirectory(
      at: SessionRepository.sessionsFolder(underRoot: root), withIntermediateDirectories: true)
    try watch(folders: foldersToWatch())
  }

  /// The folders the watcher covers: the project of every session that sits on disk, and the
  /// folder the sessions themselves live in.
  ///
  /// The sessions folder is watched too, because a session that starts while the watcher runs must
  /// be picked up without a restart, and the file that says a session started is written there.
  func foldersToWatch() -> [URL] {
    var folders = [SessionRepository.sessionsFolder(underRoot: root)]
    for session in SessionIndex.sessions(underRoot: root) {
      guard let path = session.project.path else {
        continue
      }
      folders.append(SavedProject.folderToWatch(ofProjectAt: path))
    }
    return folders
  }

  /// One changed file, as the source reports it.
  func changed(_ path: String) {
    guard let project = SavedProject.projectPath(ofDataAt: path) else {
      // Everything else that moves under a watched folder is a reason to look for a session that
      // was not there when the watch started.
      refresh()
      return
    }
    record(saveOfProjectAt: project, readingDataAt: URL(fileURLWithPath: path))
  }

  /// Watches the projects of the sessions that are there now, when that is not what it watches
  /// already.
  func refresh() {
    let folders = foldersToWatch()
    guardian.lock()
    let held = watching
    guardian.unlock()
    guard folders.map(\.path) != held.map(\.path) else {
      return
    }
    // The stream is replaced away from the thread its own reports arrive on.
    work.async { [weak self] in
      guard let self else {
        return
      }
      do {
        try self.watch(folders: folders)
      } catch {
        let said: [String: JSONValue] = [
          "event": .string("not watching"), "reason": .string("\(error)"),
        ]
        self.log.wrote(said, at: self.now())
      }
    }
  }

  /// Writes one step for the save of one project, and answers what it did.
  ///
  /// The state is read, the step is built and the step is written while this holds the lock of the
  /// session, so a command that is running writes its own step before or after this one, and never
  /// into the middle of it.
  @discardableResult
  func record(saveOfProjectAt project: String, readingDataAt dataFile: URL) -> Recording {
    let moment = now()
    guard
      let repository = SessionIndex.repository(
        ofProjectAt: project, root: root, git: git, lock: lock)
    else {
      return refusal("no session carries the project at \(project)", of: project, at: moment)
    }
    let chunks: [ProjectData.PluginChunk]
    do {
      chunks = try ProjectData.pluginChunks(ofFileAt: dataFile)
    } catch {
      let reason = "the saved project at \(dataFile.path) could not be read: \(error)"
      return refusal(reason, of: project, at: moment)
    }
    do {
      return try repository.lock.holding(repository.folder) { () throws -> Recording in
        try write(saveOf: chunks, into: repository, of: project, at: moment)
      }
    } catch {
      return refusal("the save step was not written: \(error)", of: project, at: moment)
    }
  }

  /// Writes the step, while the caller holds the lock of the session.
  private func write(
    saveOf chunks: [ProjectData.PluginChunk], into repository: SessionRepository,
    of project: String, at moment: Date
  ) throws -> Recording {
    guard let recorded = storedState(of: repository) else {
      let reason = "the session of \(project) recorded no state, so there is nothing to compare"
      return refusal(reason, of: project, at: moment)
    }
    let plugins = SaveWatcher.plugins(of: recorded)
    let mapping = SaveWatcher.mapping(ofNamedChunks: chunks, onto: plugins)
    if let reason = mapping.reason {
      let said: [String: JSONValue] = [
        "event": .string("plugins not read"),
        "project": .string(project),
        "reason": .string(reason),
      ]
      log.wrote(said, at: moment)
    }
    let after = SaveWatcher.state(recorded, withPluginHashes: mapping.hashes)
    let differences = StateDiff.between(recorded, after)
    let step = Step(
      seq: repository.nextSequence(),
      kind: .save,
      startedAt: moment,
      finishedAt: moment,
      exitCode: 0,
      stateBefore: CanonicalJSON.sha256(of: recorded),
      stateAfter: CanonicalJSON.sha256(of: after),
      differences: differences)
    let commit = try repository.writeUnderTheLock(step, stateJSON: after)
    let said: [String: JSONValue] = [
      "event": .string("save"),
      "project": .string(project),
      "session": .string(repository.session.id),
      "commit": .string(commit),
      "differences": .number(Double(differences.count)),
    ]
    log.wrote(said, at: moment)
    return .written(commit: commit, differences: differences.count)
  }

  /// Writes down a save that was not recorded, and answers it.
  private func refusal(_ reason: String, of project: String, at moment: Date) -> Recording {
    let said: [String: JSONValue] = [
      "event": .string("not recorded"),
      "project": .string(project),
      "reason": .string(reason),
    ]
    log.wrote(said, at: moment)
    return .notRecorded(reason: reason)
  }

  /// The state the session recorded last, or nothing when it recorded none.
  private func storedState(of repository: SessionRepository) -> JSONValue? {
    let file = repository.folder.appendingPathComponent("state.json")
    guard let data = try? Data(contentsOf: file),
      let value = try? CanonicalJSON.value(of: String(decoding: data, as: UTF8.self))
    else {
      return nil
    }
    return value
  }

  /// Starts one watch over those folders.
  private func watch(folders: [URL]) throws {
    guardian.lock()
    watching = folders
    guardian.unlock()
    let said: [String: JSONValue] = [
      "event": .string("watching"), "folders": .number(Double(folders.count)),
    ]
    log.wrote(said, at: now())
    try source.start(watching: folders) { [weak self] path in
      self?.changed(path)
    }
  }
}

extension SaveWatcher {
  /// The plugins of the recorded state, in track order and then in slot order.
  ///
  /// This is the order a pointer into the state carries, so the answer says where each hash goes.
  static func plugins(of state: JSONValue) -> [RecordedPlugin] {
    guard case .object(let members) = state,
      case .array(let tracks) = members["tracks"] ?? .null
    else {
      return []
    }
    var found: [RecordedPlugin] = []
    for (track, carried) in tracks.enumerated() {
      guard case .object(let fields) = carried,
        case .array(let plugins) = fields["plugins"] ?? .null
      else {
        continue
      }
      for (slot, plugin) in plugins.enumerated() {
        guard case .object(let named) = plugin else {
          continue
        }
        var name: String?
        if case .string(let text) = named["name"] ?? .null {
          name = text
        }
        found.append(RecordedPlugin(track: track, slot: slot, name: name))
      }
    }
    return found
  }

  /// Which hash belongs to which plugin of the state.
  ///
  /// Logic writes the settings of one plugin as one chunk that carries its name, and it writes
  /// them in the order of the tracks, each track from its instrument down its channel strip. The
  /// chunks that carry no name hold something other than the settings of a plugin, and the named
  /// chunks after the last plugin of the last track belong to no track at all: the metronome is
  /// one of those.
  ///
  /// The names are read against the state as a check. A file that does not agree with the state
  /// means the two are about different projects, or that this reading of the file is wrong, and a
  /// hash written into the wrong slot would name the wrong plugin as the one a person changed.
  /// Nothing is written then, and the reason goes to the log.
  static func mapping(
    ofNamedChunks chunks: [ProjectData.PluginChunk], onto plugins: [RecordedPlugin]
  ) -> Mapping {
    let named = chunks.filter { $0.name != nil }
    guard named.count >= plugins.count else {
      var reason = "the saved project holds \(named.count) named plugin chunks, "
      reason += "and the state holds \(plugins.count) plugins"
      return Mapping(hashes: [], reason: reason)
    }
    for (place, plugin) in plugins.enumerated() {
      let carried = named[place].name ?? "a chunk with no name"
      guard let name = plugin.name, name == carried else {
        let held = plugin.name ?? "a plugin with no name"
        var reason = "the state holds \(held) in slot \(plugin.slot + 1) "
        reason += "of track \(plugin.track + 1), and the saved project holds \(carried) there"
        return Mapping(hashes: [], reason: reason)
      }
    }
    return Mapping(hashes: named.prefix(plugins.count).map(\.stateHash), reason: nil)
  }

  /// The recorded state with the hashes of this save over it.
  ///
  /// Everything else stays as the session recorded it, because the watcher reads a file and never
  /// Logic. An empty list of hashes leaves the state as it was.
  static func state(_ state: JSONValue, withPluginHashes hashes: [String]) -> JSONValue {
    guard !hashes.isEmpty, case .object(let read) = state,
      case .array(let tracks) = read["tracks"] ?? .null
    else {
      return state
    }
    var members = read
    var given = 0
    var written: [JSONValue] = []
    for carried in tracks {
      guard case .object(let held) = carried,
        case .array(let plugins) = held["plugins"] ?? .null
      else {
        written.append(carried)
        continue
      }
      var fields = held
      var reset: [JSONValue] = []
      for plugin in plugins {
        guard case .object(let carriedPlugin) = plugin, given < hashes.count else {
          reset.append(plugin)
          continue
        }
        var named = carriedPlugin
        named["stateHash"] = .string(hashes[given])
        given += 1
        reset.append(.object(named))
      }
      fields["plugins"] = .array(reset)
      written.append(.object(fields))
    }
    members["tracks"] = .array(written)
    return .object(members)
  }
}
