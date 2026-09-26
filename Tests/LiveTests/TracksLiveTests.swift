import Foundation
import Testing

/// One command of phase 2, and the live scenario that drives it against Logic.
struct Phase2Command: Sendable, Equatable {
  /// The name of the live scenario that drives this command on this Mac.
  let liveScenario: String

  /// The command as a person types it.
  let typed: String
}

/// The commands of phase 2, in the order a person drives them.
///
/// The live scenarios read this, and so does the scenario the pipeline runs, so the phase has one
/// order and both read the same one.
enum Phase2Flow {
  /// The kind of track a person writes MIDI on, added to a project with nothing in it.
  static let addsASoftwareInstrumentTrack = Phase2Command(
    liveScenario: "addsASoftwareInstrumentTrackToANewProject",
    typed: "tracks add --type software-instrument")

  /// The other kind of track, which records sound.
  static let addsAnAudioTrack = Phase2Command(
    liveScenario: "addsAnAudioTrackToANewProject",
    typed: "tracks add --type audio")

  /// The name of a track, which is how a person tells two of them apart.
  static let renamesTheFirstTrack = Phase2Command(
    liveScenario: "renamesTheFirstTrack",
    typed: "tracks rename --index 1 --name \(Phase2Live.renamedTo)")

  /// Muting a track, with the flag that sets the state rather than turning it around.
  static let mutesTheFirstTrack = Phase2Command(
    liveScenario: "mutesTheFirstTrack",
    typed: "tracks mute --index 1 --on")

  /// Unmuting the same track, so a replay reaches the same state from any start.
  static let unmutesTheFirstTrack = Phase2Command(
    liveScenario: "unmutesTheFirstTrack",
    typed: "tracks mute --index 1 --off")

  /// Soloing a track.
  static let solosTheFirstTrack = Phase2Command(
    liveScenario: "solosTheFirstTrack",
    typed: "tracks solo --index 1 --on")

  /// Deleting a track, which answers the list that is left.
  static let deletesTheSecondTrack = Phase2Command(
    liveScenario: "deletesTheSecondTrack",
    typed: "tracks delete --index 2")

  /// Reading the tracks of the project, which is how an agent sees what it built.
  static let listsTheTracks = Phase2Command(
    liveScenario: "listsTheTracksOfTheProject",
    typed: "tracks list")

  /// Every command of phase 2, in order.
  static let inOrder: [Phase2Command] = [
    addsASoftwareInstrumentTrack,
    addsAnAudioTrack,
    renamesTheFirstTrack,
    mutesTheFirstTrack,
    unmutesTheFirstTrack,
    solosTheFirstTrack,
    deletesTheSecondTrack,
    listsTheTracks,
  ]
}

/// The project one live scenario made, and the session that records the work on it.
struct Phase2Project {
  /// The folder of this scenario, under the temporary folder of this Mac.
  let folder: URL

  /// Where the project is saved.
  let path: URL

  /// The session that holds one step for every command the scenario ran.
  let session: String
}

/// What a live scenario of phase 2 does, and what it never does to the work of a person.
enum Phase2Live {
  /// The name of the project each live scenario makes.
  static let projectName = "Phase2.logicx"

  /// The name a scenario gives a track it renames.
  static let renamedTo = "Bass"

  /// The folder where a person keeps their projects of Logic.
  static var logicFolder: URL {
    LiveHarness.musicFolder.appending(path: "Logic")
  }

  /// Whether this run drives the real Logic.
  ///
  /// The suite reads this and nothing else, so the variable the pipeline reads here is the variable
  /// that turns the phase on.
  static func runsOnThisMac(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    LiveHarness.runsLive(environment)
  }

  /// Says on the output of the run that one live scenario is about to drive Logic.
  ///
  /// `make accept` counts these lines, and only a scenario that ran can print one, so a phase that
  /// drove nothing counts as nothing.
  static func announce(
    _ command: Phase2Command,
    through say: (String) -> Void = LiveHarness.liveScenario
  ) {
    say(command.liveScenario)
  }

  /// Where a live scenario saves the project it made.
  ///
  /// It refuses the music folder before anything opens or saves there. A run pointed at the work of
  /// a person damages what no undo brings back, and Logic saves where it is told.
  static func saveTarget(
    in folder: URL,
    musicFolder: URL = LiveHarness.musicFolder
  ) throws -> URL {
    let target = LiveHarness.resolved(folder).appending(path: projectName)
    guard !LiveHarness.isUnder(musicFolder, target) else {
      throw LiveHarness.Refusal.theCopyWouldBeUnderTheMusicFolder(target.path)
    }
    return target
  }

  /// The names directly under the folder of Logic projects, and nothing deeper.
  ///
  /// The run writes nothing there. It reads the names so it can say what arrived while Logic ran. A
  /// folder that is not there answers nothing, which is what a Mac with no project of its own has.
  static func namesUnderTheLogicFolder(
    _ folder: URL = Phase2Live.logicFolder,
    fileManager: FileManager = .default
  ) -> [String] {
    let found = try? fileManager.contentsOfDirectory(atPath: folder.path)
    return (found ?? []).sorted()
  }

  /// The lines that name what arrived under the folder of Logic projects while the run drove Logic.
  ///
  /// Logic decides where it puts a project of its own, and a person reads these lines to see what
  /// it did. The run reports and it never removes.
  static func newEntryLines(before: [String], after: [String]) -> [String] {
    let known = Set(before)
    return after.filter { !known.contains($0) }.sorted().map { "music folder: new entry \($0)" }
  }

  /// The line that names the session the run leaves behind.
  ///
  /// The session stays on this Mac after the run, because the journal part replays it. This line is
  /// how a person finds it.
  static func sessionLine(_ session: String) -> String {
    "live session: \(session)"
  }

  /// The line that says what `meta` said about the picture of the window of Logic.
  ///
  /// A picture is evidence and not a gate. A Mac that granted no Screen Recording takes none, and
  /// that changes nothing about what the command did to the project, so the phase prints what the
  /// answer said and carries on.
  static func screenshotLine(_ said: String?) -> String? {
    guard let said, !said.isEmpty else {
      return nil
    }
    return "live screenshot: \(said)"
  }

  /// What `meta` said about the picture, out of one envelope, or nothing when it said nothing.
  static func screenshotSaid(in printed: String) -> String? {
    guard let bytes = printed.data(using: .utf8) else {
      return nil
    }
    let read = try? JSONDecoder().decode(PictureNote.self, from: bytes)
    return read?.meta?.details?.screenshot
  }

  /// One row of the tracks, as an answer of logicctl carries it.
  struct Row: Decodable, Sendable {
    let index: Int
    let name: String
    let type: String
    let mute: Bool
    let solo: Bool
    let arm: Bool
  }

  /// One row in words, for a person reading the output of the run.
  ///
  /// `arm` is printed and never asserted. Logic decides whether a new track is armed to record, and
  /// phase 2 fixes no value for it.
  static func describe(_ row: Row) -> String {
    let states = "mute \(row.mute) solo \(row.solo) arm \(row.arm)"
    return "live track: \(row.index) name \(row.name) type \(row.type) \(states)"
  }

  /// Runs one command of logicctl, says what it said about the picture, and reads its answer.
  static func ran<Answered: Decodable>(
    _ shape: Answered.Type,
    _ arguments: [String]
  ) throws -> Answered {
    let answer = try LiveHarness.logicctl(arguments)
    let command = arguments.joined(separator: " ")
    if let line = screenshotLine(screenshotSaid(in: answer.printed)) {
      print(line)
    }
    let read = try LiveHarness.envelope(shape, of: answer, from: command)
    guard let data = read.data else {
      throw LiveHarness.Refusal.logicctlRefused(
        command: command,
        code: read.error?.code ?? "no code",
        message: read.error?.message ?? answer.complained)
    }
    return data
  }

  /// Makes the project of one live scenario, and saves it in a folder of the run.
  ///
  /// `new-project` starts the session with `createdByLogicctl` true, so no command of the phase
  /// needs `--confirm`. The save gives the project a path under the temporary folder, and it stays
  /// there after the run, because the session names that path.
  static func newProject(in folder: URL) throws -> Phase2Project {
    let target = try saveTarget(in: folder)
    let made = try ran(NewProjectAnswer.self, ["new-project"])
    print(sessionLine(made.session))
    let saved = try ran(SaveAnswer.self, ["save", "--path", target.path])
    print("live project: \(saved.project.path)")
    return Phase2Project(folder: folder, path: target, session: made.session)
  }

  /// Drives one command of phase 2 against the real Logic, in a project of its own.
  ///
  /// Each scenario makes its own project. The order two scenarios run in is not a contract, so a
  /// scenario that read the tracks another one added would pass for the wrong reason.
  static func drive(
    _ command: Phase2Command,
    work: (Phase2Project) throws -> Void
  ) throws {
    announce(command)
    let before = namesUnderTheLogicFolder()
    defer {
      for line in newEntryLines(before: before, after: namesUnderTheLogicFolder()) {
        print(line)
      }
    }

    let folder = try LiveHarness.temporaryFolder()
    let project = try newProject(in: folder)
    try work(project)
  }
}

/// Phase 2 of the stories, against the Logic that runs on this Mac.
///
/// The pipeline proves the six commands against a tree that `inspect` recorded from Logic 12.3.1. A
/// recorded tree says the locator finds the element. It does not say the press reaches Logic and
/// changes the track. These scenarios are where that is answered.
///
/// They run one at a time, because each one drives the one Logic this Mac has.
@Suite(.serialized, .enabled(if: Phase2Live.runsOnThisMac()))
struct Phase2LiveScenarios {
  /// The operator adds a software instrument track to a project with nothing in it (story S2.2).
  @Test func addsASoftwareInstrumentTrackToANewProject() throws {
    try Phase2Live.drive(Phase2Flow.addsASoftwareInstrumentTrack) { _ in
      let added = try Phase2Live.ran(
        TrackAnswer.self, ["tracks", "add", "--type", "software-instrument"])
      print(Phase2Live.describe(added.track))

      #expect(added.track.index == 1, "the first track of an empty project is track 1")
      #expect(
        added.track.type == "software-instrument",
        "and Logic made the kind of track that was asked for: \(added.track.type)")
    }
  }

  /// The operator adds an audio track (story S2.2).
  @Test func addsAnAudioTrackToANewProject() throws {
    try Phase2Live.drive(Phase2Flow.addsAnAudioTrack) { _ in
      let added = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "audio"])
      print(Phase2Live.describe(added.track))

      #expect(added.track.index == 1, "the first track of an empty project is track 1")
      #expect(added.track.type == "audio", "and Logic made an audio track: \(added.track.type)")
    }
  }

  /// The operator gives a track a name, and reads the name Logic shows (story S2.3).
  @Test func renamesTheFirstTrack() throws {
    try Phase2Live.drive(Phase2Flow.renamesTheFirstTrack) { _ in
      _ = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "software-instrument"])
      let renamed = try Phase2Live.ran(
        TrackAnswer.self, ["tracks", "rename", "--index", "1", "--name", Phase2Live.renamedTo])
      print(Phase2Live.describe(renamed.track))

      #expect(renamed.track.index == 1, "the row that comes back is the track that was named")
      #expect(
        renamed.track.name == Phase2Live.renamedTo,
        "and it carries the name Logic shows after the change: \(renamed.track.name)")
    }
  }

  /// The operator mutes a track (story S2.3).
  @Test func mutesTheFirstTrack() throws {
    try Phase2Live.drive(Phase2Flow.mutesTheFirstTrack) { _ in
      _ = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "software-instrument"])
      let muted = try Phase2Live.ran(TrackAnswer.self, ["tracks", "mute", "--index", "1", "--on"])
      print(Phase2Live.describe(muted.track))

      #expect(muted.track.mute, "the track Logic shows after the change is muted")
    }
  }

  /// The operator unmutes the same track, and the flag sets the state (story S2.3).
  ///
  /// The mute is the start this scenario needs, so the scenario sets it itself rather than reading
  /// what another scenario left behind.
  @Test func unmutesTheFirstTrack() throws {
    try Phase2Live.drive(Phase2Flow.unmutesTheFirstTrack) { _ in
      _ = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "software-instrument"])
      let muted = try Phase2Live.ran(TrackAnswer.self, ["tracks", "mute", "--index", "1", "--on"])
      #expect(muted.track.mute, "this scenario starts from a track that is muted")

      let cleared = try Phase2Live.ran(
        TrackAnswer.self, ["tracks", "mute", "--index", "1", "--off"])
      print(Phase2Live.describe(cleared.track))

      #expect(cleared.track.mute == false, "and the track Logic shows after --off is not muted")
    }
  }

  /// The operator solos a track (story S2.3).
  @Test func solosTheFirstTrack() throws {
    try Phase2Live.drive(Phase2Flow.solosTheFirstTrack) { _ in
      _ = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "software-instrument"])
      let soloed = try Phase2Live.ran(TrackAnswer.self, ["tracks", "solo", "--index", "1", "--on"])
      print(Phase2Live.describe(soloed.track))

      #expect(soloed.track.solo, "the track Logic shows after the change is soloed")
    }
  }

  /// The operator deletes a track, and reads the list that is left (story S2.4).
  @Test func deletesTheSecondTrack() throws {
    try Phase2Live.drive(Phase2Flow.deletesTheSecondTrack) { _ in
      _ = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "software-instrument"])
      _ = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "audio"])
      let left = try Phase2Live.ran(TracksAnswer.self, ["tracks", "delete", "--index", "2"])
      for row in left.tracks {
        print(Phase2Live.describe(row))
      }

      #expect(left.tracks.count == 1, "two tracks less one is one: \(left.tracks.count)")
      #expect(left.tracks.first?.index == 1, "and the list that comes back starts at track 1")
    }
  }

  /// The operator reads the tracks of the project (story S2.1).
  @Test func listsTheTracksOfTheProject() throws {
    try Phase2Live.drive(Phase2Flow.listsTheTracks) { _ in
      let empty = try Phase2Live.ran(TracksAnswer.self, ["tracks", "list"])
      #expect(empty.tracks.isEmpty, "a project with nothing in it lists nothing, and exits 0")

      _ = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "software-instrument"])
      let listed = try Phase2Live.ran(TracksAnswer.self, ["tracks", "list"])
      for row in listed.tracks {
        print(Phase2Live.describe(row))
      }

      #expect(listed.tracks.count == 1, "one track added is one row: \(listed.tracks.count)")
      #expect(
        listed.tracks.first?.name.isEmpty == false,
        "and the row carries the name Logic shows")
    }
  }
}

/// Phase 2 of the stories is accepted on this Mac, and it leaves a session the journal replays.
///
/// `make accept PART=2` is the run that answers whether logicctl builds the track layout of a
/// project in the real Logic Pro 12.3.1. The pipeline cannot answer that: it has no Logic, no
/// project and no grant. So this scenario holds the part of the answer a machine with no Logic can
/// hold, and it holds it where the pipeline reads it on every pull request.
///
/// A phase made of live scenarios alone could not do this. The runner counts a scenario it left out
/// as a test that ran, so a live only scenario reads as a pass on every machine with no Logic.
/// A phase that drove nothing at all would then close the step.
///
/// So this scenario asserts the acceptance of phase 2. The phase drives every command of phase 2,
/// in the order a person drives them. Each command answers for itself on the output, so the count
/// of those lines says how many of them ran. The phase drives Logic nowhere by accident. It works
/// on a project in a folder of the run, and it refuses the folder a person keeps their own work in.
/// And it names the session it leaves behind, because the journal part replays that session.
@Test func phaseTwoAgainstLogic() throws {
  let typed = Phase2Flow.inOrder.map(\.typed)
  #expect(
    typed == [
      "tracks add --type software-instrument",
      "tracks add --type audio",
      "tracks rename --index 1 --name Bass",
      "tracks mute --index 1 --on",
      "tracks mute --index 1 --off",
      "tracks solo --index 1 --on",
      "tracks delete --index 2",
      "tracks list",
    ],
    "phase 2 is every command of the phase, in the order a person drives them: \(typed)")

  var said: [String] = []
  for command in Phase2Flow.inOrder {
    Phase2Live.announce(command, through: { said.append($0) })
  }
  #expect(
    said == Phase2Flow.inOrder.map(\.liveScenario),
    "each command answers for itself, by the name of the scenario that drives it: \(said)")
  #expect(
    said.isEmpty == false && Set(said).count == said.count,
    "and no two of them answer to one name, which a count reads as one scenario: \(said)")

  #expect(Phase2Live.runsOnThisMac([:]) == false, "a run that names nothing drives no Logic")
  #expect(Phase2Live.runsOnThisMac(["LOGICCTL_LIVE": "0"]) == false)
  #expect(
    Phase2Live.runsOnThisMac(["LOGICCTL_LIVE": "1"]),
    "and a person turns the phase on with the one variable, on the Mac that has Logic")

  let folder = try LiveHarness.temporaryFolder()
  defer { try? FileManager.default.removeItem(at: folder) }

  let target = try Phase2Live.saveTarget(in: folder)
  #expect(
    LiveHarness.isUnder(folder, target),
    "the project of a scenario is saved in the folder of the run: \(target.path)")
  #expect(target.pathExtension == "logicx", "and it is a project of Logic: \(target.path)")

  var refused: Error?
  do {
    _ = try Phase2Live.saveTarget(in: Phase2Live.logicFolder)
  } catch {
    refused = error
  }
  #expect(
    isTheMusicFolderRefusal(refused),
    "the folder a person keeps their work in is refused: \(String(describing: refused))")

  let arrived = Phase2Live.newEntryLines(
    before: ["Sketch.logicx"], after: ["Phase2.logicx", "Sketch.logicx"])
  #expect(
    arrived == ["music folder: new entry Phase2.logicx"],
    "a name that arrived under the folder of Logic projects is reported: \(arrived)")
  #expect(
    Phase2Live.newEntryLines(before: ["Sketch.logicx"], after: []).isEmpty,
    "and the report names what arrived, because the run removes nothing there")

  #expect(
    Phase2Live.sessionLine("7f3a9c11") == "live session: 7f3a9c11",
    "the run names the session it leaves behind, which the journal part replays")

  #expect(
    Phase2Live.screenshotLine(nil) == nil,
    "a step that carries a picture of the window says nothing more about it")
  #expect(
    Phase2Live.screenshotLine("no grant") == "live screenshot: no grant",
    "and a Mac that took none says what it said, without failing the phase")
}

/// Whether the harness refused a path for sitting under the music folder of this Mac.
private func isTheMusicFolderRefusal(_ error: Error?) -> Bool {
  switch error as? LiveHarness.Refusal {
  case .theProjectIsUnderTheMusicFolder, .theCopyWouldBeUnderTheMusicFolder:
    return true
  default:
    return false
  }
}

/// What `new-project` answers.
private struct NewProjectAnswer: Decodable {
  /// The session that records the work on the project it made.
  let session: String

  /// Where that session sits on this Mac.
  let repository: String
}

/// What `save` answers.
private struct SaveAnswer: Decodable {
  /// The project Logic has open, and where it sits now.
  struct Project: Decodable {
    let name: String
    let path: String
  }

  let project: Project
}

/// What a command that changes one track answers.
private struct TrackAnswer: Decodable {
  let track: Phase2Live.Row
}

/// What a command that answers the whole list answers.
private struct TracksAnswer: Decodable {
  let tracks: [Phase2Live.Row]
}

/// What `meta` says about the picture of the window of Logic.
private struct PictureNote: Decodable {
  /// The part of `meta` that carries what went beside the command without failing it.
  struct Meta: Decodable {
    /// What the run said about the picture.
    struct Details: Decodable {
      let screenshot: String?
    }

    let details: Details?
  }

  let meta: Meta?
}
