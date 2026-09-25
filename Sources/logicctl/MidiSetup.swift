import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac

extension Midi {
  /// Reports the port logicctl sends notes to.
  ///
  /// The commands that play something, `midi note`, `midi chord` and `midi cc`, send to a port of
  /// the IAC driver of macOS named `logicctl`. A Mac without that port takes those notes and drops
  /// them, and nothing says so: the command works, Logic hears nothing, and the region stays
  /// empty. So this command answers the one question those three depend on, before a person spends
  /// a take finding out.
  ///
  /// It makes nothing. The IAC driver is a switch in Audio MIDI Setup, and only a person moves it.
  /// A Mac that carries no such port gets the failure and the three steps that switch it on.
  ///
  /// It reads no Logic, so it takes no session lock and it writes no step.
  struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "setup",
      abstract: "Report the IAC bus that logicctl sends MIDI to.",
      discussion: """
        The bus is a port of the IAC driver of macOS, named logicctl. Make it once in Audio MIDI \
        Setup, and every MIDI command of logicctl reaches Logic through it.

        Example: logicctl midi setup
        """)

    @OptionGroup var output: OutputOption

    func run() throws {
      let status = Midi.Setup.answer(of: MidiBus.live(), format: output.format)
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Midi.Setup {
  /// What a person does when this Mac carries no such port.
  static let driverOff =
    "The IAC driver is off. Open Audio MIDI Setup, show the MIDI Studio, and enable the IAC Driver"

  /// Looks for the bus, prints the envelope, and answers the number the process exits with.
  ///
  /// `seenByLogic` is the offline property of the port and nothing more. CoreMIDI says whether this
  /// Mac carries the port and whether the port is online. It cannot say that Logic opened it, so
  /// this answer does not claim that.
  static func answer(
    of bus: MidiBus,
    format: OutputFormat = .compact,
    now: () -> Date = { Date() },
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let found = bus.named()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    // This command reads no Logic, so it carries no session and no step in `meta`.
    let meta = AnswerMeta.refusal(version: Logicctl.version, from: started, to: now())

    guard let found else {
      return printer.write(
        Envelope.failure(
          Failure(code: .midiUnavailable, message: driverOff, details: nil), meta: meta))
    }
    return printer.write(
      Envelope.success(
        data: .object([
          "bus": .string(found.name),
          "seenByLogic": .bool(!found.isOffline),
        ]),
        meta: meta))
  }
}
