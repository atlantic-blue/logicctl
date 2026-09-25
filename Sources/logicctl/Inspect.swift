import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac

/// Prints the tree of elements that Logic shows, as logicctl reads it.
///
/// Logic answers only through Accessibility, so every other command finds what it needs by walking
/// this tree. Nothing here changes anything: it is the command a person runs to see what Logic
/// shows, and the command that records the tree of one version of Logic to a file. The file is the
/// only way a pipeline with no Logic can prove a walk, because `RecordedTree` reads back what this
/// writes.
///
/// It writes no journal step yet. Nothing in logicctl builds a driver over the real Logic so far,
/// so there is no session to write into. The step that brings the driver routes this command
/// through the run, and `meta.session` and `meta.step` are null until then.
struct Inspect: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inspect",
    abstract: "Print the tree of elements Logic shows.",
    discussion: """
      Each element carries its role, its title, its identifier, its value, what it can be asked \
      to do, and the elements under it.

      Example: logicctl inspect --depth 4
      """)

  /// Where the walk starts. Only the main window can be named, because that is the one window
  /// every other command reads.
  enum Window: String, ExpressibleByArgument, CaseIterable {
    case main
  }

  /// What this command refuses with on its own.
  enum Refusal: Error {
    /// `--window main` was given and Logic shows no window at all.
    case noWindow
  }

  @Option(help: "How many levels to print, counted from the element it starts at, from 1.")
  var depth: Int = 4

  @Option(help: "Start at the main window of Logic instead of at the application.")
  var window: Window?

  @Option(help: "Write the tree to this file as well as printing it.")
  var out: String?

  @OptionGroup var output: OutputOption

  func validate() throws {
    guard depth >= 1 else {
      throw ValidationError("--depth counts the levels from 1, so give 1 or more.")
    }
    guard let out else {
      return
    }
    let folder = URL(fileURLWithPath: out).deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: folder.path) else {
      throw ValidationError("--out names a folder that is not there: \(folder.path).")
    }
  }

  func run() throws {
    let status = answer(of: LogicTree.ofRunningLogic, format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension Inspect {
  /// Walks the tree a source answers with, prints the envelope, and answers the number the process
  /// exits with.
  ///
  /// The source is a closure, so the pipeline drives this against a tree that was recorded from
  /// Logic 12.3.1, and the command line drives it against the Logic that runs now. One walk serves
  /// both.
  func answer(
    of source: () throws -> LogicTree,
    format: OutputFormat = .compact,
    now: () -> Date = { Date() },
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    // This command reads the tree of Logic, so it is a command that talks to Logic. It carries no
    // session and no step because no session exists to write into yet.
    func meta() -> Meta {
      AnswerMeta.run(
        version: Logicctl.version, session: nil, step: nil, externalChange: nil, from: started,
        to: now())
    }

    do {
      let tree = try start(from: source())
      var written = JSONValue.null
      if let out {
        let file = URL(fileURLWithPath: out)
        try TreeWriter.write(tree, depth: depth, to: file)
        written = .string(file.path)
      }
      return printer.write(
        Envelope.success(
          data: .object([
            "logicVersion": .string(tree.logicVersion),
            "depth": .number(Double(depth)),
            "elementsAtEachDepth": .array(
              TreeWriter.counts(of: tree.root, depth: depth).map { .number(Double($0)) }),
            "out": written,
            "root": TreeWriter.json(of: tree.root, depth: depth),
          ]),
          meta: meta()))
    } catch {
      return printer.write(Envelope.failure(Inspect.failure(for: error), meta: meta()))
    }
  }

  /// The tree the walk starts at: the whole application, or the window that `--window` named.
  private func start(from tree: LogicTree) throws -> LogicTree {
    guard window == .main else {
      return tree
    }
    guard let front = tree.atTheFrontWindow() else {
      throw Refusal.noWindow
    }
    return front
  }

  /// The failure an error stopped the command with.
  static func failure(for error: Error) -> Failure {
    if let refusal = error as? Refusal {
      switch refusal {
      case .noWindow:
        return Failure(
          code: .elementNotFound,
          message: "Logic shows no window, so there is no main window to start the tree at.")
      }
    }
    if let refusal = error as? DriverRefusal, let code = ErrorCode(rawValue: refusal.rawValue) {
      return Failure(code: code, message: Run.sentence(of: code))
    }
    return Failure(
      code: .internalFailure,
      message: "The tree could not be written.",
      details: .object(["reason": .string(String(describing: error))]))
  }
}
