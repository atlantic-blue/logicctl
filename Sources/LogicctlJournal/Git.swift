import Foundation

/// The `git` that a session repository is written with, run as a child process.
///
/// logicctl links no git library, so every read and every write of a history goes through the
/// command line tool. A run carries a limit: a `git` that waits for an answer nobody will give
/// must not hold a command of logicctl open for ever.
public struct Git: Sendable {
  /// What a run of git can refuse.
  public enum Refusal: Error, Equatable {
    /// Git ran and ended with a status that is not zero.
    case failed(arguments: [String], status: Int32, output: String)

    /// Git passed its limit, so it was stopped.
    case tookTooLong(arguments: [String], seconds: Double)

    /// Git could not be started at all.
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

  /// Variables added to the environment of every run. A test points git at a configuration of its
  /// own with these, so no test reads or writes the configuration of the operator.
  public var environment: [String: String]

  public init(
    executable: URL = URL(fileURLWithPath: "/usr/bin/git"),
    limitSeconds: Double = Git.defaultLimitSeconds,
    environment: [String: String] = [:]
  ) {
    self.executable = executable
    self.limitSeconds = limitSeconds
    self.environment = environment
  }

  /// Runs git in one folder and answers everything it printed.
  ///
  /// The output goes to a file and not to a pipe, because a pipe that fills stops the child while
  /// this side waits for the child to end.
  @discardableResult
  public func run(
    _ arguments: [String], in folder: URL, environment extra: [String: String] = [:]
  ) throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.environment = passedEnvironment(adding: extra)

    let sink = try outputFile(for: arguments)
    process.standardOutput = sink.handle
    process.standardError = sink.handle
    do {
      try process.run()
    } catch {
      sink.remove()
      throw Refusal.couldNotStart(arguments: arguments, reason: "\(error)")
    }

    let stopped = waitForTheEnd(of: process)
    process.waitUntilExit()
    try? sink.handle.close()
    let printed = sink.text()
    sink.remove()

    if stopped {
      throw Refusal.tookTooLong(arguments: arguments, seconds: limitSeconds)
    }
    guard process.terminationStatus == 0 else {
      throw Refusal.failed(
        arguments: arguments, status: process.terminationStatus, output: printed)
    }
    return printed
  }

  /// Waits for the process, and stops it when it passes the limit. True when it was stopped.
  private func waitForTheEnd(of process: Process) -> Bool {
    let limit = Date().addingTimeInterval(limitSeconds)
    while process.isRunning {
      if Date() >= limit {
        process.terminate()
        return true
      }
      Thread.sleep(forTimeInterval: Git.lookWaitSeconds)
    }
    return false
  }

  private func passedEnvironment(adding extra: [String: String]) -> [String: String] {
    var passed = ProcessInfo.processInfo.environment
    for (name, value) in environment {
      passed[name] = value
    }
    for (name, value) in extra {
      passed[name] = value
    }
    return passed
  }

  private func outputFile(for arguments: [String]) throws -> Output {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("logicctl-git-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: url.path, contents: nil),
      let handle = FileHandle(forWritingAtPath: url.path)
    else {
      throw Refusal.couldNotStart(arguments: arguments, reason: "no file for the output of git")
    }
    return Output(url: url, handle: handle)
  }

  /// The file one run writes its output into.
  private struct Output {
    let url: URL
    let handle: FileHandle

    func text() -> String {
      guard let data = try? Data(contentsOf: url) else {
        return ""
      }
      return String(decoding: data, as: UTF8.self)
    }

    func remove() {
      try? FileManager.default.removeItem(at: url)
    }
  }
}
