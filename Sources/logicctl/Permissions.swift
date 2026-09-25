import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac

/// Reports whether this Mac lets logicctl drive Logic.
///
/// Every other command of logicctl needs both grants: it reads the interface of Logic through
/// Accessibility, and it saves a picture of the window through Screen Recording. A tool without
/// them does not fail with something a caller can read. It reads an empty interface and finds
/// nothing, which looks the same as a project with nothing in it. So this command answers the
/// question on its own, with its own code and its own exit number, before anything asks Logic for
/// anything.
///
/// It grants nothing itself. macOS puts the switch in System Settings, and only a person moves it.
/// A grant that is missing opens the prompt of macOS one time, so the person has the shortest way
/// to that switch, and the answer says that the prompt opened.
struct Permissions: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "permissions",
    abstract: "Report the Accessibility and Screen Recording grants of logicctl.",
    discussion: """
      A missing grant opens the prompt of macOS once. Grant it in System Settings, then run the \
      command again.

      Example: logicctl permissions
      """)

  @OptionGroup var output: OutputOption

  func run() throws {
    let status = Permissions.answer(of: Grants.live(), format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension Permissions {
  /// What a person does about a grant that is missing.
  static let missingGrant = "Grant Accessibility and Screen Recording to logicctl"

  /// Reads both grants, opens the prompt of each grant that is missing, prints the envelope, and
  /// answers the number the process exits with.
  ///
  /// This command reads nothing from Logic, so it writes no step and it takes no session lock. The
  /// answer carries no session and no step either, whichever way it went.
  static func answer(
    of grants: Grants,
    format: OutputFormat = .compact,
    now: () -> Date = { Date() },
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let accessibility = grants.accessibility()
    let screenRecording = grants.screenRecording()

    // macOS gives no way to read the answer to a prompt in the same run, so the command asks for
    // each missing grant and then answers with what it read before it asked.
    if !accessibility {
      grants.promptForAccessibility()
    }
    if !screenRecording {
      grants.promptForScreenRecording()
    }

    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)
    let meta = AnswerMeta.refusal(version: Logicctl.version, from: started, to: now())
    guard accessibility, screenRecording else {
      return printer.write(
        Envelope.failure(
          Failure(
            code: .permissionMissing,
            message: missingGrant,
            details: .object([
              "accessibility": .bool(accessibility),
              "screenRecording": .bool(screenRecording),
              "prompted": .bool(true),
            ])),
          meta: meta))
    }
    return printer.write(
      Envelope.success(
        data: .object([
          "accessibility": .bool(accessibility),
          "screenRecording": .bool(screenRecording),
        ]),
        meta: meta))
  }
}
