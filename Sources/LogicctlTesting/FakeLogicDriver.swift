import LogicctlCore

/// The driver a test uses where there is no Logic.
///
/// It holds one state in memory and answers it. It refuses what the real driver refuses: with no
/// Logic to read, both reads throw `DriverRefusal.logicNotRunning`. A fake that answered there
/// would make every test of a command a false pass, because the pipeline has no Logic at all.
public final class FakeLogicDriver: LogicDriver {
  /// The state the driver answers. Nil stands for a Mac where Logic is not running.
  public var state: State?

  /// The process id the driver answers. Nil stands for a Mac where Logic is not running.
  public var runningProcessID: Int32?

  /// A Mac where Logic runs with one project open.
  public init(state: State, processID: Int32 = 4242) {
    self.state = state
    self.runningProcessID = processID
  }

  /// A Mac where Logic is not running. Both reads refuse.
  public init() {
    self.state = nil
    self.runningProcessID = nil
  }

  /// The state the driver holds.
  public func readState() throws -> State {
    guard let state else { throw DriverRefusal.logicNotRunning }
    return state
  }

  /// The process id the driver holds.
  public func processID() throws -> Int32 {
    guard let runningProcessID else { throw DriverRefusal.logicNotRunning }
    return runningProcessID
  }
}
