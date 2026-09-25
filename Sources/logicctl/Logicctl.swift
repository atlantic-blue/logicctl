import ArgumentParser
import Darwin
import Foundation
import LogicctlCore

/// The command line tool that drives Logic Pro.
///
/// Nothing reaches Logic until the arguments are right. A flag that does not exist, a flag that is
/// missing, a flag given twice over and a value outside the scale Logic shows all stop here. Each
/// one comes back as the JSON every other answer is written in, with the code `invalid_argument`
/// and the exit number the design system gives it, so a caller reads a refusal the same way it
/// reads a result. `--help` is the one answer that is not JSON.
@main
struct Logicctl: ParsableCommand {
  /// The version this build answers with, in `meta.version`.
  static let version = "0.1.0"

  static let configuration = CommandConfiguration(
    commandName: "logicctl",
    abstract: "Drive Logic Pro from the command line.",
    discussion: """
      Every answer but this one is a single JSON object on standard output.

      Example: logicctl --help
      """,
    subcommands: [
      Permissions.self, Inspect.self, Log.self, Sessions.self, Show.self, Launch.self,
      Status.self, NewProject.self, Save.self, Quit.self, Midi.self, Tracks.self,
      TransportCommand.self, Replay.self, Watch.self, Plugins.self,
    ])

  /// Reads the arguments of the process, answers on both channels, and exits with the number the
  /// design system gives what happened.
  static func main() {
    Darwin.exit(run(arguments: Array(CommandLine.arguments.dropFirst())))
  }

  /// Runs one command line and answers the number the process exits with.
  ///
  /// A test calls this with its own arguments and its own channels, and reads back both.
  static func run(
    arguments: [String],
    standardOutput: @escaping (String) -> Void = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping (String) -> Void = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = Date()
    do {
      var command = try parseAsRoot(arguments)
      try command.run()
      return 0
    } catch {
      // A command that printed its own envelope asks for the number it exits with, and nothing
      // else is written for it. Writing a second envelope here would put two JSON objects on
      // standard output, and the caller reads exactly one.
      if let asked = error as? ExitCode {
        return asked.rawValue
      }
      // `--help`, and a command that asks for help by having nothing to do, leave through here
      // too. They are not failures, so they keep the plain text of the library and exit 0.
      if exitCode(for: error).rawValue == 0 {
        standardOutput(fullMessage(for: error) + "\n")
        return 0
      }
      return report(
        error,
        arguments: arguments,
        since: started,
        standardOutput: standardOutput,
        standardError: standardError)
    }
  }

  /// Writes a refusal that happened before logicctl talked to Logic, and answers the number the
  /// process exits with.
  ///
  /// Every one of them is `invalid_argument`: the arguments were wrong, so Logic was never asked
  /// anything, nothing changed, and no step is written.
  static func report(
    _ error: Error,
    arguments: [String] = [],
    since started: Date = Date(),
    standardOutput: @escaping (String) -> Void = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping (String) -> Void = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let failure = Failure(code: .invalidArgument, message: sentence(for: error))
    let printer = EnvelopePrinter(
      format: arguments.contains("--pretty") ? .pretty : .compact,
      standardOutput: standardOutput,
      standardError: standardError)
    let meta = AnswerMeta.refusal(version: version, from: started, to: Date())
    return printer.write(Envelope.failure(failure, meta: meta))
  }

  /// What the refusal says, on one line, because standard error carries one line for the person
  /// reading along.
  private static func sentence(for error: Error) -> String {
    message(for: error)
      .split(whereSeparator: \.isNewline)
      .joined(separator: " ")
  }
}
