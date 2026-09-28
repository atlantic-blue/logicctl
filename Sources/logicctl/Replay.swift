import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// Runs the steps of one session again on a new project.
///
/// This is the command that says whether the work of a session is repeatable. It opens a new
/// project, runs each step of the session again, and compares the project after each step with the
/// state that step recorded. A step that cannot be run again is reported as skipped, so a replay
/// never reads as a clean run of a session it did not reproduce.
///
/// The work of the replay is a session of its own, and that session says which session it came
/// from. So a person reads both histories and compares them step by step.
struct Replay: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "replay",
    abstract: "Run the steps of one session again on a new project.",
    discussion: """
      The session is the id that `sessions` prints, in full. replay opens a new project and runs \
      every step of that session again. After each step it compares the project with the state \
      the step recorded, and every field that differs is a pointer into the state.

      A change that a person made in Logic cannot be run again, so replay reports it as a skipped \
      step. A replay that skipped a step, or found a difference, fails with replay_differences and \
      carries the whole report.

      A recorded save is not written to the path it was recorded with. replay saves into a folder \
      of its own under the temporary folder, under the file name of that path, so a replay never \
      writes over the project of a person.

      --from and --to are step numbers, counted from 1, as `show` counts them, and a step at \
      either end is inside the range. A range that starts after step 1 runs on a new project, \
      and logicctl gives no warning, so the project misses the work of every step before the \
      range.

      Example: logicctl replay 6f0a1b2c-3d4e-4f50-8a9b-0c1d2e3f4a5b --from 2 --to 3
      """)

  @Argument(help: "The id of the session to run again, in full, as `sessions` prints it.")
  var session: String

  @Option(help: "The first step to run again, counted from 1. The default is step 1.")
  var from: OneBasedIndex?

  @Option(help: "The last step to run again, counted from 1. The default is the last step.")
  var to: OneBasedIndex?

  @OptionGroup var output: OutputOption

  @OptionGroup var wait: TimeoutOption

  /// The limit of every wait this command makes, in milliseconds.
  var limitMs: Int {
    wait.timeout.milliseconds
  }

  func validate() throws {
    guard let first = from, let last = to, first.value > last.value else {
      return
    }
    throw ValidationError(
      Replay.sentence(of: Replay.Refusal.emptyRange(from: first.value, to: last.value)))
  }

  func run() throws {
    let status = Replay.answer(
      session: session,
      from: from?.value,
      to: to?.value,
      chooser: ProjectChooser.live(),
      driver: NewProject.liveDriver(),
      limitMs: limitMs,
      format: output.format)
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension Replay {
  /// Runs one session again, prints the envelope, and answers the number the process exits with.
  ///
  /// The chooser, the driver, the actions, the panel and the runner are given rather than reached
  /// for, so the pipeline drives the whole command against a Logic and a session of its own.
  /// `savesUnder` is the folder the saves of a replay go under, which is the temporary folder of
  /// this Mac and, in the pipeline, a folder of the test.
  static func answer(
    session id: String,
    from: Int? = nil,
    to: Int? = nil,
    chooser: ProjectChooser,
    driver: any LogicDriver,
    actions: TrackActions = TrackActions.live(),
    dialog: SaveDialog = SaveDialog.live(),
    savesUnder: URL = FileManager.default.temporaryDirectory,
    runner: SessionReplay.Runner? = nil,
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    limitMs: Int = Wait.defaultLimitMs,
    format: OutputFormat = .compact,
    now: () -> Date = { Date() },
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds,
    git: Git = Git(),
    lock: Lock = Lock(),
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    do {
      let source = try SessionReplay.source(withId: id, underRoot: root, git: git, lock: lock)
      let held = try SessionReplay.steps(of: source)
      let steps = try Replay.range(of: held, from: from, to: to, in: id)
      guard let first = steps.first, let last = steps.last else {
        throw SessionReplay.Refusal.nothingToReplay(id: id)
      }

      let made = try NewProject.projectWithTracks(
        through: chooser, and: driver, limitMs: limitMs, clock: clock, sleeper: sleeper)
      let fresh = Replay.session(
        of: made,
        at: try driver.projectPath(),
        replaying: source.session.id,
        firstCommit: first.commit,
        lastCommit: last.commit,
        version: version,
        startedAt: started)
      let repository = try SessionRepository.start(
        session: fresh, root: root, state: made, git: git, lock: lock)

      let runs =
        runner
        ?? Replay.liveRunner(
          readingThrough: driver,
          acting: actions,
          saving: dialog,
          into: Replay.saveFolder(ofSession: fresh.id, under: savesUnder),
          limitMs: limitMs,
          clock: clock,
          sleeper: sleeper)
      let outcome = try SessionReplay.compare(
        steps: steps,
        of: source,
        into: repository,
        startingFrom: made,
        now: now,
        through: runs)
      let meta = AnswerMeta.run(
        version: version, session: fresh.id, step: outcome.lastStep, externalChange: nil,
        from: started, to: now())
      guard outcome.report.repeatedTheWork else {
        return printer.write(
          Envelope.failure(Replay.differences(outcome.report), meta: meta))
      }
      return printer.write(Envelope.success(data: outcome.report.json, meta: meta))
    } catch {
      // The answer names no session and no step, because most of what stops a replay stops it
      // before there is a project to replay into. A recorded command this build cannot read stops
      // one that did start, and that session is on disk with the checks it wrote before the stop.
      return printer.write(
        Envelope.failure(
          Replay.failure(of: error),
          meta: AnswerMeta.run(
            version: version, session: nil, step: nil, externalChange: nil, from: started,
            to: now())))
    }
  }

  /// What a range a person named can be refused for.
  ///
  /// Both are the arguments and never Logic, so both are `invalid_argument`, and a replay that
  /// carries one of them opened no project and wrote no session.
  enum Refusal: Error, Equatable {
    /// The session holds no step of that number.
    case noSuchStep(step: Int, held: Int)

    /// The range ends before it starts, so it holds no step at all.
    case emptyRange(from: Int, to: Int)
  }

  /// The steps of one session that are inside the range a person named, oldest first.
  ///
  /// A step at either end is inside the range. A flag nobody typed is the end of the session it
  /// stands for, so `--from 2` alone runs to the last step and `--to 3` alone starts at the first.
  ///
  /// The refusals come before the project is opened. A replay costs a new project and the time of
  /// a session to run, and it leaves that project behind, so a range nobody can act on is worth
  /// refusing while the cost is one line of JSON.
  static func range(
    of steps: [RecordedStep], from: Int?, to: Int?, in session: String
  ) throws -> [RecordedStep] {
    guard let held = steps.last?.seq else {
      throw SessionReplay.Refusal.nothingToReplay(id: session)
    }
    let first = from ?? 1
    let last = to ?? held
    guard first <= last else {
      throw Refusal.emptyRange(from: first, to: last)
    }
    guard steps.contains(where: { $0.seq == first }) else {
      throw Refusal.noSuchStep(step: first, held: held)
    }
    guard steps.contains(where: { $0.seq == last }) else {
      throw Refusal.noSuchStep(step: last, held: held)
    }
    return steps.filter { $0.seq >= first && $0.seq <= last }
  }

  /// What a range that holds no step says, on one line.
  ///
  /// The command line and the answer say the same thing, because a person who typed the range gets
  /// the refusal from whichever one read it first.
  static func sentence(of refusal: Refusal) -> String {
    switch refusal {
    case .noSuchStep(let step, let held):
      return "The session has no step \(step). It holds \(held)."
    case .emptyRange(let first, let last):
      return "Step \(first) is after step \(last), so the range holds no step."
    }
  }

  /// The failure one refusal of a range stops the command with.
  static func failure(of refusal: Refusal) -> Failure {
    switch refusal {
    case .noSuchStep(let step, let held):
      return Failure(
        code: .invalidArgument,
        message: Replay.sentence(of: refusal),
        details: .object([
          "step": .number(Double(step)),
          "steps": .number(Double(held)),
        ]))
    case .emptyRange(let first, let last):
      return Failure(
        code: .invalidArgument,
        message: Replay.sentence(of: refusal),
        details: .object([
          "from": .number(Double(first)),
          "to": .number(Double(last)),
        ]))
    }
  }

  /// The session that replay records its own work in.
  ///
  /// `replayOf` carries the session it came from and the first and the last step commit that
  /// replay read. `createdByLogicctl` is true, because replay made this project, and a command of
  /// the replay may change it without `--confirm`.
  static func session(
    of state: State,
    at path: String?,
    replaying source: String,
    firstCommit: String,
    lastCommit: String,
    version: String,
    startedAt: Date
  ) -> Session {
    Session(
      createdAt: startedAt,
      project: Session.Project(name: state.project.name, path: path, createdByLogicctl: true),
      replayOf: Session.ReplayOf(session: source, from: firstCommit, to: lastCommit),
      versions: Session.Versions(
        logicctl: version, logic: state.logic.version, macos: Run.macosVersion()))
  }

  /// What this build of logicctl can run again, by the name the record carries.
  ///
  /// replay opens a new project itself, so a `new-project` step is repeated by that. Every other
  /// step is the command the record names, built again from the arguments the record carries and
  /// acted on the project the replay made. A record of a command this build does not have is
  /// skipped with `no_such_command` and the replay fails saying so. Each part of the tool that adds
  /// a command adds it here.
  ///
  /// The command acts, and it does not go through `Run`. A run writes a step into the session of
  /// the project it worked on, and a replay writes a check of its own for every step it ran, so a
  /// step there would record the work of the session twice.
  ///
  /// The project of a replay is made by logicctl, so no command of a replay is guarded and none of
  /// them needs `--confirm`.
  static func liveRunner(
    readingThrough driver: any LogicDriver,
    acting actions: TrackActions,
    saving dialog: SaveDialog,
    into folder: URL,
    limitMs: Int,
    clock: @escaping Wait.Clock,
    sleeper: @escaping Wait.Sleeper,
    files: FileManager = .default
  ) -> SessionReplay.Runner {
    { (step: RecordedStep) -> ReplayRun in
      guard step.command != "new-project" else {
        return ReplayRun.ran(try driver.readState())
      }
      guard
        let command = try Replay.work(
          of: step, acting: actions, saving: dialog, into: folder, limitMs: limitMs, clock: clock,
          sleeper: sleeper, files: files)
      else {
        return ReplayRun.noSuchCommand
      }
      _ = try command.act(through: driver)
      return ReplayRun.ran(try driver.readState())
    }
  }

  /// The command one recorded step runs again, or nothing when this build has no command of that
  /// name.
  ///
  /// The arguments are read by the parser of the subcommand itself, so a record is read the way the
  /// line a person typed is read, and one place says what each flag means. A record this build
  /// cannot read stops the replay with the reason, because `no_such_command` says that the name is
  /// unknown and the name is known here.
  static func work(
    of step: RecordedStep,
    acting actions: TrackActions,
    saving dialog: SaveDialog,
    into folder: URL,
    limitMs: Int,
    clock: @escaping Wait.Clock,
    sleeper: @escaping Wait.Sleeper,
    files: FileManager
  ) throws -> (any LogicCommand)? {
    guard let command = step.command else {
      return nil
    }
    switch command {
    case "tracks list":
      return TracksListCommand(argv: step.argv)
    case "tracks add":
      let typed = try Tracks.Add.parse(step.argv)
      return TracksAddCommand(
        argv: step.argv, type: typed.type, actions: actions, limitMs: limitMs, clock: clock,
        sleeper: sleeper)
    case "tracks rename":
      let typed = try Tracks.Rename.parse(step.argv)
      return TracksRenameCommand(
        argv: step.argv, index: typed.track.index.value, newName: typed.name, actions: actions,
        limitMs: limitMs, clock: clock, sleeper: sleeper)
    case "tracks mute":
      let typed = try Tracks.Mute.parse(step.argv)
      return TracksMuteCommand(
        argv: step.argv, index: typed.track.index.value, muted: try typed.muting.state(),
        actions: actions, limitMs: limitMs, clock: clock, sleeper: sleeper)
    case "tracks solo":
      let typed = try Tracks.Solo.parse(step.argv)
      return TracksSoloCommand(
        argv: step.argv, index: typed.track.index.value, soloed: try typed.soloing.state(),
        actions: actions, limitMs: limitMs, clock: clock, sleeper: sleeper)
    case "tracks delete":
      let typed = try Tracks.Delete.parse(step.argv)
      return TracksDeleteCommand(
        argv: step.argv, index: typed.track.index.value, actions: actions, limitMs: limitMs,
        clock: clock, sleeper: sleeper)
    case "save":
      let typed = try Save.parse(step.argv)
      let path = try Replay.savePath(ofRecorded: typed.path, into: folder, files: files)
      return SaveCommand(
        argv: step.argv, path: path, dialog: dialog, limitMs: limitMs, clock: clock,
        sleeper: sleeper)
    default:
      return nil
    }
  }

  /// The folder one replay saves into.
  ///
  /// The name of it carries the id of the session the replay records its own work in, so two
  /// replays never write to one path, and a person reads which replay left a file behind.
  static func saveFolder(ofSession id: String, under folder: URL) -> URL {
    folder.appendingPathComponent("logicctl-replay-" + id)
  }

  /// Where a recorded `save` writes in a replay: the folder of the replay, under the file name the
  /// record carries.
  ///
  /// The path of the record is where a person keeps their work, and a `.logicx` holds hours of it
  /// that nothing brings back, so a replay writes nowhere near it. The folder of the replay is made
  /// here, because a replay of a session that holds no save needs no folder at all.
  ///
  /// Anything already at that name goes first. macOS asks whether to replace a file that is in the
  /// way, logicctl presses no button in a dialog, and a session that saves the same name twice
  /// would reach that question on its second save. The folder belongs to this replay alone, so the
  /// file that goes is one this replay wrote a moment ago.
  static func savePath(
    ofRecorded recorded: String, into folder: URL, files: FileManager = .default
  ) throws -> String {
    let name = URL(fileURLWithPath: recorded).lastPathComponent
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent(name).path
    guard files.fileExists(atPath: path) else {
      return path
    }
    try files.removeItem(atPath: path)
    return path
  }

  /// The failure of a replay that did not repeat the work.
  ///
  /// The whole report goes in `details`, as the data model asks, so an agent reads the same object
  /// whether the replay worked or not.
  static func differences(_ report: ReplayReport) -> Failure {
    Failure(
      code: .replayDifferences,
      message: Replay.sentence(of: report),
      details: report.json)
  }

  /// What a replay that did not repeat the work says, on one line.
  ///
  /// It counts the steps it passed over and the fields it found, because those are the two things
  /// that make a replay something other than a repeat of the work.
  static func sentence(of report: ReplayReport) -> String {
    let steps = report.skipped.count == 1 ? "step" : "steps"
    let found = report.differenceCount
    return "Replay skipped \(report.skipped.count) \(steps) and found \(found) differences"
  }

  /// What the command stopped with.
  ///
  /// A replay that never reached its new project stops with the failure of that route, so a person
  /// reads what Logic refused. Everything else is a session that cannot be replayed.
  static func failure(of error: Error) -> Failure {
    if let range = error as? Replay.Refusal {
      return Replay.failure(of: range)
    }
    guard let refusal = error as? SessionReplay.Refusal else {
      return NewProject.failure(of: error)
    }
    switch refusal {
    case .noSuchSession(let id):
      return Failure(
        code: .invalidArgument,
        message: "No session has the id \(id).",
        details: .object(["session": .string(id)]))
    case .nothingToReplay(let id):
      return Failure(
        code: .invalidArgument,
        message: "That session holds no step, so there is nothing to run again.",
        details: .object(["session": .string(id)]))
    case .unreadableState(let commit):
      return Failure(
        code: .internalFailure,
        message: "The state that one step of the session recorded could not be read.",
        details: .object(["commit": .string(commit)]))
    }
  }
}
