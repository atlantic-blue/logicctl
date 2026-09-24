import LogicctlCore
import LogicctlTesting
import Testing

/// A command reaches Logic through the driver and through nothing else, and the pipeline has no
/// Logic. So the double has to answer the project it stands for, or no test of a command means
/// anything.
@Test func theFakeReadsBackItsState() throws {
  let project = Conformance.aProjectWithOneTrack
  let driver = FakeLogicDriver(state: project)

  try Conformance.readsBackItsState.run(against: driver, holding: project)
}

/// The other half of the same seam. A fake that answered where the real driver refuses would turn
/// every later test into a false pass.
@Test func aFakeWithNoLogicRefusesBothReads() {
  let driver = FakeLogicDriver()

  #expect(throws: DriverRefusal.logicNotRunning) { try driver.readState() }
  #expect(throws: DriverRefusal.logicNotRunning) { try driver.processID() }
}
