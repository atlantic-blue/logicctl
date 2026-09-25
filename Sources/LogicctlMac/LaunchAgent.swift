import Darwin
import Foundation

/// What loads a launch agent on this Mac and unloads it again.
///
/// The two verbs are behind a protocol because a test cannot ask launchd for anything: a test that
/// loaded the real agent would start a watcher on the machine that ran it, and it would leave that
/// watcher running after the test ended. So a test gives its own loader and reads back what it was
/// asked to do, and the one place that talks to launchd is the loader below it.
public protocol LaunchAgentLoader {
  /// Loads the agent whose property list sits in that file.
  func load(fileAt file: URL, label: String) throws

  /// Unloads the agent of that label.
  func unload(fileAt file: URL, label: String) throws
}

/// The user launch agent that keeps the watcher of logicctl running.
///
/// A watcher that a person starts by hand stops when they close the terminal, and it does not come
/// back when the Mac restarts. So the watcher is a launch agent of the user: launchd starts it, and
/// launchd starts it again after a restart. `watch start` writes the property list and loads it,
/// and `watch stop` unloads it and takes the file away, so a Mac that was never asked for a watcher
/// carries no file for one.
public struct LaunchAgent {
  /// Why the agent could not be written, loaded, unloaded or removed.
  public struct Refusal: Error, Equatable {
    /// One short reason, in the words of the Mac that refused.
    public let reason: String

    public init(reason: String) {
      self.reason = reason
    }
  }

  /// The label launchd knows the agent by. The file is named after it, as launchd asks.
  public static let label = "com.atlantic-blue.logicctl.watch"

  /// The name of the property list file, which is the label and the extension launchd reads.
  public static let fileName = LaunchAgent.label + ".plist"

  /// The subcommand the agent runs. It is hidden from the help, and only launchd types it.
  public static let arguments: [String] = []

  /// Where macOS keeps the launch agents of the person using the Mac.
  public static var defaultFolder: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library")
      .appendingPathComponent("LaunchAgents")
  }

  /// The binary the agent runs.
  ///
  /// It is the binary that is answering now, and not a path written into the source, because the
  /// tool is built and signed on this Mac and lives wherever the person put it. An agent that named
  /// a path nobody built to would load and fail at every start.
  public static var runningProgram: URL {
    let found = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return found.resolvingSymlinksInPath()
  }

  /// The folder the property list is written into.
  public var folder: URL

  /// The binary the agent runs.
  public var program: URL

  /// What loads the agent and unloads it.
  public var loader: any LaunchAgentLoader

  public init(
    folder: URL = LaunchAgent.defaultFolder,
    program: URL = LaunchAgent.runningProgram,
    loader: any LaunchAgentLoader = LaunchctlLoader()
  ) {
    self.folder = folder
    self.program = program
    self.loader = loader
  }

  /// The property list file of the agent, whether it is there or not.
  public var file: URL {
    folder.appendingPathComponent(LaunchAgent.fileName)
  }

  /// True when the property list file is there.
  public var isWritten: Bool {
    FileManager.default.fileExists(atPath: file.path)
  }

  /// What the property list holds.
  ///
  /// `RunAtLoad` starts the watcher as soon as the agent loads, so a person who asked for it does
  /// not wait for the next restart to get one. `KeepAlive` starts it again when it ends, so a
  /// watcher that stops on its own comes back without anybody watching for that.
  public var propertyList: [String: Any] {
    [
      "Label": LaunchAgent.label,
      "ProgramArguments": [program.path] + LaunchAgent.arguments,
      "RunAtLoad": true,
      "KeepAlive": true,
    ]
  }

  /// Writes the property list and loads the agent.
  ///
  /// A file that is already there is written again, and the agent is loaded again, so a person who
  /// runs the command twice gets a watcher that runs the binary they have now.
  public func start() throws {
    try write()
    do {
      try loader.load(fileAt: file, label: LaunchAgent.label)
    } catch {
      throw Refusal(reason: "the launch agent was written and launchd refused it: \(error)")
    }
  }

  /// Unloads the agent and takes its property list away.
  ///
  /// A Mac with no file for the agent has no agent, so there is nothing to unload and nothing to
  /// remove. That is the answer to `watch stop` and not a failure: the person asked for no watcher,
  /// and there is none.
  public func stop() throws {
    guard isWritten else {
      return
    }
    do {
      try loader.unload(fileAt: file, label: LaunchAgent.label)
    } catch {
      throw Refusal(reason: "launchd refused to unload the launch agent: \(error)")
    }
    do {
      try FileManager.default.removeItem(at: file)
    } catch {
      throw Refusal(reason: "the launch agent was unloaded and its file stayed: \(error)")
    }
  }

  /// Writes the property list of the agent, making the folder when macOS has none yet.
  public func write() throws {
    let bytes: Data
    do {
      bytes = try PropertyListSerialization.data(
        fromPropertyList: propertyList, format: .xml, options: 0)
    } catch {
      throw Refusal(reason: "the property list of the launch agent could not be built: \(error)")
    }
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try bytes.write(to: file, options: .atomic)
    } catch {
      throw Refusal(reason: "the launch agent could not be written to \(file.path): \(error)")
    }
  }
}

/// The loader that talks to launchd, through the `launchctl` tool of macOS.
///
/// The agent belongs to the person at the Mac and not to the machine, so it lives in the graphical
/// user session, which launchctl calls `gui/<user id>`. A run carries a limit: a launchctl that
/// waits for an answer nobody will give must not hold the command open for ever.
public struct LaunchctlLoader: LaunchAgentLoader {
  /// What a run of launchctl can refuse.
  public enum Refusal: Error, Equatable {
    /// launchctl ran and ended with a status that is not zero.
    case failed(arguments: [String], status: Int32, output: String)

    /// launchctl passed its limit, so it was stopped.
    case tookTooLong(arguments: [String], seconds: Double)

    /// launchctl could not be started at all.
    case couldNotStart(arguments: [String], reason: String)
  }

  /// How long one run may take, in seconds.
  public static let defaultLimitSeconds = 10.0

  /// How often the wait looks at the process again, in seconds.
  static let lookWaitSeconds = 0.01

  /// The tool to run.
  public var executable: URL

  /// How long one run may take, in seconds.
  public var limitSeconds: Double

  /// The user whose session the agent belongs to.
  public var userID: UInt32

  public init(
    executable: URL = URL(fileURLWithPath: "/bin/launchctl"),
    limitSeconds: Double = LaunchctlLoader.defaultLimitSeconds,
    userID: UInt32 = getuid()
  ) {
    self.executable = executable
    self.limitSeconds = limitSeconds
    self.userID = userID
  }

  /// The session launchctl loads the agent into.
  public var domain: String {
    "gui/\(userID)"
  }

  /// Loads the agent from its file.
  ///
  /// `bootstrap` is the verb launchd takes on macOS 15. `load` does the same thing and Apple
  /// deprecated it, so the one that is not on its way out is the one logicctl types.
  public func load(fileAt file: URL, label: String) throws {
    try run(["bootstrap", domain, file.path])
  }

  /// Unloads the agent by its label, which is how launchd names a service that is loaded.
  public func unload(fileAt file: URL, label: String) throws {
    try run(["bootout", "\(domain)/\(label)"])
  }

  /// Runs launchctl once and refuses with what it did.
  ///
  /// The output goes to a file and not to a pipe, because a pipe that fills stops the child while
  /// this side waits for the child to end.
  func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments

    let sink = try outputFile()
    defer { sink.remove() }
    process.standardOutput = sink.handle
    process.standardError = sink.handle

    do {
      try process.run()
    } catch {
      throw Refusal.couldNotStart(arguments: arguments, reason: "\(error)")
    }
    if stoppedAtTheLimit(process) {
      throw Refusal.tookTooLong(arguments: arguments, seconds: limitSeconds)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Refusal.failed(
        arguments: arguments, status: process.terminationStatus, output: sink.text())
    }
  }

  /// Waits for the tool, and stops it when it passes the limit. True when it was stopped.
  private func stoppedAtTheLimit(_ process: Process) -> Bool {
    let limit = Date().addingTimeInterval(limitSeconds)
    while process.isRunning {
      if Date() >= limit {
        process.terminate()
        return true
      }
      Thread.sleep(forTimeInterval: LaunchctlLoader.lookWaitSeconds)
    }
    return false
  }

  /// The file everything launchctl printed is collected in.
  private func outputFile() throws -> OutputSink {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("logicctl-launchctl-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: url.path, contents: nil),
      let handle = try? FileHandle(forWritingTo: url)
    else {
      throw Refusal.couldNotStart(
        arguments: [], reason: "the output of launchctl could not be collected at \(url.path)")
    }
    return OutputSink(url: url, handle: handle)
  }
}

/// Where the output of one run of launchctl is collected.
struct OutputSink {
  let url: URL
  let handle: FileHandle

  /// Everything the run printed.
  func text() -> String {
    try? handle.close()
    let bytes = (try? Data(contentsOf: url)) ?? Data()
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Takes the file away.
  func remove() {
    try? handle.close()
    try? FileManager.default.removeItem(at: url)
  }
}
