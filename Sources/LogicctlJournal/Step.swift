import CryptoKit
import Foundation
import LogicctlCore

/// What `step.json` holds: one command of logicctl, or one change that happened without it.
public struct Step: Sendable, Equatable {
  /// What wrote the step.
  public enum Kind: String, Sendable, Equatable, CaseIterable {
    case command = "command"
    case externalChange = "external_change"
    case save = "save"
    case replayCheck = "replay_check"
  }

  /// One file a step read, as the record keeps it.
  public struct Input: Sendable, Equatable {
    /// The name the copy takes under `inputs/`.
    public var name: String

    /// The hash of the bytes, so a reader can tell the copy from another file.
    public var sha256: String

    /// How many bytes the file holds.
    public var bytes: Int

    public init(name: String, sha256: String, bytes: Int) {
      self.name = name
      self.sha256 = sha256
      self.bytes = bytes
    }

    /// This part of `step.json` as a JSON value.
    public var json: JSONValue {
      .object([
        "name": .string(name),
        "sha256": .string(sha256),
        "bytes": .number(Double(bytes)),
      ])
    }
  }

  /// The version of the schema the step was written with.
  public var schema: Int

  /// The number of the step, from 1, with no gap inside a session.
  public var seq: Int

  /// What wrote the step.
  public var kind: Kind

  /// The subcommand, for example `tracks mute`. Null for a change that no command made.
  public var command: String?

  /// The arguments after the subcommand, as a person typed them.
  public var argv: [String]

  /// When the step started.
  public var startedAt: Date

  /// When the step ended.
  public var finishedAt: Date

  /// The code the command exited with.
  public var exitCode: Int

  /// The envelope the command printed, without `meta.step`, because the commit does not exist
  /// until the step is written.
  public var envelope: JSONValue

  /// The hash of the state before the step.
  public var stateBefore: String?

  /// The hash of the state after the step, or null when no Logic was left to read.
  public var stateAfter: String?

  /// What changed, as pointers into the state.
  public var differences: [Difference]

  /// The files the step read, one for each copy under `inputs/`.
  public var inputs: [Input]

  /// The name of the picture of the window, or null when the capture failed.
  public var screenshot: String?

  public init(
    schema: Int = 1,
    seq: Int,
    kind: Kind,
    command: String? = nil,
    argv: [String] = [],
    startedAt: Date,
    finishedAt: Date,
    exitCode: Int,
    envelope: JSONValue = .null,
    stateBefore: String? = nil,
    stateAfter: String? = nil,
    differences: [Difference] = [],
    inputs: [Input] = [],
    screenshot: String? = nil
  ) {
    self.schema = schema
    self.seq = seq
    self.kind = kind
    self.command = command
    self.argv = argv
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.exitCode = exitCode
    self.envelope = envelope
    self.stateBefore = stateBefore
    self.stateAfter = stateAfter
    self.differences = differences
    self.inputs = inputs
    self.screenshot = screenshot
  }

  /// The one line of the commit message: the sequence and the command. A step that no command
  /// wrote carries the word of its kind, because a commit needs a subject.
  public var subject: String {
    "\(seq) \(command ?? kind.rawValue)"
  }

  /// The three trailers of the commit. A state that could not be read is the word `null`, because
  /// a trailer carries a value and an empty one reads as a missing trailer.
  public var trailers: [String] {
    [
      "Logicctl-Kind: \(kind.rawValue)",
      "Logicctl-State-Before: \(stateBefore ?? "null")",
      "Logicctl-State-After: \(stateAfter ?? "null")",
    ]
  }

  /// The step as `step.json` holds it.
  ///
  /// The members are put in one at a time. A literal of every field at once asks the type checker
  /// for more than it will do, and it stops with "unable to type-check this expression".
  public var json: JSONValue {
    var members: [String: JSONValue] = [:]
    members["schema"] = .number(Double(schema))
    members["seq"] = .number(Double(seq))
    members["kind"] = .string(kind.rawValue)
    members["command"] = Step.text(command)
    members["argv"] = .array(argv.map { JSONValue.string($0) })
    members["startedAt"] = .string(Moment.text(of: startedAt))
    members["finishedAt"] = .string(Moment.text(of: finishedAt))
    members["exitCode"] = .number(Double(exitCode))
    members["envelope"] = envelope
    members["stateBefore"] = Step.text(stateBefore)
    members["stateAfter"] = Step.text(stateAfter)
    members["differences"] = .array(differences.map { Step.json(of: $0) })
    members["inputs"] = .array(inputs.map(\.json))
    members["screenshot"] = Step.text(screenshot)
    return .object(members)
  }

  /// One text as a JSON value, or null. A field of the record is null and never absent.
  static func text(_ value: String?) -> JSONValue {
    guard let value else {
      return .null
    }
    return .string(value)
  }

  /// One difference as a JSON value. A field that was added carries no `before` and a field that
  /// was removed carries no `after`, because a null is a value that Logic gave.
  static func json(of difference: Difference) -> JSONValue {
    var members: [String: JSONValue] = ["path": .string(difference.path)]
    if let before = difference.before {
      members["before"] = before
    }
    if let after = difference.after {
      members["after"] = after
    }
    return .object(members)
  }
}

/// One file a step read, with the bytes to copy beside `step.json`.
public struct InputFile: Sendable, Equatable {
  /// The name the copy takes under `inputs/`.
  public var name: String

  /// What the file holds.
  public var contents: Data

  public init(name: String, contents: Data) {
    self.name = name
    self.contents = contents
  }

  /// The record of the file, as `step.json` keeps it.
  public var record: Step.Input {
    Step.Input(name: name, sha256: InputFile.sha256(of: contents), bytes: contents.count)
  }

  /// The hash of some bytes, in hexadecimal.
  static func sha256(of contents: Data) -> String {
    SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
  }
}

extension SessionRepository {
  /// The sequence the next step takes: one more than the highest step the repository holds.
  public func nextSequence() -> Int {
    let steps = folder.appendingPathComponent("steps").path
    let names = (try? FileManager.default.contentsOfDirectory(atPath: steps)) ?? []
    let highest = names.compactMap { Int($0) }.max() ?? 0
    return highest + 1
  }

  /// Writes one step as one commit, and answers the id of that commit.
  ///
  /// The record of the picture and of the inputs is taken from the files that are written here, so
  /// `step.json` cannot claim a file the commit does not carry.
  @discardableResult
  public func write(
    _ step: Step,
    state: State?,
    screenshot: Data? = nil,
    inputs: [InputFile] = []
  ) throws -> String {
    var recorded = step
    recorded.inputs = inputs.map(\.record)
    recorded.screenshot = screenshot.map { _ in SessionRepository.screenshotName }
    let stepFolder = "steps/" + SessionRepository.stepFolderName(ofSequence: recorded.seq)

    return try lock.holding(folder) { () throws -> String in
      var staged: [String] = []
      if let state {
        try writeText(CanonicalJSON.text(of: state, indent: 2), to: "state.json")
        staged.append("state.json")
      }
      try make(stepFolder)
      try writeText(CanonicalJSON.text(of: recorded.json, indent: 2), to: stepFolder + "/step.json")
      staged.append(stepFolder + "/step.json")
      if let screenshot {
        let at = stepFolder + "/" + SessionRepository.screenshotName
        try writeData(screenshot, to: at)
        staged.append(at)
      }
      if !inputs.isEmpty {
        try make(stepFolder + "/inputs")
      }
      for file in inputs {
        let at = stepFolder + "/inputs/" + file.name
        try writeData(file.contents, to: at)
        staged.append(at)
      }
      try git.run(["add", "--"] + staged, in: folder)
      try commit(subject: recorded.subject, trailers: recorded.trailers)
      return try head()
    }
  }

  /// Makes one folder inside the repository.
  private func make(_ relative: String) throws {
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent(relative), withIntermediateDirectories: true)
  }
}
