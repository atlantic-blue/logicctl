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

/// A step is written into the session that carries the path of the open project. A driver that
/// named another project would write this work into the history of that one.
@Test func theFakeNamesTheProjectItHasOpen() throws {
  let project = Conformance.aProjectWithOneTrack
  let driver = FakeLogicDriver(state: project, path: "/Users/someone/Music/Untitled.logicx")

  try Conformance.namesTheProjectItHasOpen.run(against: driver, holding: project)
}

/// The path is a read of Logic like the other two, so a fake with no Logic refuses it as well.
@Test func aFakeWithNoLogicRefusesThePathToo() {
  let driver = FakeLogicDriver()

  #expect(throws: DriverRefusal.logicNotRunning) { try driver.projectPath() }
}
