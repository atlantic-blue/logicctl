import LogicctlCore

/// The part of logicctl that writes a session to a git repository.
///
/// It carries a placeholder until the step that fills it.
public enum LogicctlJournal {
  /// The name of this module.
  public static let moduleName = "LogicctlJournal"

  /// The name of the module this one is built on.
  public static let coreModuleName = LogicctlCore.moduleName
}
