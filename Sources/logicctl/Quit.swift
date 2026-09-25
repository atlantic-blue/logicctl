import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac

/// Closes Logic, and stops when the project has unsaved changes.
///
/// Logic is the authority on whether there is work to lose. A project with unsaved changes holds
/// the request to close and asks the person what to do, so Logic is still running when this command
/// reads it back. That refusal is the whole point of the command: a person or an agent never loses
/// the work of a session to one word. logicctl answers the question Logic then shows on no account,
/// because pressing a button in it would decide what happens to that work.
///
/// `--save` writes the project where it already sits and then closes Logic. `--discard` ends Logic
/// and every change since the last save, which is why it needs `--confirm` from the person who
/// typed it.
///
/// It writes no journal step, as `launch` writes none. Logic is gone when the command answers, so
/// there is no state to read again and no window to photograph, and `meta.session` and `meta.step`
/// are null.
struct Quit: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "quit",
    abstract: "Close Logic, and stop when the project has unsaved changes.",
    discussion: """
      A project with unsaved changes stops the command, and Logic stays open. --save writes the \
      project first. --discard closes Logic without saving, and loses every change since the last \
      save, so it needs --confirm.

      Example: logicctl quit --save
      """)

  @Flag(help: "Write the project where it sits before Logic closes.")
  var save = false

  @Flag(help: "Close Logic without saving. It needs --confirm.")
  var discard = false

  @OptionGroup var confirm: ConfirmOption

  @OptionGroup var output: OutputOption

  @OptionGroup var wait: TimeoutOption

  /// The limit of the one wait this command makes, in milliseconds.
  var limitMs: Int {
    wait.timeout.milliseconds
  }

  func validate() throws {
    guard !(save && discard) else {
      throw ValidationError("Give one of --save and --discard, not both.")
    }
  }

  func run() throws {
    let status = Quit.answer(
      of: AppControl.live(),
      driver: Quit.liveDriver(),
      saving: save,
      discarding: discard,
      confirmed: confirm.confirm,
      limitMs: limitMs,
      format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension Quit {
  /// Closes Logic, prints the envelope, and answers the number the process exits with.
  ///
  /// The control and the driver are given rather than reached for, so the pipeline drives the same
  /// command against a Logic of its own. The clock and the sleep are given for the same reason: a
  /// test drives a five second wait in no time.
  static func answer(
    of control: AppControl,
    driver: any LogicDriver,
    saving: Bool = false,
    discarding: Bool = false,
    confirmed: Bool = false,
    version: String = Logicctl.version,
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

    // This command talks to Logic, and it carries no session and no step because it writes none.
    func meta() -> Meta {
      AnswerMeta.run(
        version: version, session: nil, step: nil, externalChange: nil, from: started, to: now())
    }

    // A forced close answers no question and cannot be taken back, so the word of the person who
    // typed it comes before Logic is read, let alone asked for anything.
    if discarding && !confirmed {
      return printer.write(
        Envelope.failure(
          Quit.needsConfirm, meta: AnswerMeta.refusal(version: version, from: started, to: now())))
    }

    do {
      guard try control.read() != nil else {
        throw DriverRefusal.logicNotRunning
      }
      // The name of the project is read before anything acts on Logic. After the close there is
      // no project to read it from, and the refusal is the one answer that names it.
      let named = (try? driver.readState())?.project.name

      if saving {
        guard let path = try driver.projectPath(), !path.isEmpty else {
          return printer.write(
            Envelope.failure(
              Quit.neverSaved,
              meta: AnswerMeta.refusal(version: version, from: started, to: now())))
        }
        try control.save()
      }

      if discarding {
        try control.end()
      } else {
        try control.close()
      }

      _ = named

      return printer.write(
        Envelope.success(data: .object(["running": .bool(false)]), meta: meta()))
    } catch let ranOut as Wait.RanOut {
      return printer.write(Envelope.failure(ranOut.failure, meta: meta()))
    } catch {
      return printer.write(Envelope.failure(Run.failure(for: error), meta: meta()))
    }
  }

  /// What the command stops with when `--discard` came without `--confirm`.
  static let needsConfirm = Failure(
    code: .confirmRequired,
    message: "quit --discard loses every change since the last save, so it needs --confirm.")

  /// What `--save` stops with for a project that sits nowhere yet.
  ///
  /// Save writes a project where it already is, and this one is nowhere. The panel that asks where
  /// a project goes takes a path, and the path is the thing a person chooses, so they choose it.
  static let neverSaved = Failure(
    code: .invalidArgument,
    message: "This project was never saved, so there is nowhere to write it. "
      + "Run save --path <path> first.")

  /// What a refused close answers, in the words the mockup shows.
  static func unsavedChanges(of named: String?) -> Failure {
    Failure(code: .unsavedChanges, message: "\(named ?? "The project") has unsaved changes")
  }

  /// What this command reads the state of Logic through on this Mac.
  ///
  /// Nothing in logicctl reads the whole state of Logic yet, so there is no driver over the real
  /// Logic to give here, and the name of the project is read from none. The part that reads the
  /// tracks brings one, and this command is written against the protocol so that it needs no
  /// change when it arrives.
  static func liveDriver() -> any LogicDriver {
    NewProject.liveDriver()
  }
}
