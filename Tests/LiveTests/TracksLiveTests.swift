import Foundation
import LogicctlCore
import LogicctlMac
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
  /// The kind of track a person writes MIDI on.
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

  /// How many tracks `new-project` leaves in the project it makes.
  ///
  /// Logic asks for the first track of a project the moment it makes one, and it refuses to save
  /// the project until that sheet is answered, so `new-project` presses Create and answers a
  /// project with one software instrument track. Every scenario of phase 2 starts from that track,
  /// which is why `--index 1` names a track before the phase adds anything.
  static let tracksOfANewProject = 1

  /// The command that reads what Logic is doing, which names the project window when there is one.
  static let statusCommand = ["status"]

  /// The command that starts Logic when a scenario finds it not running.
  static let launchCommand = ["launch"]

  /// The command that closes the project of a scenario at the end of it.
  ///
  /// `--discard` throws the changes away, because the journal of the session holds every step and
  /// the project itself is a copy. The design system says `--discard` needs `--confirm`.
  static let quitCommand = ["quit", "--discard", "--confirm"]

  /// The folder where a person keeps their projects of Logic.
  static var logicFolder: URL {
    LiveHarness.musicFolder.appending(path: "Logic")
  }

  /// The folder a scenario makes its own folder in.
  static var homeOfTheRun: URL {
    FileManager.default.homeDirectoryForCurrentUser
  }

  /// The name Logic puts at the start of the title of the window of the project of a scenario.
  static var windowName: String {
    URL(fileURLWithPath: projectName).deletingPathExtension().lastPathComponent
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

  /// Whether Logic is showing the project of a scenario, in any one of its windows.
  static func showsTheProject(in tree: RecordedTree) -> Bool {
    LiveHarness.showsTheProject(named: windowName, in: tree)
  }

  /// A folder of its own for one scenario, under the home folder of this Mac.
  ///
  /// The Save panel of Logic walks the columns of the browser, one folder of the path per column,
  /// and it opens only what a column lists. The temporary folder of this Mac resolves to a path
  /// under the hidden `/var`, which the first column does not list, so a save into it can never
  /// land: measured on this Mac on 2026-09-27 against Logic 12.3.1, save answered that column 1 of
  /// the panel did not list `var` within 5057ms. The home folder is listed, and it is not the music
  /// folder.
  static func folderOfTheScenario(under home: URL = Phase2Live.homeOfTheRun) throws -> URL {
    let folder = home.appending(path: "logicctl-phase2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// Takes the folder of one scenario away at the end of it.
  ///
  /// The project in it is a copy that logicctl made, and the session keeps every step of the work
  /// on it, so nothing there is the work of a person. It goes, rather than leaving one folder per
  /// scenario in the home folder.
  static func removeFolderOfTheScenario(_ folder: URL, fileManager: FileManager = .default) {
    try? fileManager.removeItem(at: folder)
  }

  /// Gets this Mac to a Logic that runs and shows no project, before a scenario makes one.
  ///
  /// Phase 2 runs after phase 1, which ends by quitting Logic, so a scenario meets a Mac with no
  /// Logic and `new-project` waits for a chooser that never comes. `status` answers whether Logic
  /// runs and exits 0 either way, so the phase reads it and starts Logic only when it must.
  ///
  /// Logic reopens the project of its last session as it starts, and `new-project` makes a project
  /// of its own, so it refuses while Logic shows one. `status` names the project window when there
  /// is a project, so the phase reads that name, closes the project with the quit the scenarios end
  /// with, and starts Logic again. `--discard` drops the changes nobody saved. It deletes nothing,
  /// and the project stays where it sits.
  static func logicWithNoProject() throws {
    var read = try ran(StatusAnswer.self, statusCommand)
    if read.running == false {
      read = try launchLogic()
    }
    guard let open = read.projectWindow else {
      print("live logic: running, and it shows no project")
      return
    }

    print("live logic: closing the project Logic had open: \(open)")
    quitLogic()
    read = try launchLogic()
    if let still = read.projectWindow {
      throw Phase2Refusal.logicStillShowsAProject(still)
    }
  }

  /// Starts Logic, and answers what `status` reads of the Logic that is now running.
  ///
  /// The answer of `launch` says that Logic runs and carries no window, so the project Logic
  /// reopened as it started is only visible in a `status` read after it.
  private static func launchLogic() throws -> StatusAnswer {
    let started = try ran(RunningAnswer.self, launchCommand)
    print("live logic: launched, running \(started.running)")
    return try ran(StatusAnswer.self, statusCommand)
  }

  /// Closes the project of a scenario, whichever way the scenario went.
  ///
  /// `new-project` refuses while Logic shows a project, so a scenario that left its project open
  /// would stop every scenario after it before it started anything. The next one then finds a Logic
  /// that does not run, and starts it.
  ///
  /// A quit that fails does not fail the scenario that ran. It says what it answered, and the
  /// scenario after this one reports the state this one left Logic in.
  static func quitLogic() {
    do {
      let closed = try ran(RunningAnswer.self, quitCommand)
      print("live logic: quit, running \(closed.running)")
    } catch {
      print("live logic: quit did not close Logic: \(String(describing: error))")
    }
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
  /// `arm` is printed and never asserted. Logic decides whether a track is armed to record, and
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

  /// The tracks of the project Logic has open now.
  static func tracksNow() throws -> [Row] {
    try ran(TracksAnswer.self, ["tracks", "list"]).tracks
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
    try waitForTheWindowOfTheProject()
    return Phase2Project(folder: folder, path: target, session: made.session)
  }

  /// Waits until Logic shows the project of this scenario in one of its windows.
  ///
  /// The first track of the project is a software instrument, so Logic opens the window of its
  /// instrument in front of the project. That window is not modal, and every read of logicctl works
  /// while it is open, so the phase reads every window of Logic and gets on with the scenario as
  /// soon as one of them is the project it saved.
  static func waitForTheWindowOfTheProject() throws {
    var windows = "no window"
    do {
      try Wait.until(limitMs: LiveHarness.openLimitMs, pollMs: LiveHarness.pollMs) {
        guard let tree = try LiveHarness.treeOfLogic() else {
          return false
        }
        windows = LiveHarness.whatTheWindowsRead(in: tree)
        return showsTheProject(in: tree)
      }
    } catch let ranOut as Wait.RanOut {
      throw LiveHarness.Refusal.logicDidNotShowTheCopy(
        name: windowName, seen: windows, waitedMs: ranOut.waitedMs)
    }
    print("live windows: \(windows)")
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
    let folder = try folderOfTheScenario()
    defer {
      quitLogic()
      removeFolderOfTheScenario(folder)
      for line in newEntryLines(before: before, after: namesUnderTheLogicFolder()) {
        print(line)
      }
    }

    try logicWithNoProject()
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
///
/// The `type` of a row is read from the channel strip of the track in the Mixer, so the Mixer is
/// open while the phase runs. A track whose strip the reader cannot find reads `other`, which is
/// what the two scenarios that add a track name in their failure.
///
/// Each scenario reaches a Logic that runs and shows no project before it makes one, and it closes
/// its project at the end, whichever way it went. Phase 1 quits Logic, Logic reopens the project of
/// its last session as it starts, and `new-project` refuses while Logic shows a project, so a phase
/// that did neither would drive nothing after its first scenario.
@Suite(.serialized, .enabled(if: Phase2Live.runsOnThisMac()))
struct Phase2LiveScenarios {
  /// The operator adds a software instrument track to the project `new-project` made (story S2.2).
  @Test func addsASoftwareInstrumentTrackToANewProject() throws {
    try Phase2Live.drive(Phase2Flow.addsASoftwareInstrumentTrack) { _ in
      let before = try Phase2Live.tracksNow()
      let added = try Phase2Live.ran(
        TrackAnswer.self, ["tracks", "add", "--type", "software-instrument"])
      print(Phase2Live.describe(added.track))
      let after = try Phase2Live.tracksNow()

      #expect(
        before.count == Phase2Live.tracksOfANewProject,
        "the project new-project made carries its first track: \(before.count)")
      #expect(
        after.count == before.count + 1,
        "one add is one track more: \(before.count) became \(after.count)")
      #expect(
        added.track.type == "software-instrument",
        "and Logic made the kind that was asked for, read from the Mixer: \(added.track.type)")
      #expect(
        after.contains { $0.index == added.track.index && $0.type == added.track.type },
        "the row it answered is the row the list carries: \(added.track.index)")
    }
  }

  /// The operator adds an audio track (story S2.2).
  @Test func addsAnAudioTrackToANewProject() throws {
    try Phase2Live.drive(Phase2Flow.addsAnAudioTrack) { _ in
      let before = try Phase2Live.tracksNow()
      let added = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "audio"])
      print(Phase2Live.describe(added.track))
      let after = try Phase2Live.tracksNow()

      #expect(
        after.count == before.count + 1,
        "one add is one track more: \(before.count) became \(after.count)")
      #expect(
        added.track.type == "audio",
        "and Logic made an audio track, read from the Mixer: \(added.track.type)")
    }
  }

  /// The operator gives a track a name, and reads the name Logic shows (story S2.3).
  @Test func renamesTheFirstTrack() throws {
    try Phase2Live.drive(Phase2Flow.renamesTheFirstTrack) { _ in
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
      let soloed = try Phase2Live.ran(TrackAnswer.self, ["tracks", "solo", "--index", "1", "--on"])
      print(Phase2Live.describe(soloed.track))

      #expect(soloed.track.solo, "the track Logic shows after the change is soloed")
    }
  }

  /// The operator deletes a track, and reads the list that is left (story S2.4).
  ///
  /// The project starts with one track, so the scenario adds the second one it deletes.
  @Test func deletesTheSecondTrack() throws {
    try Phase2Live.drive(Phase2Flow.deletesTheSecondTrack) { _ in
      _ = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "audio"])
      let before = try Phase2Live.tracksNow()
      #expect(before.count == 2, "this scenario starts from two tracks: \(before.count)")

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
      let made = try Phase2Live.tracksNow()
      for row in made {
        print(Phase2Live.describe(row))
      }
      #expect(
        made.count == Phase2Live.tracksOfANewProject,
        "the list of the project new-project made carries its first track: \(made.count)")
      #expect(made.first?.index == 1, "and the list starts at track 1")

      _ = try Phase2Live.ran(TrackAnswer.self, ["tracks", "add", "--type", "software-instrument"])
      let listed = try Phase2Live.tracksNow()
      for row in listed {
        print(Phase2Live.describe(row))
      }
      #expect(listed.count == made.count + 1, "one track added is one row more: \(listed.count)")
      #expect(
        listed.allSatisfy { !$0.name.isEmpty },
        "and every row carries the name Logic shows: \(listed.map(\.name))")
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
/// on a project in a folder of its own under the home folder, which the Save panel can walk, and it
/// refuses the folder a person keeps their work in. It finds that project in any window of Logic.
/// It reaches a Logic with no project before it makes one, and it takes the folder away at the
/// end. And it names the session it leaves behind, because the journal part replays that session.
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

  let home = try LiveHarness.temporaryFolder()
  defer { try? FileManager.default.removeItem(at: home) }

  let folder = try Phase2Live.folderOfTheScenario(under: home)
  let target = try Phase2Live.saveTarget(in: folder)
  #expect(
    LiveHarness.isUnder(folder, target),
    "the project of a scenario is saved in the folder of that scenario: \(target.path)")
  #expect(target.pathExtension == "logicx", "and it is a project of Logic: \(target.path)")
  #expect(
    folder.lastPathComponent.hasPrefix(".") == false,
    "the Save panel lists one column per folder of the path, so no part of it is hidden")
  #expect(
    Phase2Live.homeOfTheRun == FileManager.default.homeDirectoryForCurrentUser,
    "a scenario saves under the home folder, which the first column of the panel lists")
  #expect(
    LiveHarness.isUnder(Phase2Live.homeOfTheRun, FileManager.default.temporaryDirectory) == false,
    "and never under the temporary folder, whose own first column the panel does not list")

  Phase2Live.removeFolderOfTheScenario(folder)
  #expect(
    FileManager.default.fileExists(atPath: folder.path) == false,
    "the folder of a scenario goes at the end of it, rather than one folder staying per scenario")

  #expect(
    Phase2Live.launchCommand == ["launch"],
    "a scenario starts Logic when it finds none, because the phase before it quit Logic")
  #expect(
    Phase2Live.quitCommand == ["quit", "--discard", "--confirm"],
    "and it closes its project at the end, because new-project refuses while one is open")
  #expect(
    Phase2Live.statusCommand == ["status"],
    "and it reads what Logic shows first, because Logic reopens a project as it starts")

  #expect(
    StatusAnswer(running: true, window: "Untitled 1.logicx - Tracks").projectWindow != nil,
    "a status that names a project window is a project new-project refuses, so the phase closes it")
  #expect(
    StatusAnswer(running: true, window: nil).projectWindow == nil,
    "a status that names none is a Logic a scenario makes its own project in")
  #expect(
    StatusAnswer(running: true, window: "").projectWindow == nil,
    "and a window of no name is no project either")

  var refused: Error?
  do {
    _ = try Phase2Live.saveTarget(in: Phase2Live.logicFolder)
  } catch {
    refused = error
  }
  #expect(
    isTheMusicFolderRefusal(refused),
    "the folder a person keeps their work in is refused: \(String(describing: refused))")

  let behindAnInstrument = try logicWithWindows(["Deluxe Classic", "Phase2.logicx - Tracks"])
  let theInstrumentAlone = try logicWithWindows(["Deluxe Classic"])
  #expect(
    Phase2Live.showsTheProject(in: behindAnInstrument),
    "the phase drives the project it made while Logic keeps another window in front of it")
  #expect(
    Phase2Live.showsTheProject(in: theInstrumentAlone) == false,
    "and a Logic with no window of that project is not showing it")

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

/// A tree of a Logic that shows these windows, in the order Logic lists them.
private func logicWithWindows(_ titles: [String]) throws -> RecordedTree {
  let windows = titles.map { title in
    "{ \"role\": \"AXWindow\", \"title\": \"\(title)\", \"actions\": [\"AXRaise\"] }"
  }.joined(separator: ", ")
  let text = """
    {
      "logicVersion": "\(LiveHarness.logicVersion)",
      "root": {
        "role": "AXApplication",
        "title": "Logic Pro",
        "children": [\(windows)]
      }
    }
    """
  return try JSONDecoder().decode(RecordedTree.self, from: Data(text.utf8))
}

/// What `launch` and `quit` each answer about the Logic on this Mac.
private struct RunningAnswer: Decodable {
  /// Whether Logic runs.
  let running: Bool
}

/// What `status` answers about the Logic on this Mac.
private struct StatusAnswer: Decodable {
  /// Whether Logic runs.
  let running: Bool

  /// The title of the project window, or nothing when Logic shows no project.
  let window: String?

  /// The project Logic has open, by the name of its window, or nothing when it has none.
  ///
  /// `status` reads the window the tracks sit in and not the window in front, so a name here is a
  /// project that `new-project` would refuse, and nothing here is a Logic a scenario can make its
  /// own project in.
  var projectWindow: String? {
    guard let window, !window.isEmpty else {
      return nil
    }
    return window
  }
}

/// What the phase refuses to drive.
private enum Phase2Refusal: Error, CustomStringConvertible {
  /// Logic shows a project after the phase closed one and started Logic again.
  case logicStillShowsAProject(String)

  var description: String {
    switch self {
    case .logicStillShowsAProject(let window):
      return """
        Logic shows the project \(window) after a quit that discarded it and a launch. new-project \
        makes a project of its own, so close that project in Logic and run the phase again
        """
    }
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
