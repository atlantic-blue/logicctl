import Dispatch
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-watch-run-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A git whose configuration signs every commit, with a signing program that always fails.
///
/// Every test here writes a real repository, and a session repository turns signing off for
/// itself. So no test reads or writes the configuration of the operator.
private func gitThatSigns(inside folder: URL) throws -> Git {
  let configuration = folder.appendingPathComponent("gitconfig")
  let written = """
    [commit]
    \tgpgsign = true
    [gpg]
    \tprogram = /usr/bin/false
    """
  try Data(written.utf8).write(to: configuration, options: .atomic)
  return Git(environment: [
    "GIT_CONFIG_GLOBAL": configuration.path,
    "GIT_CONFIG_SYSTEM": "/dev/null",
  ])
}

/// Where the saved projects that the tests read sit.
///
/// The folder is read from the source tree, and not as a resource of this test target, because it
/// sits beside the test targets rather than inside one.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/projectdata")

/// The two saves of one project, one Channel EQ knob apart.
private let theProjectBeforeTheKnob = fixtureFolder.appending(path: "before")
private let theProjectAfterTheKnob = fixtureFolder.appending(path: "after")

/// A saved project of four tracks, measured on 2026-09-25 against Logic 12.3.1.
private let theProjectOfFourTracks = fixtureFolder.appending(path: "four-tracks")

/// The plugins of the project the `before` and `after` files hold, in track order and slot order.
private let thePluginsOfTheProject = [
  ["E-Piano", "Channel EQ"],
  ["E-Piano", "Compressor"],
  ["Piano", "Channel EQ", "Compressor", "ChromaVerb"],
  ["Piano", "Channel EQ", "Compressor", "ChromaVerb"],
]

/// The plugins of the project of four tracks. The third track is an audio track and carries none.
private let thePluginsOfTheFourTracks = [
  ["E-Piano", "Channel EQ"],
  ["E-Piano"],
  [],
  ["E-Piano"],
]

/// When the session of these tests started.
private let aMoment = Date(timeIntervalSince1970: 1_700_000_000)

/// The named plugin chunks of one saved project, which is the order Logic wrote them in.
private func namedChunks(of file: URL) throws -> [ProjectData.PluginChunk] {
  try ProjectData.pluginChunks(ofFileAt: file).filter { $0.name != nil }
}

/// The state a session recorded, with the plugin hashes one saved project gives.
private func aState(named names: [[String]], hashedFrom file: URL) throws -> State {
  let chunks = try namedChunks(of: file)
  var given = 0
  var tracks: [Track] = []
  for (place, carried) in names.enumerated() {
    var plugins: [Plugin] = []
    for (slot, name) in carried.enumerated() {
      let hash: String? = given < chunks.count ? chunks[given].stateHash : nil
      plugins.append(Plugin(slot: slot + 1, name: name, stateHash: hash))
      given += 1
    }
    tracks.append(
      Track(
        index: place + 1, name: "Track \(place + 1)",
        type: carried.isEmpty ? .audio : .softwareInstrument, plugins: plugins))
  }
  return State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(tempo: 120),
    tracks: tracks)
}

/// A session of one project, as a command starts one.
private func aSession(at path: String) -> Session {
  Session(
    createdAt: aMoment,
    project: Session.Project(name: "Sketch", path: path, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// Puts a saved project on disk, the way Logic writes one, and answers where it sits.
private func aProject(inside folder: URL, savedFrom file: URL) throws -> String {
  let project = folder.appendingPathComponent("Sketch.logicx")
  let alternative = project.appendingPathComponent("Alternatives").appendingPathComponent("000")
  try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
  try Data(contentsOf: file).write(
    to: alternative.appendingPathComponent("ProjectData"), options: .atomic)
  return project.path
}

/// Where the work of a project on disk sits.
private func theDataFile(ofProjectAt path: String) -> URL {
  URL(fileURLWithPath: path)
    .appendingPathComponent("Alternatives")
    .appendingPathComponent("000")
    .appendingPathComponent("ProjectData")
}

/// Writes one saved project over another, the way a save in Logic does.
private func save(_ file: URL, overTheProjectAt path: String) throws {
  try Data(contentsOf: file).write(to: theDataFile(ofProjectAt: path), options: .atomic)
}

/// How many commits one session holds.
private func commits(of repository: SessionRepository, git: Git) throws -> Int {
  try git.run(["log", "--format=%H"], in: repository.folder)
    .split(separator: "\n")
    .count
}

/// What one step of a session holds, read back from its record.
private func step(_ sequence: Int, of repository: SessionRepository) throws -> [String: Any] {
  let file =
    repository.folder
    .appendingPathComponent("steps")
    .appendingPathComponent(SessionRepository.stepFolderName(ofSequence: sequence))
    .appendingPathComponent("step.json")
  let parsed = try JSONSerialization.jsonObject(with: try Data(contentsOf: file))
  return parsed as? [String: Any] ?? [:]
}

/// What `state.json` of a session holds.
private func recordedState(of repository: SessionRepository) throws -> [String: Any] {
  let file = repository.folder.appendingPathComponent("state.json")
  let parsed = try JSONSerialization.jsonObject(with: try Data(contentsOf: file))
  return parsed as? [String: Any] ?? [:]
}

/// The hash the state carries for one plugin of one track, both counted from 0.
private func hash(ofTrack track: Int, plugin: Int, in state: [String: Any]) -> String? {
  let tracks = state["tracks"] as? [[String: Any]] ?? []
  guard track < tracks.count else {
    return nil
  }
  let plugins = tracks[track]["plugins"] as? [[String: Any]] ?? []
  guard plugin < plugins.count else {
    return nil
  }
  return plugins[plugin]["stateHash"] as? String
}

/// Everything the watcher wrote down about itself.
private func lines(of log: URL) -> String {
  guard let bytes = try? Data(contentsOf: log) else {
    return ""
  }
  return String(decoding: bytes, as: UTF8.self)
}

/// A source of changes that reports what a test tells it to report.
///
/// The file system of the machine that runs a test is not a thing to wait on. One test below does
/// drive the real one, and every other test hands the path over itself.
private final class AHand: FileChangeSource, @unchecked Sendable {
  /// The folders the watcher asked for, on the last start.
  private let guardian = NSLock()
  private var asked: [URL] = []
  private var report: (@Sendable (String) -> Void)?

  /// The folders the watcher asked for.
  var folders: [URL] {
    guardian.lock()
    defer { guardian.unlock() }
    return asked
  }

  func start(watching folders: [URL], report: @escaping @Sendable (String) -> Void) throws {
    guardian.lock()
    asked = folders
    self.report = report
    guardian.unlock()
  }

  func stop() {
    guardian.lock()
    report = nil
    guardian.unlock()
  }

  /// Tells the watcher that one file changed.
  func change(_ path: String) {
    guardian.lock()
    let told = report
    guardian.unlock()
    told?(path)
  }
}

/// A watcher over one root, with a source and a log a test can read.
private func aWatcher(
  root: URL, source: any FileChangeSource, git: Git, lock: Lock = Lock()
) -> SaveWatcher {
  SaveWatcher(
    root: root,
    source: source,
    log: WatchLog(file: root.appendingPathComponent(WatchLog.fileName)),
    now: { aMoment },
    git: git,
    lock: lock)
}

/// A person opens a plugin, moves one knob and presses Command S. Nobody types a command.
///
/// Without this, that work leaves no trace at all. The journal holds every command of logicctl and
/// nothing a person did by hand, so the next command reads the new sound as drift and the history
/// cannot say what made it. A person who wants to know what they changed has to remember.
///
/// So a save is a step, and the step names the plugin. One knob of one Channel EQ moved between
/// the two saved projects here, and the step says exactly that: the plugin in slot 2 of track 1
/// holds different settings now, here is what its settings hashed to before and what they hash to
/// now, and no other plugin was touched. The session carries the new hashes from here on, so the
/// command after this one compares against the sound the person actually has.
@Test func aSaveWritesOneSaveStep() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = try aProject(inside: root, savedFrom: theProjectBeforeTheKnob)

  let before = try namedChunks(of: theProjectBeforeTheKnob)
  let after = try namedChunks(of: theProjectAfterTheKnob)
  let namesOfTheProject = [
    "E-Piano", "Channel EQ", "E-Piano", "Compressor", "Piano", "Channel EQ", "Compressor",
    "ChromaVerb", "Piano", "Channel EQ", "Compressor", "ChromaVerb", "Klopfgeist",
  ]
  try #require(
    before.map(\.name) == namesOfTheProject,
    "the saved project holds the plugins these tests are written against")
  try #require(
    zip(before, after).filter { $0.stateHash != $1.stateHash }.count == 1,
    "one knob moved between the two saves, so one plugin hash moved")

  let recorded = try aState(named: thePluginsOfTheProject, hashedFrom: theProjectBeforeTheKnob)
  let repository = try SessionRepository.start(
    session: aSession(at: project), root: root, state: recorded, git: git)
  let held = try commits(of: repository, git: git)

  try save(theProjectAfterTheKnob, overTheProjectAt: project)
  let watcher = aWatcher(root: root, source: AHand(), git: git)
  let recording = watcher.record(
    saveOfProjectAt: project, readingDataAt: theDataFile(ofProjectAt: project))

  #expect(recording.commit != nil, "the save is recorded as a step of its own: \(recording)")
  #expect(recording.differences == 1, "and one plugin changed: \(recording)")
  #expect(
    try commits(of: repository, git: git) == held + 1,
    "the save is one commit of its own, and the person typed no command to get it")

  let written = try step(1, of: repository)
  #expect(written["kind"] as? String == "save", "the history says a save made this step")
  #expect(written["command"] is NSNull, "and that no command made it")
  #expect(written["exitCode"] as? Int == 0, "a save that happened did not fail")

  let differences = written["differences"] as? [[String: Any]] ?? []
  #expect(differences.count == 1, "one knob moved, so the step names one plugin: \(differences)")
  #expect(
    differences.first?["path"] as? String == "/tracks/0/plugins/1/stateHash",
    "the plugin it names is the Channel EQ of track 1, which is where the knob was")
  #expect(
    differences.first?["before"] as? String == before[1].stateHash,
    "the step says what that plugin held before the person opened it")
  #expect(
    differences.first?["after"] as? String == after[1].stateHash,
    "and what it holds now")

  let state = try recordedState(of: repository)
  #expect(
    hash(ofTrack: 0, plugin: 1, in: state) == after[1].stateHash,
    "the session carries the new settings, so the next command compares against this sound")
  #expect(
    hash(ofTrack: 3, plugin: 3, in: state) == after[11].stateHash,
    "and the plugins the person left alone keep the hashes they had")
}

/// The watcher and a command both write into one repository, and a repository has one index.
///
/// A person can press Command S at the moment a command of logicctl is writing its own step. Two
/// writers in one git repository at once leave a half written index or a step that no commit
/// carries, and the history is then a worse record than none, because a reader believes it. So the
/// watcher waits for the lock the command holds, and writes after it.
@Test func aSaveWaitsForTheCommandThatHoldsTheLock() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = try aProject(inside: root, savedFrom: theProjectBeforeTheKnob)
  let recorded = try aState(named: thePluginsOfTheProject, hashedFrom: theProjectBeforeTheKnob)
  let repository = try SessionRepository.start(
    session: aSession(at: project), root: root, state: recorded, git: git)
  let held = try commits(of: repository, git: git)
  try save(theProjectAfterTheKnob, overTheProjectAt: project)

  let taken = DispatchSemaphore(value: 0)
  let letGo = DispatchSemaphore(value: 0)
  let folder = repository.folder
  let lock = Lock()
  DispatchQueue.global().async {
    do {
      try lock.holding(folder) {
        taken.signal()
        letGo.wait()
      }
    } catch {
      taken.signal()
    }
  }
  taken.wait()

  let started = Date()
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { letGo.signal() }
  let watcher = aWatcher(root: root, source: AHand(), git: git, lock: Lock())
  let recording = watcher.record(
    saveOfProjectAt: project, readingDataAt: theDataFile(ofProjectAt: project))
  let waited = Date().timeIntervalSince(started)

  #expect(waited >= 0.3, "the watcher waited for the writer that held the session, \(waited)s")
  #expect(recording.commit != nil, "and then it wrote the save: \(recording)")
  #expect(
    try commits(of: repository, git: git) == held + 1,
    "one save is one commit, and waiting for the lock did not make it two")
}

/// Which hash belongs to which plugin is the whole claim of a save step.
///
/// Logic writes the settings of each plugin in the order of the tracks, and it writes more chunks
/// than a person has plugins: the ones with no name are not settings at all, and the metronome
/// carries settings while belonging to no track. A reading that counted those in would move every
/// hash after them by one slot, and the step would name a plugin the person never opened.
///
/// This project was saved on 2026-09-25 with four tracks, one of them an audio track with an empty
/// channel strip, and the metronome last.
@Test func theNamedChunksGoToThePluginsOfEachTrackInOrder() throws {
  let chunks = try ProjectData.pluginChunks(ofFileAt: theProjectOfFourTracks)
  let named = chunks.filter { $0.name != nil }
  try #require(
    named.map(\.name) == ["E-Piano", "Channel EQ", "E-Piano", "E-Piano", "Klopfgeist"],
    "the saved project holds the plugins this test is written against")

  let state = try aState(named: thePluginsOfTheFourTracks, hashedFrom: theProjectOfFourTracks)
  let plugins = SaveWatcher.plugins(of: state.json)
  #expect(
    plugins.map(\.name) == ["E-Piano", "Channel EQ", "E-Piano", "E-Piano"],
    "the state holds four plugins over four tracks, and the audio track holds none")

  let mapping = SaveWatcher.mapping(ofNamedChunks: chunks, onto: plugins)
  #expect(mapping.reason == nil, "the file and the state agree: \(mapping.reason ?? "")")
  #expect(
    mapping.hashes == named.prefix(4).map(\.stateHash),
    "each plugin takes the settings Logic wrote for it, in that order")
  #expect(
    !mapping.hashes.contains(named[4].stateHash),
    "and the metronome, which belongs to no track, is left out")
}

/// The names are read against the state, so a file about another project cannot be read into it.
///
/// A hash written into the wrong slot is worse than no hash: the history then names a plugin the
/// person did not open, and every later save compares against it. So when the file and the state
/// disagree about what sits where, no plugin difference is written and the log says why.
@Test func aFileThatDisagreesWithTheStateWritesNoPluginDifference() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = try aProject(inside: root, savedFrom: theProjectAfterTheKnob)
  var recorded = try aState(named: thePluginsOfTheProject, hashedFrom: theProjectBeforeTheKnob)
  recorded.tracks[0].plugins[1].name = "Vintage EQ"
  let repository = try SessionRepository.start(
    session: aSession(at: project), root: root, state: recorded, git: git)
  let held = try commits(of: repository, git: git)

  let watcher = aWatcher(root: root, source: AHand(), git: git)
  let recording = watcher.record(
    saveOfProjectAt: project, readingDataAt: theDataFile(ofProjectAt: project))

  #expect(recording.commit != nil, "the save happened, so it is a step: \(recording)")
  #expect(recording.differences == 0, "and it claims nothing about the plugins")
  #expect(try commits(of: repository, git: git) == held + 1)
  let state = try recordedState(of: repository)
  let untouched = try namedChunks(of: theProjectBeforeTheKnob)[1].stateHash
  #expect(
    hash(ofTrack: 0, plugin: 1, in: state) == untouched,
    "the hashes the session carried are left as they were")
  #expect(
    lines(of: root.appendingPathComponent(WatchLog.fileName)).contains("Vintage EQ"),
    "and a person reading the log is told which slot did not agree")
}

/// Every save is a step, even a save that changed no sound.
///
/// A person presses Command S after moving a region, or after nothing at all. The record of the
/// last save is what says how much work a crash of Logic could have cost, so a save that is not in
/// the history is a save that cannot answer that question.
@Test func aSaveThatMovedNoKnobIsStillAStep() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = try aProject(inside: root, savedFrom: theProjectBeforeTheKnob)
  let recorded = try aState(named: thePluginsOfTheProject, hashedFrom: theProjectBeforeTheKnob)
  let repository = try SessionRepository.start(
    session: aSession(at: project), root: root, state: recorded, git: git)
  let held = try commits(of: repository, git: git)

  let watcher = aWatcher(root: root, source: AHand(), git: git)
  let recording = watcher.record(
    saveOfProjectAt: project, readingDataAt: theDataFile(ofProjectAt: project))

  #expect(recording.commit != nil, "the save is recorded: \(recording)")
  #expect(recording.differences == 0, "and nothing about the sound changed")
  #expect(try commits(of: repository, git: git) == held + 1, "and it is still one commit")
  #expect(try step(1, of: repository)["kind"] as? String == "save", "and it is a save")
}

/// A project that logicctl never worked on is not the watcher's to record.
///
/// The watcher follows the sessions. A save of anything else is a save of a project nobody asked
/// logicctl to follow, and starting a session for it would put a person's other work into a
/// history they never asked for.
@Test func aSaveOfAProjectWithNoSessionIsNotRecorded() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let project = try aProject(inside: root, savedFrom: theProjectAfterTheKnob)

  let watcher = aWatcher(root: root, source: AHand(), git: git)
  let recording = watcher.record(
    saveOfProjectAt: project, readingDataAt: theDataFile(ofProjectAt: project))

  #expect(recording.commit == nil, "nothing was written: \(recording)")
  #expect(
    SessionIndex.sessions(underRoot: root).isEmpty,
    "and no session was started for a project logicctl never worked on")
}

/// A person starts the watcher once and goes on working. Every project they open after that is a
/// new session, and a watcher that only knew the sessions of the moment it started would record
/// nothing for any of them until the next restart of the Mac.
@Test func aSessionThatStartsAfterTheWatcherIsWatchedToo() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let first = try aProject(inside: root, savedFrom: theProjectBeforeTheKnob)
  let recorded = try aState(named: thePluginsOfTheProject, hashedFrom: theProjectBeforeTheKnob)
  _ = try SessionRepository.start(
    session: aSession(at: first), root: root, state: recorded, git: git)

  let hand = AHand()
  let watcher = aWatcher(root: root, source: hand, git: git)
  try watcher.watch()
  let covering = [SessionRepository.sessionsFolder(underRoot: root).path, first]
  #expect(
    hand.folders.map(\.path) == covering,
    "the watcher covers the project it knows about, and the folder the sessions live in")

  let later = root.appendingPathComponent("later")
  let second = try aProject(inside: later, savedFrom: theProjectBeforeTheKnob)
  _ = try SessionRepository.start(
    session: aSession(at: second), root: root, state: recorded, git: git)
  hand.change(SessionRepository.sessionsFolder(underRoot: root).path + "/something")

  var covered = hand.folders.count
  for _ in 0..<200 where covered < 3 {
    Thread.sleep(forTimeInterval: 0.01)
    covered = hand.folders.count
  }
  #expect(
    hand.folders.map(\.path).contains(second),
    "and it covers the project of the session that started while it ran")
}

/// The watcher reads one file out of everything that moves on a Mac, so it has to know which one.
@Test func onlyTheWorkOfAProjectReadsAsASave() throws {
  let project = "/Users/someone/Music/Sketch.logicx"
  #expect(
    SavedProject.projectPath(ofDataAt: project + "/Alternatives/000/ProjectData") == project,
    "the work of an alternative is a save of the project that holds it")
  #expect(
    SavedProject.projectPath(ofDataAt: project + "/Alternatives/001/ProjectData") == project,
    "a project carries more than one alternative, and a save writes the one that is open")
  #expect(
    SavedProject.isSaveOfAProject(path: project + "/Alternatives/000/Autosave/ProjectData"),
    "an autosave writes its own folder, and that file is still the work of this project")
  #expect(
    SavedProject.projectPath(ofDataAt: project + "/Alternatives/000/DisplayState.plist") == nil,
    "and what Logic shows on the screen is not a save")
  #expect(
    SavedProject.projectPath(ofDataAt: "/Users/someone/ProjectData") == nil,
    "a file of that name outside a project belongs to no project")
}

/// The path rules and the recorder are only reached when macOS says a file changed, so one test
/// drives the real thing.
@Test func theWatcherIsToldWhenAFileChanges() throws {
  let folder = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: folder) }
  let told = ASink()
  let events = FileSystemEvents(latencySeconds: 0.05)
  defer { events.stop() }
  try events.start(watching: [folder]) { path in
    told.add(path)
  }

  let file = folder.appendingPathComponent("ProjectData")
  for _ in 0..<100 where told.isEmpty {
    try Data("a save".utf8).write(to: file, options: .atomic)
    Thread.sleep(forTimeInterval: 0.1)
  }

  #expect(!told.isEmpty, "macOS reported the file that changed under the folder")
  #expect(
    told.paths.contains { $0.hasSuffix("ProjectData") },
    "and it named the file, not only the folder: \(told.paths)")
}

/// Every path macOS reported.
private final class ASink: @unchecked Sendable {
  private let guardian = NSLock()
  private var held: [String] = []

  var paths: [String] {
    guardian.lock()
    defer { guardian.unlock() }
    return held
  }

  var isEmpty: Bool {
    paths.isEmpty
  }

  func add(_ path: String) {
    guardian.lock()
    held.append(path)
    guardian.unlock()
  }
}

/// The launch agent types `logicctl watch run`, and a subcommand the root command does not hold is
/// not there at all, whatever the code behind it does. A person does not type it, so it is left
/// out of the help: a command in the help is a command somebody will run, and this one runs for
/// ever and answers nothing.
@Test func theCommandLineReachesWatchRunAndTheHelpLeavesItOut() throws {
  let answer = Answer()
  let exitCode = Logicctl.run(
    arguments: ["watch", "run", "--help"], standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 0, "the help of a command is not a failure")
  #expect(
    answer.out.contains("logicctl watch run"), "the launch agent reaches the command it runs")

  let listing = Answer()
  #expect(
    Logicctl.run(
      arguments: ["watch", "--help"], standardOutput: listing.write,
      standardError: listing.writeError) == 0)
  #expect(
    !listing.out.contains("run"),
    "and a person reading the help of watch is shown start and stop: \(listing.out)")
}

/// What one run of a command wrote, on each channel.
private final class Answer {
  var out = ""
  var err = ""

  func write(_ text: String) {
    out += text
  }

  func writeError(_ text: String) {
    err += text
  }
}

extension SaveWatcher.Recording {
  /// The commit of a save that was written, or nothing when none was.
  var commit: String? {
    switch self {
    case .written(let commit, _):
      return commit
    case .notRecorded:
      return nil
    }
  }

  /// How many differences the step of a save carries, or nothing when none was written.
  var differences: Int? {
    switch self {
    case .written(_, let differences):
      return differences
    case .notRecorded:
      return nil
    }
  }
}
