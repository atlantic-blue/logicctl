import Foundation
import LogicctlCore

/// One step of a session, as replay reads it back out of the history.
///
/// The commit is here because the number of a step leads to its record and the commit leads to the
/// state that step left. A record holds two hashes and no values, so a list of differences needs
/// the `state.json` of the commit itself.
public struct RecordedStep: Sendable, Equatable {
  /// The number of the step in the session it came from, from 1.
  public var seq: Int

  /// The commit that holds the step.
  public var commit: String

  /// What wrote the step.
  public var kind: Step.Kind

  /// The subcommand, for example `tracks mute`. Nothing for a step that no command wrote.
  public var command: String?

  /// The arguments after the subcommand, as a person typed them.
  public var argv: [String]

  public init(
    seq: Int,
    commit: String,
    kind: Step.Kind,
    command: String? = nil,
    argv: [String] = []
  ) {
    self.seq = seq
    self.commit = commit
    self.kind = kind
    self.command = command
    self.argv = argv
  }
}

/// Why replay passed over one step.
///
/// A skip is a failure of the replay and never a quiet pass, so each reason says what could not be
/// repeated. A person reads the word and knows whether to do something by hand or to wait for a
/// command that logicctl does not have yet.
public enum SkipReason: String, Sendable, Equatable, CaseIterable {
  /// A person made this change in Logic, so no command repeats it.
  case cannotRepeatAChangeByHand = "cannot_repeat_a_change_by_hand"

  /// Logic saved the project, and logicctl never saves to make a record.
  case cannotRepeatASave = "cannot_repeat_a_save"

  /// The step is a check that a replay wrote, and a check is not work on a project.
  case cannotRepeatACheck = "cannot_repeat_a_check"

  /// This build of logicctl has no command of that name.
  case noSuchCommand = "no_such_command"
}

/// One step replay passed over, and why.
public struct SkippedStep: Sendable, Equatable {
  /// The number of the step in the session that was replayed.
  public var seq: Int

  /// Why it was passed over.
  public var reason: SkipReason

  public init(seq: Int, reason: SkipReason) {
    self.seq = seq
    self.reason = reason
  }

  /// This part of the report as a JSON value.
  public var json: JSONValue {
    .object([
      "seq": .number(Double(seq)),
      "reason": .string(reason.rawValue),
    ])
  }
}

/// What replay found at one step: the fields of the project that are not what the step recorded.
public struct StepDifferences: Sendable, Equatable {
  /// The number of the step in the session that was replayed.
  public var seq: Int

  /// The fields that differ, as pointers into the state.
  public var differences: [Difference]

  public init(seq: Int, differences: [Difference]) {
    self.seq = seq
    self.differences = differences
  }

  /// This part of the report as a JSON value.
  public var json: JSONValue {
    .object([
      "seq": .number(Double(seq)),
      "differences": .array(differences.map { Step.json(of: $0) }),
    ])
  }
}

/// What one replay found, as the replay report of the data model.
public struct ReplayReport: Sendable, Equatable {
  /// The session that was replayed.
  public var source: String

  /// The session that replay recorded its own work in.
  public var session: String

  /// The first step commit that replay read.
  public var from: String

  /// The last step commit that replay read.
  public var to: String

  /// How many steps ran again.
  public var stepsRun: Int

  /// The steps replay passed over.
  public var skipped: [SkippedStep]

  /// What replay found, one item for each step that differed.
  public var differences: [StepDifferences]

  public init(
    source: String,
    session: String,
    from: String,
    to: String,
    stepsRun: Int,
    skipped: [SkippedStep] = [],
    differences: [StepDifferences] = []
  ) {
    self.source = source
    self.session = session
    self.from = from
    self.to = to
    self.stepsRun = stepsRun
    self.skipped = skipped
    self.differences = differences
  }

  /// True when the replay repeated the whole session: nothing was passed over, and every step
  /// left the project as the record says it was left.
  public var repeatedTheWork: Bool {
    skipped.isEmpty && differences.isEmpty
  }

  /// How many fields replay found that are not what the session recorded.
  public var differenceCount: Int {
    differences.reduce(0) { total, step in total + step.differences.count }
  }

  /// The report as the command prints it.
  ///
  /// The members are put in one at a time, as `step.json` is. A literal of every field at once
  /// asks the type checker for more than it will do.
  public var json: JSONValue {
    var members: [String: JSONValue] = [:]
    members["source"] = .string(source)
    members["session"] = .string(session)
    members["from"] = .string(from)
    members["to"] = .string(to)
    members["stepsRun"] = .number(Double(stepsRun))
    members["skipped"] = .array(skipped.map(\.json))
    members["differences"] = .array(differences.map(\.json))
    return .object(members)
  }
}

/// What one run of a recorded step answered.
public enum ReplayRun: Sendable {
  /// The step ran again, and this is the state of Logic after it.
  case ran(State)

  /// This build of logicctl has no command of that name, so nothing ran.
  case noSuchCommand
}

/// Runs the steps of one session again and says where the second run differs from the first.
///
/// A person replays a session to learn whether the work is repeatable. So a step that cannot be
/// repeated is reported and never passed over: a replay that said nothing about a change made by
/// hand would read as a clean run of a session it did not reproduce.
///
/// The thing that runs one step is given by the caller. This module holds no command of logicctl
/// and reaches no Logic, so the executable hands in the route to both.
public enum SessionReplay {
  /// What a replay can refuse.
  public enum Refusal: Error, Equatable {
    /// No session under the root carries that id.
    case noSuchSession(id: String)

    /// The session holds no step, so there is nothing to run again.
    case nothingToReplay(id: String)

    /// A commit of the session holds no state that can be read.
    case unreadableState(commit: String)
  }

  /// How replay runs one step of the source session again.
  public typealias Runner = (RecordedStep) throws -> ReplayRun

  /// The session of one id.
  ///
  /// The session is named by the whole id, as a relink is. A folder name carries the first eight
  /// characters, and two sessions can share those, so a short id would replay a session a person
  /// did not name.
  public static func source(
    withId id: String,
    underRoot root: URL = SessionRepository.defaultRoot,
    git: Git = Git(),
    lock: Lock = Lock()
  ) throws -> SessionRepository {
    guard let found = SessionIndex.sessions(underRoot: root).first(where: { $0.id == id }) else {
      throw Refusal.noSuchSession(id: id)
    }
    return SessionRepository(
      folder: SessionRepository.sessionFolder(of: found, underRoot: root),
      session: found,
      git: git,
      lock: lock)
  }

  /// The steps of one session, oldest first, which is the order the work happened in.
  public static func steps(of repository: SessionRepository) throws -> [RecordedStep] {
    try History.rows(of: repository).reversed().map { row in
      RecordedStep(
        seq: row.seq,
        commit: row.commit,
        kind: row.kind,
        command: row.command,
        argv: arguments(ofSequence: row.seq, in: repository))
    }
  }

  /// The state one commit of a session recorded.
  ///
  /// It comes from git and not from the record of the step, because a record holds the hash of the
  /// state and a difference carries the values on both sides.
  public static func recordedState(
    ofCommit commit: String, in repository: SessionRepository
  ) throws -> JSONValue {
    guard
      let printed = try? repository.git.run(
        ["show", commit + ":state.json"], in: repository.folder),
      let value = try? CanonicalJSON.value(of: printed)
    else {
      throw Refusal.unreadableState(commit: commit)
    }
    return value
  }

  /// Runs the steps again, writes one check for each step that ran, and answers what it found.
  ///
  /// The state of the replayed project is carried from step to step, so each check records where
  /// the project was before it and where it is after it, as every other step does.
  public static func compare(
    steps: [RecordedStep],
    of source: SessionRepository,
    into replayed: SessionRepository,
    startingFrom state: State,
    now: () -> Date = { Date() },
    through runner: Runner
  ) throws -> Outcome {
    guard let first = steps.first, let last = steps.last else {
      throw Refusal.nothingToReplay(id: source.session.id)
    }

    var ran = 0
    var skipped: [SkippedStep] = []
    var found: [StepDifferences] = []
    var lastStep: String?
    var held = state

    for step in steps {
      guard step.kind == Step.Kind.command else {
        skipped.append(SkippedStep(seq: step.seq, reason: SessionReplay.reason(of: step.kind)))
        continue
      }
      guard case .ran(let after) = try runner(step) else {
        skipped.append(SkippedStep(seq: step.seq, reason: SkipReason.noSuchCommand))
        continue
      }
      ran += 1
      let differences = StateDiff.between(held.json, after.json)
      if !differences.isEmpty {
        found.append(StepDifferences(seq: step.seq, differences: differences))
      }
      lastStep = try write(
        check: step, differences: differences, before: held, after: after, into: replayed,
        at: now())
      held = after
    }

    let report = ReplayReport(
      source: source.session.id,
      session: replayed.session.id,
      from: first.commit,
      to: last.commit,
      stepsRun: ran,
      skipped: skipped,
      differences: found)
    return Outcome(report: report, lastStep: lastStep)
  }

  /// What a replay answered: what it found, and the last step it wrote.
  public struct Outcome: Sendable {
    /// What replay found, as the command prints it.
    public var report: ReplayReport

    /// The commit of the last step replay wrote, or nothing when it ran no step.
    public var lastStep: String?

    public init(report: ReplayReport, lastStep: String?) {
      self.report = report
      self.lastStep = lastStep
    }
  }

  /// Writes the check of one step into the session replay records, and answers its commit.
  ///
  /// The check carries no picture of the window. The picture of a command belongs to the step of
  /// that command, and this step is the comparison and not the command.
  static func write(
    check step: RecordedStep,
    differences: [Difference],
    before: State,
    after: State,
    into replayed: SessionRepository,
    at moment: Date
  ) throws -> String {
    let record = Step(
      seq: replayed.nextSequence(),
      kind: .replayCheck,
      command: step.command,
      argv: step.argv,
      startedAt: moment,
      finishedAt: moment,
      exitCode: differences.isEmpty ? 0 : Int(ErrorCode.replayDifferences.exitCode),
      stateBefore: CanonicalJSON.sha256(of: before),
      stateAfter: CanonicalJSON.sha256(of: after),
      differences: differences)
    return try replayed.write(record, state: after)
  }

  /// Why a step of one kind cannot be run again.
  ///
  /// Only a command runs again. A change made by hand, a save of Logic and a check of an earlier
  /// replay are each a record of something that no command of logicctl did.
  static func reason(of kind: Step.Kind) -> SkipReason {
    switch kind {
    case .externalChange:
      return .cannotRepeatAChangeByHand
    case .save:
      return .cannotRepeatASave
    case .replayCheck:
      return .cannotRepeatACheck
    case .command:
      return .noSuchCommand
    }
  }

  /// The arguments the record of one step holds.
  static func arguments(ofSequence sequence: Int, in repository: SessionRepository) -> [String] {
    guard case .object(let members) = SaveLookup.record(ofSequence: sequence, in: repository),
      case .array(let written) = members["argv"] ?? JSONValue.null
    else {
      return []
    }
    return written.compactMap { (value: JSONValue) -> String? in
      guard case .string(let text) = value else {
        return nil
      }
      return text
    }
  }
}
