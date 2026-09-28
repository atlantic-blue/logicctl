import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// The version of Logic every recorded tree came from.
private let recordedVersion = "12.3.1"

/// Where the recorded trees sit. They are read from the source tree, because the folder sits beside
/// the test targets rather than inside one.
private let recordedTrees = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// One recorded window, read from the tree `inspect` wrote.
private func recorded(_ tree: String) throws -> any AXNode {
  try RecordedTree(contentsOf: recordedTrees.appending(path: tree)).root
}

/// What one run of the command wrote, on each channel, and the number it exited with.
private struct Answer {
  let out: String
  let err: String
  let status: Int32

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// What the answer carries under `data`, or an empty object when it carries none.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }

  /// The failure the answer carries, or an empty object when it carries none.
  func failure() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }

  /// What the answer carries under `meta`.
  func meta() throws -> [String: Any] {
    try printed()["meta"] as? [String: Any] ?? [:]
  }

  /// What `meta` carries under `details`, or an empty object when it carries none.
  func details() throws -> [String: Any] {
    try meta()["details"] as? [String: Any] ?? [:]
  }
}

/// One element of the tree a test drives, which keeps what is written to it and answers it again.
///
/// It is a class, so the command holds the elements the fake changes: a selection written at a row,
/// and a step of a slider, land on the element the command read, the way they land in Logic. A tree
/// of values would answer the same numbers however often it was written to, and a command that
/// changed nothing would read as a command that worked.
private final class Element: AXNode {
  var role: String
  var title: String? = nil
  var identifier: String? = nil
  var value: String? = nil
  var valueDescription: String? = nil
  var description: String? = nil
  var help: String? = nil
  var actions: [String] = []

  var children: [any AXNode] {
    reads += 1
    read?()
    return kept
  }

  /// How many times anything read the elements under this one.
  private(set) var reads = 0

  /// What a test is told each time the elements under this one are read.
  var read: (() -> Void)? = nil

  /// True while Logic holds this row or this region item selected. No tree carries a selection,
  /// command reads this through the closures of `EventList.Actions` or of `RegionSelection`, and
  /// never through `AXNode`.
  var held = false

  private let kept: [any AXNode]

  init(of node: any AXNode) {
    role = node.role
    title = node.title
    identifier = node.identifier
    value = node.value
    valueDescription = node.valueDescription
    description = node.description
    help = node.help
    actions = node.actions
    kept = node.children.map { Element(of: $0) }
  }

  init(role: String, children: [any AXNode]) {
    self.role = role
    kept = children
  }

  /// Forgets the reads made while the fake was built.
  func forget() {
    reads = 0
  }
}

/// The Tracks window of a project whose tracks 3, 4 and 5 each carry a region.
///
/// `mixer-and-event-list-in-front.json` is a whole application, and its Tracks window is the one
/// recorded tree that holds a region item on more than one track. Only that window is taken, so the
/// Event List of this test is the one its notes were read from.
private func theTracksWindowOfThreeRegions() throws -> any AXNode {
  let application = try recorded("mixer-and-event-list-in-front.json")
  guard
    let window = application.children.first(where: { ($0.title ?? "").hasSuffix(" - Tracks") })
  else {
    throw AFakeLogic.ShowsNoTracksWindow()
  }
  return window
}

/// A Logic that shows the Tracks window of a project and the Event List of one region, and moves
/// what it is asked to move.
///
/// The windows are the trees `inspect` recorded from Logic 12.3.1, read once. A write at a row
/// that row, and a write at a region item toggles that region, the way Logic answers one. A step of
/// a slider changes the number Logic shows on it, which is where the reader of the notes takes a
/// velocity from, and leaves the scaled number under it, which no reader turns back into one.
private final class AFakeLogic {
  /// None of the windows this fake was given is a Tracks window, so it holds no region to select.
  struct ShowsNoTracksWindow: Error {}

  /// The window this fake was given holds no table of events, so it holds no row to drive.
  struct ShowsNoEventList: Error {}

  /// The Event List window Logic is showing.
  let window: Element

  /// The Tracks window Logic is showing.
  let tracks: Element

  /// The rows of the table of events, in the order the table answers them.
  let rows: [Element]

  /// Every region item of the Tracks window, in the order Accessibility answers them.
  let regions: [Element]

  /// How far each step moved a slider, in the order the steps went out.
  private(set) var steps: [Int] = []

  /// What Logic was asked to do, in order, with a repeat of the same thing read as one.
  private(set) var did: [String] = []

  /// The table of events. A read of it is a read of the Event List.
  private let table: Element

  /// The region item each track carries, against the number of that track.
  private let ofTrack: [Int: Element]

  /// True while a write that lets a row go reaches Logic. A Logic that keeps a row takes the
  /// write, holds the row, and answers a selection nobody asked for.
  private let letsARowGo: Bool

  /// True while Logic takes no selection write once a slider has moved, which is the Logic that
  /// keeps the row of the edit after the write back.
  private let takesNoSelectionAfterTheEdit: Bool

  init(
    showing window: any AXNode,
    tracks: any AXNode,
    theWriteLetsARowGo: Bool = true,
    theWriteBackTakesNoSelection: Bool = false
  ) throws {
    letsARowGo = theWriteLetsARowGo
    takesNoSelectionAfterTheEdit = theWriteBackTakesNoSelection
    self.window = Element(of: window)
    self.tracks = Element(of: tracks)
    guard
      let found = try LocatorResolver.element(of: Locators.eventListTable, in: self.window)
        as? Element
    else {
      throw ShowsNoEventList()
    }
    table = found
    rows = found.children.compactMap { $0 as? Element }.filter { $0.role == "AXRow" }
    guard let group = AFakeLogic.contents(of: self.tracks) else {
      throw ShowsNoTracksWindow()
    }
    regions = AFakeLogic.regionItems(under: group)
    ofTrack = AFakeLogic.regionsOfTheTracks(under: group)
    table.forget()
    table.read = { [weak self] in self?.record("read the Event List") }
  }

  /// The windows Logic is showing.
  ///
  /// The Tracks window comes first. A walk looking for the region items stops at the first group it
  /// finds, so it never reaches the Event List, and a read of that table is a read a command made.
  var tree: LogicTree {
    LogicTree(
      logicVersion: recordedVersion,
      root: Element(role: "AXApplication", children: [tracks, window]))
  }

  /// How many times anything read the table of the Event List.
  var readsOfTheEventListTable: Int {
    table.reads
  }

  /// How Logic selects a region: a write of `AXSelected` toggles the item it lands on.
  var selection: AutomationMenus.RegionSelection {
    AutomationMenus.RegionSelection(
      holds: { ($0 as? Element)?.held ?? false },
      write: { item in
        guard let region = item as? Element else {
          return
        }
        region.held = !region.held
        self.record("select the region")
      },
      same: { one, other in
        guard let left = one as? Element, let right = other as? Element else {
          return false
        }
        return left === right
      })
  }

  /// Says Logic holds the regions of these tracks selected, and no other region.
  func hold(theRegionsOfTracks tracks: [Int]) {
    for region in regions {
      region.held = false
    }
    for track in tracks {
      ofTrack[track]?.held = true
    }
  }

  /// The regions Logic holds selected, named by the track each one sits on.
  var heldRegions: [String] {
    regions.filter { $0.held }.map { region in
      guard let track = ofTrack.first(where: { $0.value === region })?.key else {
        return "a region on no track of its own"
      }
      return "the region of track \(track)"
    }
  }

  /// Keeps what Logic was asked to do. A repeat of the same thing is read as one, because a walk
  /// of a window reads what it holds more than once and the order is what a test asks about.
  private func record(_ what: String) {
    guard did.last != what else {
      return
    }
    did.append(what)
  }

  /// The group the Tracks window holds the tracks and their regions in.
  private static func contents(of node: Element) -> Element? {
    if node.description == RegionReader.contentsGroup {
      return node
    }
    for child in node.children.compactMap({ $0 as? Element }) {
      if let found = contents(of: child) {
        return found
      }
    }
    return nil
  }

  /// Every region item under one element, at any depth. A region holds no region, so the walk stops
  /// at the first one it finds on a branch.
  private static func regionItems(under node: Element) -> [Element] {
    node.children.compactMap { $0 as? Element }.flatMap { child -> [Element] in
      child.role == RegionReader.regionRole ? [child] : regionItems(under: child)
    }
  }

  /// The region item each track carries, against the number of that track.
  ///
  /// A track is the area at its own place under the group, with or without a description, which is
  /// how the Tracks window of Logic 12.3.1 answers the tracks of a project.
  private static func regionsOfTheTracks(under group: Element) -> [Int: Element] {
    let areas = group.children.compactMap { $0 as? Element }
      .filter { $0.role == RegionReader.trackRole }
    var found: [Int: Element] = [:]
    for (place, area) in areas.enumerated() {
      let items = area.children.compactMap { $0 as? Element }
        .filter { $0.role == RegionReader.regionRole }
      if let first = items.first {
        found[place + 1] = first
      }
    }
    return found
  }

  /// Where the rows Logic holds selected sit in the table, from 1.
  var heldRows: [Int] {
    rows.enumerated().filter { $0.element.held }.map { $0.offset + 1 }
  }

  /// Says Logic holds the rows at these places in the table selected, and no other row.
  func hold(theRowsAt places: [Int]) {
    for (place, row) in rows.enumerated() {
      row.held = places.contains(place + 1)
    }
  }

  /// The number on the velocity slider of every row of the table, in the order of the table. A
  /// fader row carries the value of its volume point in that column.
  var velocities: [Int] {
    rows.map { row in
      guard let slider = EventList.velocitySlider(of: row) else {
        return -1
      }
      return number(of: slider)
    }
  }

  /// What the command drives Logic through.
  var actions: EventList.Actions {
    EventList.Actions(
      select: { row, holding in
        guard let element = row as? Element else {
          return
        }
        if !holding, !self.letsARowGo {
          return
        }
        if holding, self.takesNoSelectionAfterTheEdit, !self.steps.isEmpty {
          return
        }
        element.held = holding
      },
      selected: { row in
        (row as? Element)?.held ?? false
      },
      stepper: { slider in
        SliderStepper(
          read: { self.number(of: slider) },
          write: { asked in
            self.move(slider, by: asked > self.number(of: slider) ? 1 : -1)
          },
          act: { step in
            self.move(
              slider,
              by: step == .up ? SliderStepper.stepOfAnAction : -SliderStepper.stepOfAnAction)
          })
      })
  }

  /// The number Logic shows on one slider.
  private func number(of slider: any AXNode) -> Int {
    Int(slider.valueDescription ?? "") ?? -1
  }

  /// Moves one slider by one step, and records how far it went.
  private func move(_ slider: any AXNode, by step: Int) {
    guard let element = slider as? Element else {
      return
    }
    element.valueDescription = String(number(of: element) + step)
    steps.append(step)
  }
}

/// A Logic showing the Tracks window of three regions and the Event List of a region of four notes.
private func aLogicShowingTheTracksAndTheEventList(
  theWriteLetsARowGo: Bool = true,
  theWriteBackTakesNoSelection: Bool = false
) throws -> AFakeLogic {
  try AFakeLogic(
    showing: try recorded("event-list-automation.json"),
    tracks: try theTracksWindowOfThreeRegions(),
    theWriteLetsARowGo: theWriteLetsARowGo,
    theWriteBackTakesNoSelection: theWriteBackTakesNoSelection)
}

/// A project of one track that carries one region, which is what `--track 4 --region 1` names.
private func aProjectWithARegionOnTrack4() -> [Track] {
  [
    Track(
      index: 4,
      name: "Studio Grand",
      type: .softwareInstrument,
      regions: [Region(index: 1, name: "MIDI Region", start: "1 bar", end: "3 bars")])
  ]
}

/// Runs one whole command line, the way a person types it, against a Logic that shows this window.
///
/// The project sits nowhere by default, which is a project that was never saved, so there is no
/// session to write a step into and nothing of that run touches the disk. A run that is given a
/// path drives the project of a person instead: the session under that root says who made the
/// project, and `--confirm` travels from the words a person typed into the run that reads it.
private func midiVelocity(
  _ arguments: [String],
  against logic: AFakeLogic,
  path: String? = nil,
  root: URL? = nil,
  git: Git = Git()
) throws -> Answer {
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(arguments)
  let velocity = try #require(typed as? Midi.SetVelocity)
  let status = velocity.answer(
    driver: FakeLogicDriver(tracks: aProjectWithARegionOnTrack4(), path: path),
    of: { logic.tree },
    confirmed: velocity.guarded.confirm,
    events: logic.actions,
    selection: logic.selection,
    root: root ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
    git: git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A velocity belongs to one note, and every other event of the region keeps the numbers it had.
///
/// Logic applies an edit to every row it holds selected, and the probe watched one edit of a single
/// automation point move a second point and all four note velocities by the same amount, because
/// they were all still selected. So the damage a velocity command can do is silent: the answer
/// reads as though one note changed, and the region carries four changes that nobody asked for and
/// that no later read attributes to this command.
///
/// The region of the recorded tree carries four notes at velocity 100, 70, 100 and 64, and three
/// volume points at 60, 90 and 110 which sit in the same column of the same table. Note 2 goes to
/// 90. What this proves is what the other six rows read afterwards: 100, 100 and 64 for the notes,
/// 60, 90 and 110 for the points, with every pitch, every position and every length as it was. The
/// velocity the answer carries is the one the slider reads after the change, so a Logic that took
/// the step and stopped at 80 could not report 90.
///
/// The second half is the note that is not there. Note 9 of a region of four notes stops the
/// command with `note_not_found`, and the count of the notes goes out with it, so a person asks
/// again without opening Logic to look. Nothing is selected and no slider moves.
@Test func velocityChangesOnlyItsNote() throws {
  let logic = try aLogicShowingTheTracksAndTheEventList()
  let before = try EventList.notes(in: try #require(EventList.window(of: logic.tree)))
  try #require(
    before.map(\.velocity) == [100, 70, 100, 64], "the four velocities Logic recorded")
  try #require(
    logic.velocities == [60, 100, 70, 100, 64, 90, 110],
    "three volume points share the column the velocities sit in")

  let answer = try midiVelocity(
    ["midi", "velocity", "--track", "4", "--region", "1", "--note", "2", "--value", "90"],
    against: logic)

  let data = try answer.data()
  #expect(data["track"] as? Int == 4, "the track the region sits on")
  #expect(data["region"] as? Int == 1, "the region the note sits in")
  #expect(data["note"] as? Int == 2, "the note that changed")
  #expect(data["velocity"] as? Int == 90, "the velocity the slider reads after the change")
  #expect(
    data.keys.sorted() == ["note", "region", "track", "velocity"],
    "the answer names the one note it changed, and carries no list of notes")
  #expect(answer.status == 0, "the command exits 0")
  #expect(answer.err == "", "standard error stays empty when a command worked")

  let after = try EventList.notes(in: try #require(EventList.window(of: logic.tree)))
  #expect(
    after.map(\.velocity) == [100, 90, 100, 64], "note 2 carries 90, and no other note moved")
  #expect(after.map(\.pitch) == before.map(\.pitch), "every pitch is the one it was")
  #expect(after.map(\.position) == before.map(\.position), "every note starts where it did")
  #expect(after.map(\.length) == before.map(\.length), "every note is as long as it was")
  #expect(after.map(\.channel) == before.map(\.channel), "every note is on the channel it was")
  #expect(
    logic.velocities == [60, 100, 90, 100, 64, 90, 110],
    "the three volume points read 60, 90 and 110, as Logic recorded them")
  #expect(
    logic.heldRows == [],
    "nothing was selected before, so the empty selection goes back and note 2 is let go")
  #expect(
    logic.steps == [10, 10],
    "70 reaches 90 in two steps of the slider, which moves 10 at a time")

  let untouched = try aLogicShowingTheTracksAndTheEventList()
  let refused = try midiVelocity(
    ["midi", "velocity", "--track", "4", "--region", "1", "--note", "9", "--value", "90"],
    against: untouched)

  let failure = try refused.failure()
  #expect(refused.status == 18, "the number the design system gives note_not_found")
  #expect(
    failure["code"] as? String == "note_not_found", "a note that is not there is refused as one")
  #expect(
    failure["message"] as? String == "Region 1 of track 4 has no note 9",
    "the sentence names the region and the number that was asked for")
  let details = failure["details"] as? [String: Any] ?? [:]
  #expect(details["notes"] as? Int == 4, "the count of the notes the region holds")
  #expect(
    details.keys.sorted() == ["notes"], "the count is the whole of what the refusal carries")
  #expect(try refused.printed()["data"] is NSNull, "a failure carries no data")
  #expect(
    refused.err.hasPrefix("logicctl: note_not_found: "),
    "the one line of standard error reads logicctl: <code>: <message>")
  #expect(untouched.heldRows == [], "no row was held selected")
  #expect(untouched.steps == [], "no slider moved")
  #expect(
    untouched.velocities == [60, 100, 70, 100, 64, 90, 110],
    "every velocity and every volume point is the one Logic recorded")
}

/// A folder no other test writes into, for one scenario.
private func aFolderOfItsOwn() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-velocity-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A git whose configuration signs every commit, with a signing program that always fails.
///
/// A session repository turns signing off for itself, so no test here reads or writes the
/// configuration of the operator.
private func gitThatSigns(inside folder: URL) throws -> Git {
  let configuration = folder.appendingPathComponent("gitconfig")
  let written = """
    [commit]
    \tgpgsign = true
    [gpg]
    \tprogram = /usr/bin/false
    """
  try Data(written.utf8).write(to: configuration, options: .atomic)
  return Git(environment: [
    "GIT_CONFIG_GLOBAL": configuration.path,
    "GIT_CONFIG_SYSTEM": "/dev/null",
  ])
}

/// A Mac that takes no picture of the window, which is every Mac the pipeline runs on.
private struct NoPictureOfTheWindow: WindowCapturer {
  struct TookNone: Error {}

  func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    throw TookNone()
  }
}

/// Where the project of the person sits.
private let theirProject = "/Users/someone/Music/Their Sketch.logicx"

/// The subjects of every commit of a session, newest first.
private func subjects(of folder: URL, with git: Git) throws -> [String] {
  try git.run(["log", "--format=%s"], in: folder)
    .split(separator: "\n", omittingEmptySubsequences: true)
    .map(String.init)
}

/// The session of a project a person made, holding the state Logic holds.
///
/// `createdByLogicctl` is false, which is what says the work in the project is theirs. The session
/// records the same project the driver answers, so the run finds nothing a person changed by hand
/// and the only step it can write is the step of the command.
private func aSessionTheyMade(inside root: URL, with git: Git) throws -> SessionRepository {
  let theirs = Session(
    project: Session.Project(
      name: "Untitled", path: theirProject, createdByLogicctl: false),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
  return try SessionRepository.start(
    session: theirs,
    root: root,
    state: try FakeLogicDriver(tracks: aProjectWithARegionOnTrack4()).readState(),
    git: git)
}

/// A person writes music in their own project, and an agent changes the velocity of one note of it.
///
/// The work in that project is theirs. A velocity is one number on one row of a window nobody is
/// looking at, so a change to it leaves nothing on the screen to notice: the region plays a little
/// louder, and the person finds out days later with nothing to point at. Every other command that
/// changes a project asks first, and this one did not, which made the guard a property of some
/// commands rather than a rule of the tool.
///
/// So the agent reads `confirm_required` and exit 7. Note 2 still carries the velocity 70 Logic
/// recorded, no row of the Event List is held selected, no step of the slider goes out, and the
/// session of the person gained nothing to read back. The person then types the same line with
/// `--confirm`, and note 2 carries 90 and the change is in the record as one step.
@Test func velocityNeedsConfirmOnAProjectLogicctlDidNotMake() throws {
  let root = try aFolderOfItsOwn()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let session = try aSessionTheyMade(inside: root, with: git)
  let logic = try aLogicShowingTheTracksAndTheEventList()
  let theirs = try EventList.notes(in: try #require(EventList.window(of: logic.tree)))
  try #require(
    theirs.map(\.velocity) == [100, 70, 100, 64], "the four velocities the person left")

  let refused = try midiVelocity(
    ["midi", "velocity", "--track", "4", "--region", "1", "--note", "2", "--value", "90"],
    against: logic,
    path: theirProject,
    root: root,
    git: git)

  let failure = try refused.failure()
  let details = failure["details"] as? [String: Any] ?? [:]
  #expect(refused.status == 7, "the number the design system gives confirm_required")
  #expect(
    failure["code"] as? String == "confirm_required", "logicctl did not make this project")
  #expect(
    failure["message"] as? String
      == "logicctl did not make this project, so a change to it needs --confirm.",
    "the sentence says what the person types to go ahead")
  #expect(
    details["project"] as? String == theirProject, "the refusal names the project it protected")
  #expect(
    refused.err.hasPrefix("logicctl: confirm_required: "),
    "the one line of standard error reads logicctl: <code>: <message>")
  #expect(try refused.printed()["data"] is NSNull, "a failure carries no data")
  let kept = try EventList.notes(in: try #require(EventList.window(of: logic.tree)))
  #expect(
    kept.map(\.velocity) == [100, 70, 100, 64],
    "every note carries the velocity the person left it at")
  #expect(logic.heldRows == [], "no row was held selected")
  #expect(logic.steps == [], "no slider moved")
  #expect(try refused.meta()["step"] is NSNull, "a refused change writes no step")
  #expect(
    try subjects(of: session.folder, with: git) == ["session \(session.session.shortId)"],
    "the session of the person gained nothing")

  let allowed = try aLogicShowingTheTracksAndTheEventList()
  let said = try midiVelocity(
    [
      "midi", "velocity", "--track", "4", "--region", "1", "--note", "2", "--value", "90",
      "--confirm",
    ],
    against: allowed,
    path: theirProject,
    root: root,
    git: git)

  let data = try said.data()
  let changed = try EventList.notes(in: try #require(EventList.window(of: allowed.tree)))
  #expect(said.status == 0, "the person said --confirm, so the change goes through")
  #expect(data["note"] as? Int == 2, "the note that changed")
  #expect(data["velocity"] as? Int == 90, "the velocity the slider reads afterwards")
  #expect(
    changed.map(\.velocity) == [100, 90, 100, 64], "note 2 carries 90, and no other note moved")
  _ = try #require(try said.meta()["step"] as? String, "the change that went through is recorded")
  #expect(
    try subjects(of: session.folder, with: git).first == "1 midi velocity",
    "the session holds the change the person allowed, and only that one")
}

/// An agent changes the velocity of a note of one region, and the note it moves is in that region.
///
/// The Event List shows the region Logic holds selected. Measured on Logic 12.3.1 on 2026-09-27:
/// after a take, Logic held the regions of two tracks selected, and a read of a third region
/// answered the events of one of those two. This command goes further than a read: it finds the row
/// of `--note 2` in the list, holds that row and moves its slider. So a list of the wrong region
/// means the velocity of a note of another part of the song changes, while the answer names the
/// region a person asked for and the note they asked for.
///
/// So the region the command names is the only region Logic holds before any row is read.
@Test func velocityChangesTheNoteOfTheNamedRegion() throws {
  let logic = try aLogicShowingTheTracksAndTheEventList()
  logic.hold(theRegionsOfTracks: [5])
  try #require(
    logic.heldRegions == ["the region of track 5"],
    "Logic holds the region of another track, as it does after a take")

  let answer = try midiVelocity(
    ["midi", "velocity", "--track", "4", "--region", "1", "--note", "2", "--value", "90"],
    against: logic)

  #expect(
    logic.heldRegions == ["the region of track 4"],
    "the region the command named is the only region Logic holds")
  #expect(
    logic.did == ["select the region", "read the Event List"],
    "the region is selected before a row is read, so the row belongs to the named region")
  #expect(try answer.data()["velocity"] as? Int == 90, "the velocity the slider reads afterwards")
  #expect(answer.status == 0, "the command exits 0")
}

/// An edit gives the selection back, because the selection is the work of the person at the
/// keyboard.
///
/// A person selects the rows they are working on, in this table the rows of note 1 and note 2, and
/// that selection is where they are in the piece. Logic applies an edit to every selected row, so
/// this command takes the selection down to the one row it edits. That is the right thing to do and
/// it costs the person their place: the two rows they had are gone, the answer says nothing about
/// it, and the next thing they press in Logic lands on the row logicctl left behind.
///
/// So the edit gives it back. The rows of note 1 and note 2 are selected again when the command
/// ends, the velocity of note 1 is the only number that moved, and the answer does not change,
/// because a selection that went back is not news.
///
/// The second run is the Logic that does not take the rows back. The edit is already done by then,
/// so the command still answers success, and it carries `selectionRestored` false and the names of
/// the rows, which is what a person needs to select them again without opening Logic to look.
///
/// The third run is the Logic that keeps a row, which is the refusal the guard exists for. The
/// command changes nothing and answers `selection_mismatch`, and the rows of the person still go
/// back, because a command that refused took their selection away just the same.
@Test func anEditPutsBackTheSelectedRows() throws {
  let logic = try aLogicShowingTheTracksAndTheEventList()
  logic.hold(theRowsAt: [2, 3])
  try #require(
    logic.heldRows == [2, 3],
    "Logic holds the rows of note 1 and note 2, which is where the person was working")

  let answer = try midiVelocity(
    ["midi", "velocity", "--track", "4", "--region", "1", "--note", "1", "--value", "90"],
    against: logic)

  #expect(answer.status == 0, "the command exits 0")
  #expect(try answer.data()["velocity"] as? Int == 90, "note 1 carries the velocity asked for")
  #expect(
    logic.velocities == [60, 90, 70, 100, 64, 90, 110],
    "one number of the column moved, and the other six are the ones Logic recorded")
  #expect(logic.steps == [-10], "100 reaches 90 in one step of the slider")
  #expect(
    logic.heldRows == [2, 3],
    "the rows of note 1 and note 2 are selected again, as the person left them")
  #expect(
    try answer.meta()["details"] is NSNull,
    "a selection that went back is not news, so the answer is the answer of any other edit")

  let keeping = try aLogicShowingTheTracksAndTheEventList(theWriteBackTakesNoSelection: true)
  keeping.hold(theRowsAt: [2, 3])

  let said = try midiVelocity(
    ["midi", "velocity", "--track", "4", "--region", "1", "--note", "1", "--value", "90"],
    against: keeping)

  #expect(said.status == 0, "the edit went through, so a selection that stayed put fails nothing")
  #expect(try said.data()["velocity"] as? Int == 90, "note 1 carries the velocity asked for")
  #expect(keeping.heldRows == [2], "Logic kept the row of the edit and took no selection back")
  let details = try said.details()
  #expect(
    details["selectionRestored"] as? Bool == false, "the answer says the rows did not go back")
  #expect(
    details["selectionBefore"] as? [String] == ["note 1", "note 2"],
    "the rows the person had selected, so they select them again without looking")

  let kept = try aLogicShowingTheTracksAndTheEventList(theWriteLetsARowGo: false)
  kept.hold(theRowsAt: [2, 3])

  let refused = try midiVelocity(
    ["midi", "velocity", "--track", "4", "--region", "1", "--note", "1", "--value", "90"],
    against: kept)

  #expect(refused.status == 20, "the number the design system gives selection_mismatch")
  #expect(
    try refused.failure()["code"] as? String == "selection_mismatch",
    "Logic holds a row nobody named, so no edit goes out")
  #expect(kept.steps == [], "no slider moved")
  #expect(
    kept.velocities == [60, 100, 70, 100, 64, 90, 110],
    "every velocity and every volume point is the one Logic recorded")
  #expect(
    kept.heldRows == [2, 3],
    "a command that refused took the selection away too, so it goes back as well")
  #expect(
    (try refused.failure()["details"] as? [String: Any] ?? [:]).keys.sorted() == ["selected"],
    "the rows went back, so the refusal says what it always said")
}
