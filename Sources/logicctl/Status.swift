import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac

/// Reports what Logic is doing.
///
/// This is the first question a person or an agent asks, and it is the one question where a Mac
/// with no Logic is a normal answer. So the command exits 0 there and says `running` false, and a
/// script reads that one field and decides whether to launch Logic. A failure with its own exit
/// code would stop that script on a condition that is not a fault.
///
/// It writes no journal step yet. Nothing in logicctl builds the whole driver over the real Logic
/// so far, so there is no state to compare and no session to write into. The step that brings the
/// whole driver routes this command through the run, and `meta.session` and `meta.step` are null
/// until then.
struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Report whether Logic runs, what it shows and which version it is.",
    discussion: """
      A Mac where Logic is not running answers running false and exits 0, because that is a \
      state and not a failure.

      Example: logicctl status
      """)

  @OptionGroup var output: OutputOption

  func run() throws {
    let status = Status.answer(of: AXDriver(), format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension Status {
  /// Reads what Logic is doing, prints the envelope, and answers the number the process exits
  /// with.
  ///
  /// The reader is given rather than reached for, so the pipeline drives this against a tree that
  /// was recorded from Logic 12.3.1 and the command line drives it against the Logic that runs
  /// now. One answer serves both.
  static func answer(
    of reader: any LogicStatusReader,
    format: OutputFormat = .compact,
    now: () -> Date = { Date() },
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    // This command reads Logic, so it is a command that talks to Logic. It carries no session and
    // no step because no session exists to write into yet.
    func meta() -> Meta {
      AnswerMeta.run(
        version: Logicctl.version, session: nil, step: nil, externalChange: nil, from: started,
        to: now())
    }

    do {
      let read = try reader.status()
      return printer.write(
        Envelope.success(
          data: .object([
            "running": .bool(read.running),
            "frontmost": .bool(read.frontmost),
            "window": read.window.map(JSONValue.string) ?? .null,
            "version": read.version.map(JSONValue.string) ?? .null,
          ]),
          meta: meta()))
    } catch {
      return printer.write(Envelope.failure(Run.failure(for: error), meta: meta()))
    }
  }
}
