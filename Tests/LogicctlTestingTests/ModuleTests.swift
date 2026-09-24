import LogicctlTesting
import Testing

/// The test support is built on the core, so a fake driver answers what the real one answers.
@Test func theTestSupportIsBuiltOnTheCore() {
  #expect(LogicctlTesting.coreModuleName == "LogicctlCore")
}
