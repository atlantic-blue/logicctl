import Foundation
import LogicctlCore

/// Where the work of one session was last safe on disk.
///
/// Logic can end while a command runs, and every change a person made since the last save ends
/// with it. The failure names the step that saved, so the person reads how much work is gone
/// without opening the project to find out.
public enum SaveLookup {
  /// The name of the command that saves a project.
  static let saveCommand = "save"

  /// The commit of the newest step that saved the project, or nothing when no step saved it.
  ///
  /// A history that cannot be read answers nothing. This fills one field of a failure that has
  /// already happened, so it must not turn that failure into another one.
  public static func lastSavedCommit(in repository: SessionRepository) -> String? {
    guard
      let printed = try? repository.git.run(["log", "--format=%H %s"], in: repository.folder)
    else {
      return nil
    }
    for line in printed.split(separator: "\n") {
      // The subject of a step is its sequence and then its name, and the first commit of a
      // session carries no sequence at all. The sequence is what leads to the record of the step,
      // and the record is where a save says it worked.
      let fields = line.split(separator: " ", maxSplits: 1)
      guard fields.count == 2, let sequence = Int(fields[1].prefix(while: \.isNumber)) else {
        continue
      }
      guard saved(stepOfSequence: sequence, in: repository) else {
        continue
      }
      return String(fields[0])
    }
    return nil
  }

  /// True when the step of one sequence wrote the project to disk.
  ///
  /// A save is a step of kind `save`, or a step of the `save` command. A save that ended with a
  /// failure wrote nothing, so the work was never safe at that step.
  static func saved(stepOfSequence sequence: Int, in repository: SessionRepository) -> Bool {
    guard case .object(let members) = record(ofSequence: sequence, in: repository) else {
      return false
    }
    guard case .number(let exitCode) = members["exitCode"] ?? .null, exitCode == 0 else {
      return false
    }
    if case .string(let kind) = members["kind"] ?? .null, kind == Step.Kind.save.rawValue {
      return true
    }
    if case .string(let command) = members["command"] ?? .null, command == saveCommand {
      return true
    }
    return false
  }

  /// What the `step.json` of one step holds, or null when there is no reading it.
  static func record(ofSequence sequence: Int, in repository: SessionRepository) -> JSONValue {
    let file =
      repository.folder
      .appendingPathComponent("steps")
      .appendingPathComponent(SessionRepository.stepFolderName(ofSequence: sequence))
      .appendingPathComponent("step.json")
    guard let data = try? Data(contentsOf: file),
      let value = try? CanonicalJSON.value(of: String(decoding: data, as: UTF8.self))
    else {
      return .null
    }
    return value
  }
}
