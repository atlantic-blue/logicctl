import LogicctlMac
import Testing

/// The macOS layer is built on the core, so a driver can answer with the state the core holds.
@Test func theMacLayerIsBuiltOnTheCore() {
  #expect(LogicctlMac.coreModuleName == "LogicctlCore")
}
