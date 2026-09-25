import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-watch-status-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// The binary a test pretends logicctl was installed as.
private let aBinary = URL(fileURLWithPath: "/usr/local/bin/logicctl")

/// A loader that talks to nothing and remembers what it was asked to do.
///
/// launchd is not a thing a test may reach. A test that loaded the real agent would leave a
/// watcher running on the machine that ran the test, and that watcher would write steps into the
/// sessions of the person at that machine.
private final class ALoader: LaunchAgentLoader {
  /// The file of every load, in order.
  var loaded: [URL] = []

  func load(fileAt file: URL, label: String) throws {
    loaded.append(file)
  }

  func unload(fileAt file: URL, label: String) throws {}
}

/// The launch agent of one test, whose property list sits in a folder of its own.
private func anAgent(in folder: URL) -> LaunchAgent {
  LaunchAgent(folder: folder, program: aBinary, loader: ALoader())
}

/// A session of one project, as a command starts one.
///
/// Each session takes its own moment, because the answer carries the newest session first and a
/// test of that order needs the sessions to have one.
private func aSession(named name: String, at path: String?, startedAt started: Date) -> Session {
  Session(
    createdAt: started,
    project: Session.Project(name: name, path: path, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// Writes the `session.json` of one session under a root, the way a session on disk carries it.
///
/// It writes the file and no history, because the projects the watcher covers are read from the
/// record of each session and not from its commits.
private func write(_ session: Session, underRoot root: URL) throws {
  let folder = SessionRepository.sessionFolder(of: session, underRoot: root)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let text = CanonicalJSON.text(of: session.json, indent: 2)
  try Data(text.utf8).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
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

  /// What standard output carried, read back as JSON.
  func envelope() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// What the answer carries, or an empty answer when it failed.
  func data() throws -> [String: Any] {
    try envelope()["data"] as? [String: Any] ?? [:]
  }

  /// The projects the answer names, in the order it named them.
  func projects() throws -> [String] {
    try data()["projects"] as? [String] ?? []
  }
}

/// A person who started the watcher has to see what it covers. The answer of `watch start` says
/// how many projects, and a number cannot be acted on: somebody with three sessions and two saved
/// projects still does not know whether the project in front of them is one of the two. Nothing
/// else tells them either. A save of a project the watcher does not cover never becomes a save
/// step, and the work that went into it is missing from the history at the moment they need it.
/// This is the list they read, so it names each project, and it leaves out a session that has
/// nothing on disk to watch.
@Test func watchStatusNamesTheWatchedProjects() throws {
  let root = try temporaryFolder()
  let folder = try temporaryFolder()
  let sketch = "/Users/someone/Music/Sketch.logicx"
  let demo = "/Users/someone/Music/Demo.logicx"
  try write(
    aSession(named: "Demo", at: demo, startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
    underRoot: root)
  try write(
    aSession(named: "Sketch", at: sketch, startedAt: Date(timeIntervalSince1970: 1_700_000_100)),
    underRoot: root)
  try write(
    aSession(named: "Untitled", at: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_200)),
    underRoot: root)

  let answer = Answer()
  let exitCode = WatchStatus.answer(
    agent: anAgent(in: folder), root: root, standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 0, "what the watcher covers is a question with an answer")
  #expect(
    try answer.projects() == [sketch, demo],
    "both saved projects are named, the newest session first")
  #expect(
    try answer.projects().count == 2,
    "three sessions, and the one that was never saved has nothing on disk to watch")
}

/// `sessions --relink` points a session at a project that another session already recorded, so two
/// sessions can carry one path. The watcher watches that project once. A person who read the same
/// project twice would go looking for a second watcher that is not there.
@Test func watchStatusNamesOneProjectOnce() throws {
  let root = try temporaryFolder()
  let folder = try temporaryFolder()
  let moved = "/Users/someone/Music/Moved.logicx"
  try write(
    aSession(named: "Moved", at: moved, startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
    underRoot: root)
  try write(
    aSession(named: "Moved", at: moved, startedAt: Date(timeIntervalSince1970: 1_700_000_100)),
    underRoot: root)

  let answer = Answer()
  let exitCode = WatchStatus.answer(
    agent: anAgent(in: folder), root: root, standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 0)
  #expect(try answer.projects() == [moved], "one project, however many sessions carry it")
}

/// The first thing a person reads is whether there is a watcher at all, and a script reads it to
/// decide whether to start one. A Mac that was never asked for a watcher has none. That is a state
/// and not a failure, so the command answers it and exits 0.
@Test func watchStatusSaysWhetherTheWatcherRuns() throws {
  let folder = try temporaryFolder()
  let root = try temporaryFolder()
  let agent = anAgent(in: folder)

  let quiet = Answer()
  let quietCode = WatchStatus.answer(
    agent: agent, root: root, standardOutput: quiet.write, standardError: quiet.writeError)

  #expect(quietCode == 0, "no watcher is an answer and not a failure")
  #expect(try quiet.data()["running"] as? Bool == false, "nobody asked for a watcher here")
  #expect(try quiet.projects().isEmpty, "and it covers nothing")
  #expect(quiet.err.isEmpty, "a command that worked writes nothing on standard error")

  let starting = Answer()
  let startCode = Watch.started(
    agent: agent, root: root, standardOutput: starting.write, standardError: starting.writeError)
  #expect(startCode == 0, "the watcher was asked for before this reads it")

  let running = Answer()
  let runningCode = WatchStatus.answer(
    agent: agent, root: root, standardOutput: running.write, standardError: running.writeError)

  #expect(runningCode == 0)
  #expect(try running.data()["running"] as? Bool == true, "and the person is told it runs")
  #expect(
    try running.data()["label"] as? String == "com.atlantic-blue.logicctl.watch",
    "with the agent to look for on this Mac")
}

/// The command line reaches `watch status`. A subcommand the root command does not hold is not
/// there at all, whatever the code behind it does, and every test above would still pass.
@Test func theCommandLineReachesWatchStatus() throws {
  let answer = Answer()
  let exitCode = Logicctl.run(
    arguments: ["watch", "status", "--help"], standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 0, "the help of a command is not a failure")
  #expect(
    answer.out.contains("logicctl watch status"), "the help names the command a person types")
}
