import LogicctlCore

/// The part of logicctl that talks to macOS: Accessibility, CoreMIDI and posted events.
///
/// It carries a placeholder until the step that fills it.
public enum LogicctlMac {
  /// The name of this module.
  public static let moduleName = "LogicctlMacintosh"

  /// The name of the module this one is built on.
  public static let coreModuleName = LogicctlCore.moduleName
}
