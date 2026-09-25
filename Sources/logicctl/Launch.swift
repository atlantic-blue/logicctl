import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac

/// Starts Logic and answers once Logic shows its window.
///
/// A command that answered the moment macOS was asked to start Logic would hand back a Logic with
/// no window, and every command after it would read an empty Accessibility tree and fail on a Logic
/// that is in fact starting. So this command owns the wait, and a person or an agent runs one
/// command and then knows Logic is ready.
///
/// The wait has a limit, five seconds by default, and `--timeout` changes it. A window that never
/// appears fails with `timeout`, which exits 6, and the answer says how long Logic got.
///
/// It writes no journal step. Logic starts before any project is open, so there is no project path,
/// no session to write into, and `meta.session` and `meta.step` are null, as they are for `status`.
struct Launch: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "launch",
    abstract: "Start Logic and wait until Logic shows its window.",
    discussion: """
      The command answers once the window is there, so the next command reads a Logic that is \
      ready. A window that never appears fails with timeout.

      Example: logicctl launch --timeout 20s
      """)

  @OptionGroup var output: OutputOption

  @OptionGroup var wait: TimeoutOption

  /// The limit of the one wait this command makes, in milliseconds.
  var limitMs: Int {
    wait.timeout.milliseconds
  }

  func run() throws {
    let status = Launch.answer(of: AppControl.live(), limitMs: limitMs, format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension Launch {
  /// Starts Logic, waits for its window, prints the envelope, and answers the number the process
  /// exits with.
  ///
  /// The control is given rather than reached for, so the pipeline drives this against a Logic of
  /// its own, and the command line drives it against the Logic of this Mac. The clock and the sleep
  /// are given for the same reason: a test drives a five second wait in no time.
  static func answer(
    of control: AppControl,
    limitMs: Int = Wait.defaultLimitMs,
    format: OutputFormat = .compact,
    now: () -> Date = { Date() },
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds,
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    // This command talks to Logic, and it carries no session and no step because no project is
    // open to find a session by.
    func meta() -> Meta {
      AnswerMeta.run(
        version: Logicctl.version, session: nil, step: nil, externalChange: nil, from: started,
        to: now())
    }

    do {
      try control.start()
      let logic = try Launch.logicShowingAWindow(
        through: control, limitMs: limitMs, clock: clock, sleeper: sleeper)
      return printer.write(
        Envelope.success(
          data: .object([
            "running": .bool(true),
            "pid": .number(Double(logic.processID)),
          ]),
          meta: meta()))
    } catch let ranOut as Wait.RanOut {
      return printer.write(Envelope.failure(ranOut.failure, meta: meta()))
    } catch {
      return printer.write(Envelope.failure(Run.failure(for: error), meta: meta()))
    }
  }

  /// The Logic that shows a window, read again until it does.
  static func logicShowingAWindow(
    through control: AppControl,
    limitMs: Int,
    clock: @escaping Wait.Clock,
    sleeper: @escaping Wait.Sleeper
  ) throws -> RunningLogic {
    // The wait arrives in the next commit. This one reads Logic once, so the scenario runs and
    // fails on what it read back rather than on a build.
    guard let seen = try control.read() else {
      throw Wait.RanOut(waitedMs: limitMs)
    }
    return seen
  }
}
