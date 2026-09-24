import Testing
import logicctl

/// The command is named logicctl, which is the name a person types.
@Test func theCommandIsNamedLogicctl() {
  #expect(Logicctl.configuration.commandName == "logicctl")
}
