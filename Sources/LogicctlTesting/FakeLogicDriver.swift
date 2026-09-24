import LogicctlCore

/// The driver a test uses where there is no Logic.
///
/// It holds one state in memory and answers it. It refuses what the real driver refuses: with no
/// Logic to read, every read throws `DriverRefusal.logicNotRunning`. A fake that answered there
/// would make every test of a command a false pass, because the pipeline has no Logic at all.
public final class FakeLogicDriver: LogicDriver {
  /// The state the driver answers. Nil stands for a Mac where Logic is not running.
  public var state: State?

  /// The process id the driver answers. Nil stands for a Mac where Logic is not running.
  public var runningProcessID: Int32?

  /// Where the project sits. Nil stands for a project that was never saved.
  public var path: String?

  /// A Mac where Logic runs with one project open.
  public init(state: State, processID: Int32 = 4242, path: String? = nil) {
    self.state = state
    self.runningProcessID = processID
    self.path = path
  }

  /// A Mac where Logic is not running. Every read refuses.
  public init() {
    self.state = nil
    self.runningProcessID = nil
    self.path = nil
  }

  /// The state the driver holds.
  public func readState() throws -> State {
    guard let state else { throw DriverRefusal.logicNotRunning }
    return state
  }

  /// Where the project the driver holds sits. A driver with no Logic refuses, as the real one
  /// does, because a path answered where no Logic runs would send a step into a session of a
  /// project nobody has open.
  public func projectPath() throws -> String? {
    guard state != nil else { throw DriverRefusal.logicNotRunning }
    return path
  }

  /// The process id the driver holds.
  public func processID() throws -> Int32 {
    guard let runningProcessID else { throw DriverRefusal.logicNotRunning }
    return runningProcessID
  }
}
