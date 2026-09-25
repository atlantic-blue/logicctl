import LogicctlCore

/// The driver a test uses where there is no Logic.
///
/// It holds one state in memory and answers it. It refuses what the real driver refuses: with no
/// Logic to read, every read throws `DriverRefusal.logicNotRunning`. A fake that answered there
/// would make every test of a command a false pass, because the pipeline has no Logic at all.
public final class FakeLogicDriver: LogicDriver, LogicStatusReader {
  /// The state the driver answers. Nil stands for a Mac where Logic is not running.
  public var state: State?

  /// The process id the driver answers. Nil stands for a Mac where Logic is not running.
  public var runningProcessID: Int32?

  /// Where the project sits. Nil stands for a project that was never saved.
  public var path: String?

  /// True while Logic is the application in front. A Mac where Logic is not running answers
  /// false whatever this says.
  public var frontmost = false

  /// The title of the front window of Logic, or nil when Logic shows no window.
  public var window: String?

  /// The dialog Logic waits on. Nil stands for a Logic with no modal window open. A command of a
  /// test opens one by setting it while it acts, which is when Logic opens one.
  public var dialog: ModalDialog?

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

  /// The dialog the driver holds. A driver with no Logic refuses, as every other read does: a
  /// fake that answered "no dialog" where it cannot see would let a command through that the real
  /// driver stops.
  public func modalDialog() throws -> ModalDialog? {
    guard state != nil else { throw DriverRefusal.logicNotRunning }
    return dialog
  }

  /// What Logic is doing, as the fake holds it.
  ///
  /// This is the one read that does not refuse where Logic is not running, because the real driver
  /// does not refuse there either. A fake that threw here would let the command that answers the
  /// question pass a test it fails on a real Mac.
  public func status() throws -> LogicStatus {
    guard let state else {
      return LogicStatus.notRunning
    }
    return LogicStatus(
      running: true, frontmost: frontmost, window: window, version: state.logic.version)
  }
}
