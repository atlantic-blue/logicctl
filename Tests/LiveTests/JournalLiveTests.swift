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
  static let checks: [String] = []

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
    environment[replaySessionVariable] ?? ""
  }

  /// The line a scenario prints to ask the operator for one change in Logic.
  static func byHandLine(for change: String) -> String {
    change
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
    let copy = folder.appending(path: source.lastPathComponent)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: copy)
    return copy
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

  #expect(
    source.contains(".enabled(if: LiveHarness.runsLive())"),
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
    "the replay check runs the session of phase 2, and a run that names none says which variable "
      + "to set: \(words(of: unnamed))")

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
