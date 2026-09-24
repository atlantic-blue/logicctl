import LogicctlCore
import LogicctlJournal
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// A person clones logicctl, builds it and runs its tests, and the tool they get carries every
/// part of itself: the core, the journal, the macOS layer, the test support and the command.
@Test func thePackageBuilds() {
  #expect(Logicctl.configuration.commandName == "logicctl")
  #expect(Logicctl.modules == ["LogicctlCore", "LogicctlJournal", "LogicctlMac"])
  #expect(LogicctlTesting.moduleName == "LogicctlTesting")
  #expect(LogicctlJournal.coreModuleName == LogicctlCore.moduleName)
  #expect(LogicctlMac.coreModuleName == LogicctlCore.moduleName)
  #expect(LogicctlTesting.coreModuleName == LogicctlCore.moduleName)
}
