import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// Answers what the watcher is doing: whether this Mac carries one, and which projects it covers.
///
/// `watch start` answers how many projects the watcher has to watch, and a number cannot be acted
/// on. A person with four sessions and three saved projects reads "3" and still does not know
/// whether the project they are working on today is one of the three. A save of a project the
/// watcher does not cover never becomes a `save` step, and nothing says so at the time. So this
/// names each project, and the person compares the list with the project in front of them.
///
/// It reads the journal and the launch agent, and never Logic. So it takes no lock, it writes no
/// step, and its answer carries no session and no step in `meta`, the way the data model asks.
struct WatchStatus: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Report whether this Mac carries a watcher, and which projects it covers.",
    discussion: """
      The answer carries the label launchd knows the watcher by, and the path of every project it \
      covers, the newest session first. A project that was never saved sits at no path, so \
      nothing on disk can be watched for it yet, and it is not in the list.

      A Mac that carries no watcher answers running false and exits 0, because that is a state \
      and not a failure.

      Example: logicctl watch status --pretty
      """)

  @OptionGroup var output: OutputOption

  func run() throws {
    let status = WatchStatus.answer(format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension WatchStatus {
  /// Reads the launch agent and the sessions, prints the envelope, and answers the number the
  /// process exits with.
  ///
  /// The agent and the root are given, so a test reads a property list in a folder of its own and
  /// sessions it wrote itself. Nothing a test runs reaches launchd, and no test reads the sessions
  /// of the operator.
  static func answer(
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

    let running = agent.isWritten
    let projects = WatchStatus.watchedProjects(underRoot: root)
    let data = JSONValue.object([
      "running": .bool(running),
      "label": .string(LaunchAgent.label),
      "projects": .number(Double(projects.count)),
    ])
    // This command reads no Logic, so it carries no session and no step in `meta`.
    let meta = AnswerMeta.refusal(version: Logicctl.version, from: started, to: now())
    return printer.write(Envelope.success(data: data, meta: meta))
  }

  /// The project of every session the watcher covers, the newest session first.
  ///
  /// The watcher watches a file on disk, so a session of a project that was never saved gives it
  /// nothing to watch and is left out. `sessions --relink` can point two sessions at one project,
  /// and the watcher watches that project once, so each path is in the answer once.
  static func watchedProjects(underRoot root: URL) -> [String] {
    let newestFirst = SessionIndex.sessions(underRoot: root)
      .sorted { $0.createdAt > $1.createdAt }
    var seen: Set<String> = []
    var paths: [String] = []
    for session in newestFirst {
      guard let path = session.project.path, seen.insert(path).inserted else {
        continue
      }
      paths.append(path)
    }
    return paths
  }
}
