import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// The version of Logic the trees were recorded from.
private let recordedVersion = "12.3.1"

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// The window of a project Logic has just made, with the sheet that asks for the first track on it.
private let theNewProject = "empty-project-new-track-sheet.json"

/// The window of a project that holds a track and no sheet.
private let theProjectWithATrack = "one-track.json"

/// The track the sheet makes for its own defaults, which are one Software Instrument track.
///
/// The type comes from this list and not from a walk of the recorded tree. A track header carries
/// no type, so `TrackReader` answers `other` for every track until the reader of the Mixer lands.
private let theTrackCreateMakes = Track(
  index: 1, name: "Deluxe Classic", type: .softwareInstrument)

/// The button of the sheet that closes the project Logic has just made.
///
/// Logic removes the folder it wrote for that project, so a person who pressed it would be left
/// with nothing. Nothing in logicctl names this button, and this walk is here so the test can read
/// the element and say that no press reached it.
private let theCancelButtonOfTheSheet = Locator(
  name: "test.newTrackSheet.cancelButton",
  path: [
    LocatorStep(role: "AXWindow"),
    LocatorStep(role: "AXSheet"),
    LocatorStep(role: "AXGroup"),
    LocatorStep(role: "AXButton", title: "Cancel"),
  ])

/// A person or an agent types one command and is left with a project they can save.
///
/// Measured on this Mac at 11:13 on 2026-09-26: `new-project` answered, and `save --path` then
/// failed with `timeout`. Logic puts the sheet that asks for the first track on a project it has
/// just made, and while that sheet is open the File menu reads Save false and Save As false. So the
/// command handed back a project that could not be kept, and the only button that closes the sheet
/// by itself is Cancel, which closes the project and takes the folder Logic wrote with it.
///
/// The command now answers the sheet the way a person answers it. It presses Create, which takes
/// the defaults of the sheet and makes one Software Instrument track. It answers once the sheet is
/// gone and the project holds that track. So a person gets a project Logic will save, and a session
/// that recorded it. A Logic that keeps the sheet open is a failure and not an answer, and the
/// failure names the sheet, because a person who reads `timeout` has to know where to look. A
/// project that already holds tracks is answered as it is.
@Test func newProjectPressesCreateAndAnswersOneTrack() throws {
  let logic = try Mac(showing: theNewProject, andAfterCreate: theProjectWithATrack)
  let made = logic.newProject()

  #expect(made.status == 0, "the command answered the sheet and made a project: \(made.out)")
  #expect(made.err.isEmpty, "standard error is empty on success")
  #expect(
    logic.pressed == [Locators.newTrackCreateButton.name],
    "Create is the one element the route pressed")

  let button = try LocatorResolver.element(
    of: Locators.newTrackCreateButton, in: logic.firstShown.root)
  let cancel = try LocatorResolver.element(of: theCancelButtonOfTheSheet, in: logic.firstShown.root)

  #expect(button.role == "AXButton" && button.title == "Create", "the element it pressed")
  #expect(
    cancel.identifier != button.identifier,
    "the sheet holds Cancel beside Create, and the walk reached Create")

  let answered = try made.data()
  let project = try #require(answered["project"] as? [String: Any])
  #expect(project["name"] as? String == "Untitled")
  #expect(project["path"] is NSNull, "a project has no path until it is saved")

  let session = try #require(answered["session"] as? String, "the answer names the session")
  let folder = try #require(answered["repository"] as? String, "and where it sits")
  let repository = URL(fileURLWithPath: folder)
  let recorded = try readJSON(at: repository.appending(path: "session.json"))
  let onDisk = try #require(Session(json: recorded))

  #expect(onDisk.id == session, "the session of the answer is the session on disk")
  #expect(onDisk.project.createdByLogicctl, "logicctl made this project")

  let tracks = tracksRecorded(in: repository)

  #expect(tracks.count == 1, "the project a person is left with holds the track Create made")
  #expect(tracks.first?["index"] == JSONValue.number(1))
  #expect(tracks.first?["name"] == JSONValue.string(theTrackCreateMakes.name))
  #expect(
    tracks.first?["type"] == JSONValue.string("software-instrument"),
    "the defaults of the sheet make a software instrument track")

  // A Logic that keeps the sheet open after the press is the other half of the promise. The
  // command reads the project back rather than trusting the press, so a sheet that stays is a
  // failure, and no session is started for a project nobody can save.
  let stuck = try Mac(showing: theNewProject, andAfterCreate: nil)
  let refused = stuck.newProject()

  #expect(refused.status == 6, "timeout exits 6")
  #expect(refused.err.hasPrefix("logicctl: timeout: "))
  #expect(try refused.code() == "timeout")

  let said = try refused.message()

  #expect(
    said.contains("New Track sheet"), "the failure names the sheet that stayed open: \(said)")
  #expect(
    stuck.pressed == [Locators.newTrackCreateButton.name],
    "Create was pressed once, and nothing else was pressed after it")
  #expect(try refused.data().isEmpty, "a project nobody can save answers no project")
  #expect(stuck.sessionsWritten().isEmpty, "and nothing was written for it")

  // A Logic that already shows a project with tracks is the project this command promises, so it is
  // answered as it is and no button is pressed at all.
  let already = try Mac(
    showing: theProjectWithATrack, andAfterCreate: nil, holding: [theTrackCreateMakes])
  let found = already.newProject()

  #expect(found.status == 0, "a project with tracks is an answer: \(found.out)")
  #expect(already.pressed.isEmpty, "there was no sheet to answer, so nothing was pressed")
  #expect(tracksRecorded(in: URL(fileURLWithPath: try found.folder())).count == 1)

  for run in [logic, stuck, already] {
    #expect(
      run.elementsPressed().allSatisfy { ($0.title ?? "") != "Cancel" },
      "no press of any run reached Cancel, which would have closed the project")
  }
}

/// The Logic a test drives: the window it shows, and the project it has open behind that window.
///
/// The window says what Logic shows, and the driver says what the project holds, which is how the
/// command reads the two. The recorded trees stand for the shape of the window and not for its
/// title: what the command reads from a tree here is whether it holds the chooser, the sheet, or
/// neither.
private final class Mac {
  /// The tree Logic shows now.
  var showing: RecordedTree

  /// The tree Logic showed when the command started.
  let firstShown: RecordedTree

  /// The tree Logic shows once Create is pressed, or nothing when the sheet stays open.
  let afterCreate: RecordedTree?

  /// The elements the command pressed, in the order it pressed them.
  var pressed: [String] = []

  /// The Logic the command reads the project through.
  let driver: FakeLogicDriver

  /// Where the sessions of this run sit.
  let root: URL

  /// The git of this run. It signs with a program that fails, so no commit waits for a key.
  let git: Git

  init(showing first: String, andAfterCreate next: String?, holding tracks: [Track] = []) throws {
    firstShown = try RecordedTree(contentsOf: fixtureFolder.appending(path: first))
    showing = firstShown
    afterCreate = try next.map {
      try RecordedTree(contentsOf: fixtureFolder.appending(path: $0))
    }
    driver = FakeLogicDriver(tracks: tracks)
    root = FileManager.default.temporaryDirectory
      .appending(path: "logicctl-chooser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    git = try Mac.gitThatSigns(inside: root)
  }

  /// What Logic shows now, read from the window as a command reads it.
  var shows: ProjectWindow? {
    ProjectChooser.window(showing: showing.root)
  }

  /// The chooser the command drives. Create answers the sheet, as Logic does.
  func chooser() -> ProjectChooser {
    ProjectChooser(
      read: { self.shows },
      press: { locator in
        self.pressed.append(locator.name)
        guard locator.name == Locators.newTrackCreateButton.name else {
          return
        }
        guard let next = self.afterCreate else {
          return
        }
        self.showing = next
        self.driver.state = State(
          logic: LogicVersion(version: recordedVersion),
          project: Project(name: "Untitled"),
          transport: Transport(tempo: 120),
          tracks: [theTrackCreateMakes])
      })
  }

  /// Runs `logicctl new-project` against this Logic, and answers what it wrote.
  func newProject(limitMs: Int = 200) -> Answer {
    let time = Time()
    let written = Answer()
    written.status = NewProject.answer(
      chooser: chooser(),
      driver: driver,
      root: root,
      limitMs: limitMs,
      clock: time.read,
      sleeper: time.sleep,
      git: git,
      capturer: APicture(bytes: Data("a window".utf8)),
      standardOutput: written.write,
      standardError: written.writeError)
    return written
  }

  /// The elements this run pressed, read out of the tree it started from.
  ///
  /// A press carries the name of a locator, and the element that name reaches is what Logic acted
  /// on, so this is where a press of the wrong button would show.
  func elementsPressed() -> [any AXNode] {
    pressed.compactMap { name -> (any AXNode)? in
      guard let locator = Locators.all.first(where: { $0.name == name }) else {
        return nil
      }
      return try? LocatorResolver.element(of: locator, in: firstShown.root)
    }
  }

  /// The sessions this run left on disk.
  func sessionsWritten() -> [String] {
    let folder = SessionRepository.sessionsFolder(underRoot: root)
    return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
  }

  /// A git whose configuration signs every commit, with a signing program that always fails.
  ///
  /// A session repository turns signing off for itself, so a commit of logicctl never waits for a
  /// key and never claims that a person signed it. No test reads or writes the configuration of the
  /// operator.
  private static func gitThatSigns(inside folder: URL) throws -> Git {
    let configuration = folder.appending(path: "gitconfig")
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
}

/// A clock and a sleep the test moves itself, so a wait of any length costs the suite no time.
private final class Time {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// What one run wrote, on each channel, and the number it exited with.
private final class Answer {
  var out = ""
  var err = ""
  var status: Int32 = -1

  func write(_ text: String) {
    out += text
  }

  func writeError(_ text: String) {
    err += text
  }

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// The `data` of the answer, or an empty object when it carries none.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }

  /// The code the answer failed with, or nothing when it did not fail.
  func code() throws -> String? {
    let failure = try printed()["error"] as? [String: Any] ?? [:]
    return failure["code"] as? String
  }

  /// What the failure said, or an empty string when the answer carries none.
  func message() throws -> String {
    let failure = try printed()["error"] as? [String: Any] ?? [:]
    return failure["message"] as? String ?? ""
  }

  /// Where the session of the answer sits.
  func folder() throws -> String {
    try data()["repository"] as? String ?? ""
  }
}

/// A picture of the window of Logic, which the pipeline has no window server to take.
private struct APicture: WindowCapturer {
  let bytes: Data

  func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    bytes
  }
}

/// The tracks the session at one folder recorded, in the order they read.
///
/// A folder that holds no state answers nothing rather than throwing, so a run that wrote no
/// session fails the expectation that reads it, and every claim after that one still runs.
private func tracksRecorded(in repository: URL) -> [[String: JSONValue]] {
  guard let state = try? readJSON(at: repository.appending(path: "state.json")),
    case .object(let fields) = state, case .array(let tracks) = fields["tracks"]
  else {
    return []
  }
  return tracks.compactMap { track in
    guard case .object(let row) = track else {
      return nil
    }
    return row
  }
}

/// One JSON file of a session, read back.
private func readJSON(at file: URL) throws -> JSONValue {
  try CanonicalJSON.value(of: String(decoding: try Data(contentsOf: file), as: UTF8.self))
}
