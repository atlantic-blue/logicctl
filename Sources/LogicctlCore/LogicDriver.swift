/// What a command talks to when it reads Logic or changes it.
///
/// This protocol is the whole seam between a command and Logic. The driver over Accessibility
/// lives in `LogicctlMac`, and `FakeLogicDriver` in `LogicctlTesting` stands in its place where
/// there is no Logic to read. Later steps add one operation each.
public protocol LogicDriver {
  /// The state of the project Logic has open.
  func readState() throws -> State

  /// The process id of Logic. A command reads it before an action and again after it, because a
  /// Logic that went away between the two lost the work of the command.
  func processID() throws -> Int32
}

/// Why a driver refused.
///
/// The raw value is the name of the failure in the design system, so the step that brings the
/// envelope joins the two with no change to a driver.
public enum DriverRefusal: String, Error, Equatable, Sendable {
  /// Logic is not running, so there is no project to read.
  case logicNotRunning = "logic_not_running"
}
