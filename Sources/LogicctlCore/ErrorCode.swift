/// Every failure logicctl reports, with the number the process exits with.
///
/// `design-system.json` in the repository root holds the same list, and a test refuses any
/// difference between the two. A number belongs to one code for good: a code that is retired keeps
/// its number, so a script that reads an exit code never sees its meaning move.
public enum ErrorCode: String, CaseIterable {
  case invalidArgument = "invalid_argument"
  case permissionMissing = "permission_missing"
  case logicNotRunning = "logic_not_running"
  case elementNotFound = "element_not_found"
  case timeout = "timeout"
  case confirmRequired = "confirm_required"
  case unsavedChanges = "unsaved_changes"
  case pathExists = "path_exists"
  case trackNotFound = "track_not_found"
  case pluginNotFound = "plugin_not_found"
  case midiUnavailable = "midi_unavailable"
  case journalFailed = "journal_failed"
  case replayDifferences = "replay_differences"
  case dialogOpen = "dialog_open"
  case regionNotFound = "region_not_found"
  case noteNotFound = "note_not_found"
  case pointNotFound = "point_not_found"
  case selectionMismatch = "selection_mismatch"
  case logicCrashed = "logic_crashed"

  /// Any other failure. `internal` is a keyword in Swift, so only the name of the case differs;
  /// what goes out is still `internal`.
  case internalFailure = "internal"

  /// The number the process exits with after this failure. 0 belongs to success alone.
  public var exitCode: Int32 {
    switch self {
    case .invalidArgument: return 2
    case .permissionMissing: return 3
    case .logicNotRunning: return 4
    case .elementNotFound: return 5
    case .timeout: return 6
    case .confirmRequired: return 7
    case .unsavedChanges: return 8
    case .pathExists: return 9
    case .trackNotFound: return 10
    case .pluginNotFound: return 12
    case .midiUnavailable: return 13
    case .journalFailed: return 14
    case .replayDifferences: return 15
    case .dialogOpen: return 16
    case .regionNotFound: return 17
    case .noteNotFound: return 18
    case .pointNotFound: return 19
    case .selectionMismatch: return 20
    case .logicCrashed: return 21
    case .internalFailure: return 70
    }
  }
}
