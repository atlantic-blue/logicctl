import LogicctlCore

/// The part of logicctl that other modules test against: the fake driver and the conformance suite.
///
/// It carries a placeholder until the step that fills it.
public enum LogicctlTesting {
  /// The name of this module.
  public static let moduleName = "LogicctlTesting"

  /// The name of the module this one is built on.
  public static let coreModuleName = LogicctlCore.moduleName
}
