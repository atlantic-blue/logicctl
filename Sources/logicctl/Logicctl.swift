import ArgumentParser
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// The command line tool that drives Logic Pro.
///
/// It carries a placeholder command until the step that adds the root command and its flags.
@main
struct Logicctl: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "logicctl",
    abstract: "Drive Logic Pro from the command line.")

  /// The modules the tool is built from, in the order the package declares them.
  static let modules = [
    LogicctlCore.moduleName,
    LogicctlJournal.moduleName,
    LogicctlMac.moduleName,
  ]

  func run() throws {
    print(Self.modules.joined(separator: " "))
  }
}
