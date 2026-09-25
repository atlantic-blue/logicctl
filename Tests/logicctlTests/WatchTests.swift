import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-watch-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// The binary a test pretends logicctl was installed as.
private let aBinary = URL(fileURLWithPath: "/usr/local/bin/logicctl")

/// A loader that talks to nothing and remembers what it was asked to do.
///
/// launchd is not a thing a test may reach. A test that loaded the real agent would leave a
/// watcher running on the machine that ran the test, and a test that unloaded one would stop the
/// watcher of the person at that machine.
private final class ALoader: LaunchAgentLoader {
  /// The file of every load, in order.
  var loaded: [URL] = []

  /// The label of every unload, in order.
  var unloaded: [String] = []

  /// What to refuse with, or nothing when launchd takes both verbs.
  var refusal: Error?

  init(refusing refusal: Error? = nil) {
    self.refusal = refusal
  }

  func load(fileAt file: URL, label: String) throws {
    if let refusal {
      throw refusal
    }
    loaded.append(file)
  }

  func unload(fileAt file: URL, label: String) throws {
    if let refusal {
      throw refusal
    }
    unloaded.append(label)
  }
}

/// What launchd refuses with when it will not take the agent.
private struct LaunchdSaidNo: Error {}

/// A session of one project, as a command starts one.
private func aSession(named name: String, at path: String?) -> Session {
  Session(
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    project: Session.Project(name: name, path: path, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// Writes the `session.json` of one session under a root, the way a session on disk carries it.
///
/// It writes the file and no history, because the count of projects is read from the record of
/// each session and not from its commits.
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

  /// What the failure carries, or an empty failure when it worked.
  func failure() throws -> [String: Any] {
    try envelope()["error"] as? [String: Any] ?? [:]
  }
}

/// What the property list of the agent holds, read back from the file.
private func propertyList(at file: URL) throws -> [String: Any] {
  let bytes = try Data(contentsOf: file)
  let read = try PropertyListSerialization.propertyList(from: bytes, format: nil)
  return read as? [String: Any] ?? [:]
}

/// A person asks for the watcher, and from then on a save they make in Logic is recorded, today
/// and after the next restart of the Mac. Nothing of logicctl is running when they ask: the
/// command writes a file and hands it to launchd, and launchd is what starts the watcher and
/// starts it again. So the whole of the promise sits in that file, and the part of it that
/// matters is which program launchd runs. A file naming the binary alone would load, and launchd
/// would start the command line tool with no command, which prints the help and ends. A person
/// would read "running: true", make a save, and find nothing in their history.
@Test func watchStartWritesTheLaunchAgent() throws {
  let folder = try temporaryFolder()
  let root = try temporaryFolder()
  let loader = ALoader()
  let agent = LaunchAgent(folder: folder, program: aBinary, loader: loader)

  let answer = Answer()
  let exitCode = Watch.started(
    agent: agent, root: root, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0, "the watcher was asked for and launchd took it")
  let file = folder.appendingPathComponent("com.atlantic-blue.logicctl.watch.plist")
  let written = try propertyList(at: file)
  #expect(
    written["ProgramArguments"] as? [String] == ["/usr/local/bin/logicctl", "watch", "run"],
    "launchd runs the watcher of this binary, and a binary with no command prints the help")
  #expect(
    written["Label"] as? String == "com.atlantic-blue.logicctl.watch",
    "launchd knows the agent by the label the file is named after")
  #expect(written["RunAtLoad"] as? Bool == true, "the watcher starts now and not at the restart")
  #expect(written["KeepAlive"] as? Bool == true, "a watcher that ends is started again")
  #expect(loader.loaded == [file], "launchd was handed that one file, and nothing else")
  #expect(try answer.data()["running"] as? Bool == true, "the person is told it runs")
  #expect(
    try answer.data()["label"] as? String == "com.atlantic-blue.logicctl.watch",
    "and which agent to look for on this Mac")
}

/// The count in the answer says whether the watcher has anything to watch. The watcher watches
/// the file of a project on disk, so a session of a project that was never saved gives it nothing
/// to watch yet, and a person who reads a count of two projects knows which of their sessions is
/// covered without going to look.
@Test func watchStartCountsTheProjectsItWatches() throws {
  let root = try temporaryFolder()
  try write(aSession(named: "Sketch", at: "/Users/someone/Music/Sketch.logicx"), underRoot: root)
  try write(aSession(named: "Demo", at: "/Users/someone/Music/Demo.logicx"), underRoot: root)
  try write(aSession(named: "Untitled", at: nil), underRoot: root)

  let folder = try temporaryFolder()
  let agent = LaunchAgent(folder: folder, program: aBinary, loader: ALoader())
  let answer = Answer()
  let exitCode = Watch.started(
    agent: agent, root: root, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0)
  #expect(
    try answer.data()["projects"] as? Int == 2,
    "the two saved projects are watched, and the project with no path is not")
}

/// Stopping is the way off the watcher, so it has to leave the Mac as it was before the person
/// ever asked for one. launchd holds a loaded agent by its label, and it loads every file in the
/// folder again at the next login, so a file left behind is a watcher that comes back after a
/// restart the person asked to be rid of.
@Test func watchStopUnloadsTheAgentAndRemovesTheFile() throws {
  let folder = try temporaryFolder()
  let root = try temporaryFolder()
  let loader = ALoader()
  let agent = LaunchAgent(folder: folder, program: aBinary, loader: loader)
  let started = Answer()
  let startCode = Watch.started(
    agent: agent, root: root, standardOutput: started.write, standardError: started.writeError)
  #expect(startCode == 0, "the watcher runs before the test stops it")

  let answer = Answer()
  let exitCode = Watch.stopped(
    agent: agent, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0, "the watcher was stopped")
  #expect(loader.unloaded == ["com.atlantic-blue.logicctl.watch"], "launchd was told the label")
  let file = folder.appendingPathComponent("com.atlantic-blue.logicctl.watch.plist")
  #expect(
    FileManager.default.fileExists(atPath: file.path) == false,
    "and the file is gone, so the next login starts no watcher")
  #expect(try answer.data()["running"] as? Bool == false, "the person is told none runs")
  #expect(try answer.data().count == 1, "and the answer says nothing else")
}

/// A person who never started a watcher, or who stops one twice, asked for no watcher and has
/// none. That is the answer to the question and not a failure, and a script that stops the
/// watcher before it does something else must not die on a Mac that was already quiet.
@Test func watchStopWithNoAgentIsNotAFailure() throws {
  let folder = try temporaryFolder()
  let loader = ALoader()
  let agent = LaunchAgent(folder: folder, program: aBinary, loader: loader)

  let answer = Answer()
  let exitCode = Watch.stopped(
    agent: agent, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 0, "there was nothing to stop, which is what the person asked for")
  #expect(try answer.data()["running"] as? Bool == false)
  #expect(loader.unloaded.isEmpty, "launchd was not asked about an agent that was never loaded")
  #expect(answer.err.isEmpty, "a command that worked writes nothing on standard error")
}

/// launchd can refuse: another agent holds the label, the file is not one it will take, or the
/// session is not there to load into. The person must not be told the watcher runs when it does
/// not, because they would go on making saves that nothing records.
@Test func watchStartThatLaunchdRefusesFails() throws {
  let folder = try temporaryFolder()
  let root = try temporaryFolder()
  let agent = LaunchAgent(
    folder: folder, program: aBinary, loader: ALoader(refusing: LaunchdSaidNo()))

  let answer = Answer()
  let exitCode = Watch.started(
    agent: agent, root: root, standardOutput: answer.write, standardError: answer.writeError)

  #expect(exitCode == 70, "launchd has no code of its own, so it is internal, code 70")
  #expect(try answer.failure()["code"] as? String == "internal")
  #expect(try answer.envelope()["data"] is NSNull, "a failure carries no answer")
  #expect(answer.err.hasPrefix("logicctl: internal: "), "a person reading along is told one line")
}

/// The command line reaches `watch start` and `watch stop`. A subcommand that the root command
/// does not hold is not there at all, whatever the code behind it does, and every test above
/// would still pass.
@Test func theCommandLineReachesWatch() throws {
  let answer = Answer()
  let exitCode = Logicctl.run(
    arguments: ["watch", "start", "--help"], standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exitCode == 0, "the help of a command is not a failure")
  #expect(answer.out.contains("logicctl watch start"), "the help names the command a person types")

  let stopping = Answer()
  #expect(
    Logicctl.run(
      arguments: ["watch", "stop", "--help"], standardOutput: stopping.write,
      standardError: stopping.writeError) == 0)
  #expect(stopping.out.contains("logicctl watch stop"))
}
