import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// The watcher that records a save a person made in Logic.
///
/// Every other command of logicctl writes a step because somebody typed it. A save is the one
/// change that happens without a command: a person presses Command S in Logic, the project on disk
/// changes, and no history holds that. The watcher closes that gap. It runs as a launch agent of
/// the user, so it comes back after a restart, and it writes a `save` step of its own.
///
/// `start`, `status` and `stop` manage the agent. They read no Logic, so they take no lock, they
/// write no step, and their answers carry no session and no step in `meta`, the way the data model
/// asks.
struct Watch: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch",
    abstract: "Start, read and stop the watcher that records a save made in Logic.",
    discussion: """
      Example: logicctl watch start
      """,
    subcommands: [Start.self, WatchStatus.self, Stop.self, WatchRun.self])
}

extension Watch {
  /// Writes the launch agent and loads it.
  struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "start",
      abstract: "Start the watcher that records a save made in Logic.",
      discussion: """
        The watcher runs as a launch agent of this user, so it starts again after a restart. It \
        watches the project of every session logicctl recorded, and the answer counts those \
        projects. A project that was never saved sits at no path, so nothing on disk can be \
        watched for it yet, and it is not counted.

        Running this again over a watcher that already runs is safe: the agent is written again \
        and loaded again.

        Example: logicctl watch start
        """)

    @OptionGroup var output: OutputOption

    func run() throws {
      let status = Watch.started(format: output.format)
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }

  /// Unloads the launch agent and takes its file away.
  struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "stop",
      abstract: "Stop the watcher that records a save made in Logic.",
      discussion: """
        A Mac that carries no watcher has nothing to stop, so this command answers that none \
        runs and exits 0.

        A save made in Logic while no watcher runs is not recorded as a save step. The command \
        that comes next reads the project again and records the difference as an external change.

        Example: logicctl watch stop
        """)

    @OptionGroup var output: OutputOption

    func run() throws {
      let status = Watch.stopped(format: output.format)
      guard status == 0 else {
        throw ExitCode(status)
      }
    }
  }
}

extension Watch {
  /// Writes the launch agent, loads it, prints the envelope, and answers the number the process
  /// exits with.
  ///
  /// The agent and the root are given, so a test writes a property list into a folder of its own,
  /// loads it with a loader of its own, and reads the sessions it wrote itself. Nothing a test
  /// runs reaches launchd, and no test starts a watcher on the Mac that ran it.
  static func started(
    agent: LaunchAgent = LaunchAgent(),
    root: URL = SessionRepository.defaultRoot,
    format: OutputFormat = .compact,
    now: () -> Date = { Date() },
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    // This command reads no Logic, so it carries no session and no step in `meta`.
    func meta() -> Meta {
      AnswerMeta.refusal(version: Logicctl.version, from: started, to: now())
    }

    do {
      try agent.start()
    } catch {
      let refusal = Watch.failure(for: error, saying: "The watcher could not be started.")
      return printer.write(Envelope.failure(refusal, meta: meta()))
    }
    let data = JSONValue.object([
      "running": .bool(true),
      "label": .string(LaunchAgent.label),
      "projects": .number(Double(Watch.watchedProjects(underRoot: root))),
    ])
    return printer.write(Envelope.success(data: data, meta: meta()))
  }

  /// Unloads the launch agent, takes its file away, prints the envelope, and answers the number
  /// the process exits with.
  static func stopped(
    agent: LaunchAgent = LaunchAgent(),
    format: OutputFormat = .compact,
    now: () -> Date = { Date() },
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    func meta() -> Meta {
      AnswerMeta.refusal(version: Logicctl.version, from: started, to: now())
    }

    do {
      try agent.stop()
    } catch {
      let refusal = Watch.failure(for: error, saying: "The watcher could not be stopped.")
      return printer.write(Envelope.failure(refusal, meta: meta()))
    }
    let data = JSONValue.object(["running": .bool(false)])
    return printer.write(Envelope.success(data: data, meta: meta()))
  }

  /// How many projects the watcher has to watch.
  ///
  /// It watches what is on disk, so a session whose project was never saved is not one of them.
  /// The count is the number a person reads to tell a watcher that has work from a watcher that
  /// runs over nothing.
  static func watchedProjects(underRoot root: URL) -> Int {
    SessionIndex.sessions(underRoot: root)
      .filter { $0.project.path != nil }
      .count
  }

  /// The failure that a launch agent nobody could manage stops the command with.
  ///
  /// The design system holds no code for launchd. This command writes no step either, so the code
  /// of a step that could not be written is not it. What is left is `internal`, with the reason
  /// this Mac gave in the details.
  static func failure(for error: Error, saying message: String) -> Failure {
    Failure(
      code: .internalFailure,
      message: message,
      details: .object(["reason": .string(String(describing: error))]))
  }
}
