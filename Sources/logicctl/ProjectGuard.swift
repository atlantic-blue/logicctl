import LogicctlCore

/// Runs one command that changes the project of Logic.
///
/// A change to a project a person made is theirs to allow, so this is where that question is
/// asked. The guard itself arrives in the next commit, and this one answers as though every
/// project were open to logicctl.
extension Run {
  /// Runs one command that changes the project.
  func run(change command: any LogicCommand, confirmed: Bool) -> Envelope {
    _ = confirmed
    return run(command: command)
  }
}
