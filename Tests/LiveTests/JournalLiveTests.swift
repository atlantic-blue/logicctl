import Foundation
import LogicctlCore
import Testing

/// The root of the repository, found from this file.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

/// This file, which the acceptance scenario reads to see what the phase carries.
private let phaseFile = URL(fileURLWithPath: #filePath)

/// What the acceptance of part 7 does on this Mac, and what it asks the operator for.
enum JournalLive {
  /// The variable that names the session of phase 2 that the replay check runs again.
  ///
  /// The acceptance of phase 2 keeps its own session and prints its id. A replay needs a session
  /// that logicctl recorded against the real Logic, and this phase records no such session of its
  /// own, so the operator hands the id to this run in the variable.
  static let replaySessionVariable = "LOGICCTL_REPLAY_SESSION"

  /// The scenarios of this phase, one for each thing the step proves against Logic.
  static let checks = [
    "aMuteByHandBecomesAnExternalChangeStep",
    "replayOfThePhaseTwoSessionFindsNoDifference",
    "aSaveInLogicWritesASaveStepWithNoCommand",
  ]

  /// How long a scenario waits for the operator to make one change in Logic, in milliseconds.
  static let byHandLimitMs = 300_000

  /// How long a scenario leaves between two reads of the journal, in milliseconds.
  static let pollMs = 2000

  /// What the phase refuses to do, and what the operator does about it.
  enum Refusal: Error, CustomStringConvertible {
    /// Nothing named the session of phase 2, so the replay check has no session to run again.
    case theReplaySessionIsNotNamed(String)

    /// The journal never carried the change the operator was asked for.
    case theJournalNeverShowedTheChange(change: String, waitedMs: Int)

    /// The launch agent of the watcher is still on this Mac after the run.
    case theWatcherWouldNotUnload(String)

    var description: String {
      switch self {
      case .theReplaySessionIsNotNamed(let variable):
        return """
          set \(variable) to the session the acceptance of phase 2 kept, and run this again
          """
      case .theJournalNeverShowedTheChange(let change, let waitedMs):
        return """
          the journal did not carry \(change) within \(waitedMs)ms. Make the change in Logic \
          while the scenario waits, and run this again
          """
      case .theWatcherWouldNotUnload(let reason):
        return "the watcher is still on this Mac after the run: \(reason)"
      }
    }
  }

  /// One row of `log`.
  struct Row: Decodable {
    /// The number of the step, from 1.
    let step: Int

    /// The commit that holds it.
    let commit: String

    /// What wrote it: a command, a change by hand, a save, or a check of a replay.
    let kind: String

    /// The subcommand that wrote it, and nothing for a step no command wrote.
    let command: String?

    /// The number the step exited with.
    let exitCode: Int
  }

  /// What `log` answers.
  struct Journal: Decodable {
    /// The session the rows came from.
    let session: String?

    /// The steps, newest first.
    let steps: [Row]
  }

  /// What `show` answers of one step.
  struct Recorded: Decodable {
    /// The number of the step, from 1.
    let seq: Int

    /// What wrote it.
    let kind: String

    /// The subcommand that wrote it, and nothing for a step no command wrote.
    let command: String?

    /// The hash of the project before the step.
    let stateBefore: String?

    /// The hash of the project after it.
    let stateAfter: String?
  }

  /// One row of `tracks list`.
  struct TrackRow: Decodable {
    /// The number of the track, from 1, from the top of the window.
    let index: Int

    /// The name Logic shows.
    let name: String

    /// Whether the track is muted.
    let mute: Bool
  }

  /// What `tracks list` answers.
  struct Tracks: Decodable {
    /// One row per track, from the top.
    let tracks: [TrackRow]
  }

  /// What `replay` answers.
  struct Report: Decodable {
    /// The session that was replayed.
    let source: String

    /// The session replay recorded its own work in.
    let session: String

    /// How many steps ran again.
    let stepsRun: Int

    /// The steps replay passed over.
    let skipped: [Skipped]

    /// What replay found, one item for each step that differed.
    let differences: [Differed]
  }

  /// One step replay passed over.
  struct Skipped: Decodable {
    /// The number of the step in the session that was replayed.
    let seq: Int

    /// Why it was passed over.
    let reason: String
  }

  /// One step whose project was not what the session recorded.
  struct Differed: Decodable {
    /// The number of the step in the session that was replayed.
    let seq: Int
  }

  /// What `watch start` and `watch stop` answer.
  struct Watcher: Decodable {
    /// Whether the watcher runs.
    let running: Bool
  }

  /// What `watch status` answers.
  struct WatcherStatus: Decodable {
    /// Whether the watcher runs.
    let running: Bool

    /// The project of every session it watches.
    let projects: [String]
  }

  /// The session of phase 2 this run replays.
  static func replaySession(
    in environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> String {
    let named = environment[replaySessionVariable] ?? ""
    guard !named.isEmpty else {
      throw Refusal.theReplaySessionIsNotNamed(replaySessionVariable)
    }
    return named
  }

  /// The line a scenario prints to ask the operator for one change in Logic.
  static func byHandLine(for change: String) -> String {
    "by hand: \(change)"
  }

  /// Asks the operator for one change in Logic.
  ///
  /// The suite presses nothing (`RUN-7`), and the two changes this phase reads are a mute by mouse
  /// and a knob, so a person makes them while the scenario waits.
  static func byHand(_ change: String) {
    print(byHandLine(for: change))
  }

  /// A copy of a project for this run, in a folder the run owns.
  static func copyForTheRun(into folder: URL, from project: URL? = nil) throws -> URL {
    let source: URL
    if let project {
      source = project
    } else {
      source = try LiveHarness.scratchProject()
    }
    return try LiveHarness.copy(source, into: folder)
  }

  /// Everything `log` answers now.
  ///
  /// `log` reads the journal and never Logic, so a scenario reads the history as often as it likes
  /// and the history it is reading gains no step from the reading.
  static func journal() throws -> Journal {
    try LiveHarness.read(Journal.self, from: ["log"])
  }

  /// Reads the journal until it carries what the operator changed by hand.
  static func waitForTheJournal<Found>(
    naming change: String,
    limitMs: Int = JournalLive.byHandLimitMs,
    pollMs: Int = JournalLive.pollMs,
    reads: () throws -> Found?
  ) throws -> Found {
    var found: Found?
    do {
      try Wait.until(limitMs: limitMs, pollMs: pollMs) {
        found = try reads()
        return found != nil
      }
    } catch let ranOut as Wait.RanOut {
      throw Refusal.theJournalNeverShowedTheChange(change: change, waitedMs: ranOut.waitedMs)
    }
    guard let found else {
      throw Refusal.theJournalNeverShowedTheChange(change: change, waitedMs: limitMs)
    }
    return found
  }

  /// Takes the launch agent of the watcher off this Mac, and answers what stopped it.
  ///
  /// A run of this phase loads a launch agent, which outlives the run and a restart of this Mac.
  /// So every scenario that starts the watcher stops it again, whichever way the scenario went.
  static func unloadTheWatcher() -> Error? {
    do {
      let stopped = try LiveHarness.read(Watcher.self, from: ["watch", "stop"])
      guard stopped.running == false else {
        return Refusal.theWatcherWouldNotUnload("watch stop answered a watcher that runs")
      }
      return nil
    } catch {
      return error
    }
  }
}

/// Part 7 of the path, the journal, against the Logic that runs on this Mac.
///
/// The pipeline proves the journal against a real `git` in a temporary folder and against the fake
/// driver. It says nothing about whether a change a person makes in Logic reaches the journal, and
/// that is what these three scenarios answer: a mute by hand arrives as an external change step
/// before the next command runs, a session of phase 2 repeats with no difference, and a save in
/// Logic arrives as a save step that no command wrote.
///
/// They run one at a time, because all three drive the one Logic this Mac has.
@Suite(.serialized, .enabled(if: LiveHarness.runsLive()))
struct Phase7LiveScenarios {
  /// A mute the operator makes in Logic is a step of the journal before the next command runs
  /// (story J2, `CMD-J1`).
  ///
  /// The mute is made by mouse, by a person, because the suite posts no event of its own. The
  /// scenario then reads `tracks list` until the mute is there. The command that first reads it is
  /// the command that writes the external change step, so the journal carries the change with the
  /// command after it, and `log` and `show` both read it back.
  @Test func aMuteByHandBecomesAnExternalChangeStep() throws {
    LiveHarness.liveScenario("aMuteByHandBecomesAnExternalChangeStep")

    let folder = try LiveHarness.temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let copy = try JournalLive.copyForTheRun(into: folder)
    let name = copy.deletingPathExtension().lastPathComponent
    try LiveHarness.openInLogic(copy)

    let read = try LiveHarness.read(JournalLive.Tracks.self, from: ["tracks", "list"])
    let track = try #require(
      read.tracks.first, "the copy carries a track for the operator to mute")
    #expect(
      track.mute == false,
      """
      track \(track.index) of \(name) starts unmuted, so the mute the operator makes next is the \
      change this scenario reads
      """)

    JournalLive.byHand("mute track \(track.index) of \(name) in the Tracks window of Logic")

    _ = try JournalLive.waitForTheJournal(naming: "the mute of track \(track.index)") {
      let now = try LiveHarness.read(JournalLive.Tracks.self, from: ["tracks", "list"])
      return now.tracks.first { $0.index == track.index && $0.mute }
    }

    let steps = try JournalLive.journal().steps
    #expect(
      steps.map(\.step) == steps.map(\.step).sorted(by: >),
      "log answers the steps of the session newest first")

    let found = try #require(
      steps.firstIndex { $0.kind == "external_change" },
      "the mute nobody typed is a step of the journal of its own")
    let external = steps[found]
    #expect(external.command == nil, "no command made that change, so the step names none")
    #expect(
      found > 0,
      """
      the command that read the mute wrote that step, so the journal carries it after the change
      """)
    if found > 0 {
      #expect(
        steps[found - 1].command == "tracks list",
        "and that command is the tracks list which read the mute")
    }

    let shown = try LiveHarness.read(
      JournalLive.Recorded.self, from: ["show", String(external.step)])
    #expect(shown.kind == "external_change", "show reads the same step back")
    #expect(shown.command == nil, "and it names no command either")
    #expect(
      shown.stateBefore != shown.stateAfter,
      "and the two hashes differ, because the project moved while nothing of logicctl ran")
  }

  /// A session of phase 2 runs again on a new project and reports no difference (story J3,
  /// `CMD-J3`).
  ///
  /// The acceptance of phase 2 keeps its session and prints its id, and the operator hands that id
  /// to this run. A replay that repeats the whole work reports nothing and exits 0, which is the
  /// evidence story J3 asks for.
  @Test func replayOfThePhaseTwoSessionFindsNoDifference() throws {
    LiveHarness.liveScenario("replayOfThePhaseTwoSessionFindsNoDifference")

    let session = try JournalLive.replaySession()

    let folder = try LiveHarness.temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let copy = try JournalLive.copyForTheRun(into: folder)
    try LiveHarness.openInLogic(copy)

    let answer = try LiveHarness.logicctl(["replay", session])
    let carried = try LiveHarness.envelope(
      JournalLive.Report.self, of: answer, from: "replay \(session)")
    let report = try #require(
      carried.data, "the session of phase 2 runs again on a new project: \(answer.printed)")

    #expect(answer.status == 0, "a replay that repeated the whole session exits 0")
    #expect(report.source == session, "the report names the session it ran again")
    #expect(report.stepsRun > 0, "and it ran the steps that session holds")
    #expect(
      report.skipped.isEmpty,
      "nothing was passed over: \(report.skipped.map(\.seq))")
    #expect(
      report.differences.isEmpty,
      """
      and every step left the project as the session recorded it: \
      \(report.differences.map(\.seq))
      """)
  }

  /// A save the operator makes in Logic is a step the watcher wrote, with no command (story J5,
  /// `CMD-J5`).
  ///
  /// The scenario reads `log` while it waits, and `log` reads the journal and never Logic, so the
  /// waiting writes no step of its own. A save step that arrives while nothing else ran is a step
  /// the watcher wrote.
  @Test func aSaveInLogicWritesASaveStepWithNoCommand() throws {
    LiveHarness.liveScenario("aSaveInLogicWritesASaveStepWithNoCommand")

    let folder = try LiveHarness.temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let copy = try JournalLive.copyForTheRun(into: folder)
    let name = copy.deletingPathExtension().lastPathComponent
    try LiveHarness.openInLogic(copy)

    // The watcher watches the project of a session, so the copy needs a session before it starts.
    _ = try LiveHarness.read(JournalLive.Tracks.self, from: ["tracks", "list"])

    let started = try LiveHarness.read(JournalLive.Watcher.self, from: ["watch", "start"])
    defer {
      let left = JournalLive.unloadTheWatcher()
      #expect(
        left == nil,
        "the launch agent comes off this Mac at the end of the run: \(words(of: left))")
    }
    #expect(started.running, "the watcher runs while this scenario waits for a save")

    let status = try LiveHarness.read(JournalLive.WatcherStatus.self, from: ["watch", "status"])
    #expect(status.running, "watch status reads the agent this run loaded")
    #expect(
      status.projects.contains { $0.hasSuffix(copy.lastPathComponent) },
      "and it names the copy among the projects it watches: \(status.projects)")

    let newest = try JournalLive.journal().steps.first?.step ?? 0

    JournalLive.byHand("move the Channel EQ gain on track 1 of \(name), then save the project")

    let saved = try JournalLive.waitForTheJournal(naming: "the save of \(name)") {
      let now = try JournalLive.journal()
      return now.steps.first { $0.step > newest && $0.kind == "save" }
    }

    #expect(saved.command == nil, "the watcher wrote the step, and no command of logicctl ran")
    #expect(saved.exitCode == 0, "and the step reads as a save that worked")

    let shown = try LiveHarness.read(JournalLive.Recorded.self, from: ["show", String(saved.step)])
    #expect(shown.kind == "save", "show reads the same step back")
    #expect(shown.stateAfter != nil, "and it carries the state of the project Logic saved")
  }
}

/// The acceptance of part 7 cannot report a pass unless it drove the real Logic.
///
/// `make accept PART=7` is what proves this step, and it runs on this Mac and nowhere else. The
/// pipeline has no Logic, so this is the scenario the pipeline runs, and it holds the acceptance to
/// the four things that make its result worth reading. Each thing the step proves is a live
/// scenario of its own, and each one says its name as it starts, because the target counts those
/// lines and a phase whose scenarios were all left out would otherwise read as a phase that
/// passed. The phase is off unless a person turns it on. It works on a copy in a folder of the run
/// and never on the work of a person. And the target accepts phase 7 at all, because a phase it
/// refuses is a phase nobody can accept.
@Test func journalAgainstLogic() throws {
  let source = try String(contentsOf: phaseFile, encoding: .utf8)

  #expect(
    JournalLive.checks.count == 3,
    "the step proves three things: the external change step, the clean replay and the save step")
  #expect(
    Set(JournalLive.checks).count == JournalLive.checks.count,
    "and each one is a scenario of its own: \(JournalLive.checks)")

  for check in JournalLive.checks {
    #expect(
      source.contains("@Test func \(check)()"),
      "\(check) is a scenario of this phase, so a run of the phase runs it")
    #expect(
      source.contains("LiveHarness.liveScenario(\"\(check)\")"),
      "\(check) says its name as it starts, which is the line the target counts")
  }

  // The declaration is read as two lines joined here, and never as one text this file carries,
  // because an assertion that looks for a string its own line holds passes on any file at all.
  let declaration = [
    "@Suite(.serialized, .enabled(if: LiveHarness.runsLive()))",
    "struct Phase7LiveScenarios {",
  ].joined(separator: "\n")
  #expect(
    source.contains(declaration),
    "the phase is off unless a person turns it on, so the pipeline drives nothing")
  #expect(LiveHarness.runsLive([:]) == false, "and a run that names nothing is not a live run")

  let folder = try LiveHarness.temporaryFolder()
  defer { try? FileManager.default.removeItem(at: folder) }

  let project = folder.appending(path: "Scratch.logicx")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  let into = folder.appending(path: "run")
  let copy = try JournalLive.copyForTheRun(into: into, from: project)
  #expect(
    LiveHarness.isUnder(FileManager.default.temporaryDirectory, copy),
    "the phase works on a copy in a folder of the run: \(copy.path)")
  #expect(copy.path != project.path, "and never on the project it copied from")

  let work = LiveHarness.musicFolder.appending(path: "Logic/Sketch.logicx")
  let refused = whatStopped { _ = try JournalLive.copyForTheRun(into: into, from: work) }
  #expect(
    refusedTheMusicFolder(refused),
    "and never on the work of a person under the music folder: \(words(of: refused))")

  let unnamed = whatStopped { _ = try JournalLive.replaySession(in: [:]) }
  #expect(
    words(of: unnamed).contains(JournalLive.replaySessionVariable),
    """
    the replay check runs the session of phase 2, and a run that names none says which \
    variable to set: \(words(of: unnamed))
    """)

  #expect(
    JournalLive.byHandLine(for: "mute track 2 in the Tracks window")
      == "by hand: mute track 2 in the Tracks window",
    "the suite presses nothing, so it asks the operator for the change and names it")

  let target = try String(contentsOf: repositoryRoot.appending(path: "Makefile"), encoding: .utf8)
  let text = target.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  #expect(
    text.contains("0|1|2|3|4|7)"),
    "make accept PART=7 is what proves this step, so the target accepts the phase")
}

/// What stopped one call, or nothing when it went through.
private func whatStopped(_ call: () throws -> Void) -> Error? {
  do {
    try call()
    return nil
  } catch {
    return error
  }
}

/// Whether the harness refused this project for being the work of a person.
///
/// The reason is read and not only the fact that something was refused, because a call that fell
/// over for another reason, a project that is not there for one, would otherwise read here as a
/// phase that guarded the music folder.
private func refusedTheMusicFolder(_ error: Error?) -> Bool {
  switch error as? LiveHarness.Refusal {
  case .theProjectIsUnderTheMusicFolder, .theCopyWouldBeUnderTheMusicFolder:
    return true
  default:
    return false
  }
}

/// What stopped a call, in words a failure can print.
private func words(of error: Error?) -> String {
  guard let error else {
    return "nothing stopped it"
  }
  return String(describing: error)
}
