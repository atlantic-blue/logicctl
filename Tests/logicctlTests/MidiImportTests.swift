import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// A folder no other test writes into, for one part of a scenario.
private func aFolderOfItsOwn() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-import-\(UUID().uuidString)")
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

/// Where the project of these tests sits.
private let projectPath = "/Users/someone/Music/Sketch.logicx"

/// The MIDI file these tests import, which is the file `midi write-file` writes from
/// `Tests/Fixtures/notes.json`. Importing the fixture is what an agent does: it writes a file, and
/// then it asks Logic to take the same bytes.
private let theFile = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/notes.mid")

/// What the start up disk of the Mac in a test is called. A real Mac answers its own name, and
/// nothing in logicctl may assume this one.
private let theDisk = "A Disk Of Its Own"

/// How long Logic is given for each wait, in milliseconds.
private let theLimit = 2000

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class ImportTime {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// One thing the command asked the panel of Logic to do.
private enum Move: Equatable {
  /// File, Import, "MIDI File..." was pressed.
  case menu

  /// A control of the panel was pressed, by the name of its locator.
  case pressed(String)

  /// An item of the menu the Where popup opened was pressed, by its title.
  case wherePopup(String)

  /// Logic was brought to the front and the panel was raised.
  case broughtToTheFront

  /// The file list was scrolled until a row was in view, by the name it shows.
  case broughtIntoView(String)

  /// A folder row was opened, by the name it shows.
  case opened(String)

  /// The file list was told to select these rows and nothing else.
  case selected([String])
}

/// The Import panel of Logic 12.3.1, and the project behind it.
///
/// Measured on Logic 12.3.1 on 2026-09-25: the panel carries no field for a path, so it is walked
/// one folder at a time from the start up disk, and the Import button is what takes the file. The
/// panel here answers the same way, so a command that walked somewhere else, or that pressed
/// Import with the wrong rows selected, is caught here rather than on a person's project.
private final class APanel {
  /// Every move the command made, in the order it made them.
  private(set) var moves: [Move] = []

  /// The Logic whose project the Import button changes.
  private let carriedBy: FakeLogicDriver

  /// What the panel does to the project when Import is pressed.
  private let onImport: (FakeLogicDriver) -> Void

  /// The folder the panel answers for, whatever it was asked to open. A panel that lands
  /// somewhere else is a panel about to import a file of that name from another folder.
  private let landsIn: String?

  /// A row the file list keeps selected besides the one the command asked for.
  private let alsoSelected: String?

  /// Whether the Import button reads enabled once the file is selected. Logic behind another
  /// application leaves it disabled, and a press of it does nothing.
  private let importIsEnabled: Bool

  /// Whether the panel is open.
  private var shows = false

  /// The folder the panel is in, as the Where popup shows it.
  private var folder = "Desktop"

  /// The rows the file list holds selected.
  private var selection: [String] = []

  init(
    carriedBy: FakeLogicDriver,
    landsIn: String? = nil,
    alsoSelected: String? = nil,
    importIsEnabled: Bool = true,
    onImport: @escaping (FakeLogicDriver) -> Void
  ) {
    self.carriedBy = carriedBy
    self.landsIn = landsIn
    self.alsoSelected = alsoSelected
    self.importIsEnabled = importIsEnabled
    self.onImport = onImport
  }

  /// The route the command is given.
  var dialog: ImportDialog {
    ImportDialog(
      openTheMenuItem: {
        self.moves.append(.menu)
        self.shows = true
      },
      showsThePanel: { self.shows },
      press: { locator in
        self.moves.append(.pressed(locator.name))
        guard locator.name == Locators.importButton.name else {
          return
        }
        self.shows = false
        self.onImport(self.carriedBy)
      },
      bringToFront: { self.moves.append(.broughtToTheFront) },
      enabled: { _ in self.importIsEnabled },
      pressItem: { title in
        self.moves.append(.wherePopup(title))
        self.folder = title
      },
      bringIntoView: { name in self.moves.append(.broughtIntoView(name)) },
      openFolder: { name in
        self.moves.append(.opened(name))
        self.folder = self.landsIn ?? name
      },
      folderShown: { self.folder },
      startUpDisk: { theDisk },
      selection: SelectionGuard(
        select: { names in
          self.moves.append(.selected(names))
          self.selection = names + (self.alsoSelected.map { [$0] } ?? [])
        },
        selection: { self.selection }))
  }
}

/// The track Logic makes for a MIDI file, with the region it puts on it.
///
/// The kind reads as `other`, because the header of a track says nothing about its kind and that
/// is what the reader answers for every track. The command carries `software-instrument` into the
/// answer, because that is the one kind Logic makes for a MIDI file.
private func theTrackLogicMakes() -> Track {
  Track(
    index: 2,
    name: "Studio Grand",
    type: .other,
    regions: [Region(index: 1, name: "MIDI Region", start: "1 bar", end: "2 bars")])
}

/// The import Logic does: a new track with the region on it.
private func anImportThatLands(_ driver: FakeLogicDriver) {
  driver.state?.tracks.append(theTrackLogicMakes())
}

/// The project Logic has open: one software instrument track, and nothing else.
private func aProject() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// The session of that project, as an earlier command started it.
private func aSession(madeByLogicctl: Bool = true) -> Session {
  Session(
    project: Session.Project(
      name: "Sketch", path: projectPath, createdByLogicctl: madeByLogicctl),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// A Logic with the session of its project, in a folder of its own.
private struct ALogic {
  let root: URL
  let git: Git
  let session: SessionRepository
  let driver: FakeLogicDriver
}

private func aLogic(madeByLogicctl: Bool = true) throws -> ALogic {
  let root = try aFolderOfItsOwn()
  let git = try gitThatSigns(inside: root)
  let project = aProject()
  return ALogic(
    root: root,
    git: git,
    session: try SessionRepository.start(
      session: aSession(madeByLogicctl: madeByLogicctl), root: root, state: project, git: git),
    driver: FakeLogicDriver(state: project, path: projectPath))
}

/// A Mac that takes no picture of the window, which is every Mac the pipeline runs on.
private struct NoPictureOfTheWindow: WindowCapturer {
  struct TookNone: Error {}

  func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    throw TookNone()
  }
}

/// What one run wrote, on each channel.
private final class Printed {
  var out = ""
  var err = ""

  func write(_ text: String) {
    out += text
  }

  func writeError(_ text: String) {
    err += text
  }

  /// What standard output carried, read back as JSON.
  func json() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// The data of the answer, or nil when the answer carries none.
  func data() throws -> [String: Any]? {
    try json()["data"] as? [String: Any]
  }

  /// The code of the failure the answer carries, or nil when it carries none.
  func failureCode() throws -> String? {
    let failure = try json()["error"] as? [String: Any]
    return failure?["code"] as? String
  }

  /// What the failure says, in one sentence.
  func failureMessage() throws -> String {
    let failure = try json()["error"] as? [String: Any]
    return failure?["message"] as? String ?? ""
  }

  /// What the failure says about itself.
  func failureDetails() throws -> [String: Any] {
    let failure = try json()["error"] as? [String: Any]
    return failure?["details"] as? [String: Any] ?? [:]
  }

  /// The `meta` of the answer.
  func meta() throws -> [String: Any] {
    try json()["meta"] as? [String: Any] ?? [:]
  }
}

/// What the `step.json` of one step holds.
private func record(ofStep sequence: Int, in folder: URL) throws -> [String: Any] {
  let file =
    folder
    .appendingPathComponent("steps")
    .appendingPathComponent(SessionRepository.stepFolderName(ofSequence: sequence))
    .appendingPathComponent("step.json")
  let read = try JSONSerialization.jsonObject(with: try Data(contentsOf: file))
  return read as? [String: Any] ?? [:]
}

/// How many steps a session holds.
private func steps(in folder: URL) -> Int {
  let steps = folder.appendingPathComponent("steps").path
  let names = (try? FileManager.default.contentsOfDirectory(atPath: steps)) ?? []
  return names.count
}

/// The folders of a path, from the start up disk down, without the file. The test works this out
/// itself, so the walk of the command is compared with the path and not with its own reading of it.
private func folders(of file: URL) -> [String] {
  file.resolvingSymlinksInPath().deletingLastPathComponent().path
    .split(separator: "/", omittingEmptySubsequences: true)
    .map(String.init)
}

/// Runs `midi import` against a Logic, through a panel of the test.
private func midiImport(
  file: String,
  logic: ALogic,
  panel: APanel,
  disk: ImportFile = ImportFile.live(),
  confirmed: Bool = false
) -> (status: Int32, answer: Printed) {
  let answer = Printed()
  let time = ImportTime()
  let status = Midi.Import.answer(
    driver: logic.driver,
    dialog: panel.dialog,
    disk: disk,
    file: file,
    confirmed: confirmed,
    root: logic.root,
    version: "0.1.0",
    limitMs: theLimit,
    argv: ["--file", file],
    clock: time.read,
    sleeper: time.sleep,
    git: logic.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: answer.write,
    standardError: answer.writeError)
  return (status, answer)
}

/// An agent writes a MIDI file and asks Logic to play it, and reads back where the notes landed.
///
/// This is the whole of what the command is for. Logic does not put a MIDI file on the track that
/// is selected: it makes a new software instrument track and puts the region on that. So the
/// answer names the track Logic made and the bars the region covers, and an agent that never opens
/// Logic knows where its notes are.
///
/// A press that Logic took proves nothing, so the command reads the project afterwards and reports
/// success only once the track and its region are there. And the hash of the bytes goes into the
/// answer and into the record of the step, beside the path. That is what makes the session worth
/// replaying: the record says which bytes reached the project, so a later run can say that the
/// file at that path changed rather than importing other notes under the same name. The bytes
/// themselves stay on the disk of the person, and the session copies nothing.
@Test func importStoresTheFileInTheStep() throws {
  let logic = try aLogic()
  defer { try? FileManager.default.removeItem(at: logic.root) }

  let typed = try Logicctl.parseAsRoot(["midi", "import", "--file", theFile.path])
  #expect(typed is Midi.Import, "the noun and the verb of the design system")
  #expect(logic.driver.state?.tracks.count == 1, "the project holds one track before the import")

  let bytes = try Data(contentsOf: theFile)
  let panel = APanel(carriedBy: logic.driver, onImport: anImportThatLands)
  let (status, answer) = midiImport(file: theFile.path, logic: logic, panel: panel)

  #expect(status == 0, "the notes reached the project")
  #expect(try answer.json()["error"] is NSNull, "nothing failed")
  #expect(answer.err.isEmpty, "standard error is empty on success")

  let track = try #require(try answer.data()?["track"] as? [String: Any])
  #expect(track["index"] as? Int == 2, "the track Logic made, and not the one that was selected")
  #expect(track["name"] as? String == "Studio Grand", "the name Logic gave it")
  #expect(
    track["type"] as? String == "software-instrument",
    "Logic makes a software instrument track for a MIDI file")
  #expect(track.keys.sorted() == ["index", "name", "type"], "and nothing else")

  let region = try #require(try answer.data()?["region"] as? [String: Any])
  #expect(region["startBar"] as? Int == 1, "the bar the region starts at")
  #expect(region["endBar"] as? Int == 2, "the bar it ends at")

  #expect(
    try answer.data()?["sha256"] as? String == MidiFile.sha256(of: [UInt8](bytes)),
    "the hash of the bytes Logic was given, which is the hash midi write-file prints for them")
  #expect(try answer.data()?.keys.sorted() == ["region", "sha256", "track"], "and nothing else")

  #expect(
    panel.moves == [
      .menu, .broughtToTheFront, .pressed(Locators.importWherePopup.name), .wherePopup(theDisk),
    ]
      + folders(of: theFile).flatMap { [Move.broughtIntoView($0), Move.opened($0)] }
      + [.selected([theFile.lastPathComponent]), .pressed(Locators.importButton.name)],
    "each folder was scrolled to and then opened, and then Import was pressed")

  #expect(logic.driver.state?.tracks.count == 2, "the project holds the track Logic made")

  let commit = try #require(try answer.meta()["step"] as? String, "the import is one step")
  #expect(!commit.isEmpty, "the step is a commit of the session")
  let step = try record(ofStep: 1, in: logic.session.folder)
  #expect(step["command"] as? String == "midi import")
  #expect(step["exitCode"] as? Int == 0)
  #expect(
    step["argv"] as? [String] == ["--file", theFile.path],
    "the record names the file, so a replay reads the path from the step")
  let recorded = step["envelope"] as? [String: Any] ?? [:]
  let data = recorded["data"] as? [String: Any] ?? [:]
  #expect(
    data["sha256"] as? String == MidiFile.sha256(of: [UInt8](bytes)),
    "and the hash, so a replay can say that the file at that path changed")

  #expect((step["inputs"] as? [Any])?.isEmpty == true, "the session copies no file of its own")
  let inputs = logic.session.folder
    .appendingPathComponent("steps")
    .appendingPathComponent(SessionRepository.stepFolderName(ofSequence: 1))
    .appendingPathComponent("inputs")
  #expect(
    !FileManager.default.fileExists(atPath: inputs.path),
    "and nothing was written under inputs")
}

/// A file Logic cannot be walked to is refused before Logic is asked anything.
///
/// The Import panel lists visible folders alone, so a file under a hidden folder cannot be reached
/// by opening one row at a time. A person reaching for a scratch file puts it in /tmp, which
/// resolves to /private/tmp, and /private is hidden. The message names the folder, because the fix
/// is to move the file.
@Test func aHiddenFolderOnThePathIsRefusedBeforeLogic() throws {
  let logic = try aLogic()
  defer { try? FileManager.default.removeItem(at: logic.root) }

  let panel = APanel(carriedBy: logic.driver, onImport: anImportThatLands)
  let disk = ImportFile(
    resolve: { _ in "/private/tmp/notes.mid" },
    hidden: { folder in folder == "/private" },
    read: { _ in Data([0x4d, 0x54, 0x68, 0x64]) })

  let (status, answer) = midiImport(
    file: "/tmp/notes.mid", logic: logic, panel: panel, disk: disk)

  #expect(status == 2, "an argument that is wrong")
  #expect(try answer.failureCode() == "invalid_argument")
  #expect(try answer.failureMessage().contains("/private"), "the message names the hidden folder")
  #expect(
    try answer.failureMessage().contains("visible folder"),
    "and says what to do about it")
  #expect(try answer.failureDetails()["field"] as? String == "--file")
  #expect(panel.moves.isEmpty, "Logic was asked nothing")
  #expect(logic.driver.state?.tracks.count == 1, "so the project did not change")
  #expect(try answer.meta()["step"] is NSNull, "and the session gained no step")
  #expect(steps(in: logic.session.folder) == 0)
}

/// Logic took the press and made no track, so the command says the import did not land.
///
/// This is the failure the whole read back exists for. A command that reported success here would
/// tell an agent its notes are in the project, and the agent would go on to quantize a region that
/// is not there.
@Test func anImportThatMakesNoTrackFails() throws {
  let logic = try aLogic()
  defer { try? FileManager.default.removeItem(at: logic.root) }

  let panel = APanel(carriedBy: logic.driver) { _ in }
  let (status, answer) = midiImport(file: theFile.path, logic: logic, panel: panel)

  #expect(status == 5, "nothing was found in the project")
  #expect(try answer.failureCode() == "element_not_found")
  #expect(
    try answer.failureMessage().contains("did not reach the project"),
    "the message says what did not happen")
  #expect(try answer.json()["data"] is NSNull, "a command that stopped answers nothing")
  #expect(logic.driver.state?.tracks.count == 1, "the project is as it was")

  _ = try #require(try answer.meta()["step"] as? String, "the attempt is kept")
  let step = try record(ofStep: 1, in: logic.session.folder)
  #expect(step["exitCode"] as? Int == 5)
}

/// Logic made the track and put no region on it, so the command says the import did not land.
///
/// A track with no region carries none of the notes. This is its own case, because a command that
/// counted tracks alone passes the test above and still reports success here.
@Test func anImportThatMakesATrackWithNoRegionFails() throws {
  let logic = try aLogic()
  defer { try? FileManager.default.removeItem(at: logic.root) }

  let panel = APanel(carriedBy: logic.driver) { driver in
    driver.state?.tracks.append(Track(index: 2, name: "Studio Grand", type: .other))
  }
  let (status, answer) = midiImport(file: theFile.path, logic: logic, panel: panel)

  #expect(status == 5, "the track is there and the notes are not")
  #expect(try answer.failureCode() == "element_not_found")
  #expect(try answer.failureMessage().contains("did not reach the project"))
  #expect(try answer.json()["data"] is NSNull, "a command that stopped answers nothing")
}

/// Logic asks whether to import the tempo of the file, and logicctl is not allowed to answer it.
///
/// Both answers change the project and neither is what the person typed. So logicctl presses
/// nothing and stops, and the person reads the question and the three answers in the output. A
/// tool that pressed a button here would change the tempo of a project on its own, and a tool that
/// ticked the checkbox beside them, `supression-checkbox`, would stop Logic asking anybody again.
@Test func theTempoQuestionStopsTheImport() throws {
  let logic = try aLogic()
  defer { try? FileManager.default.removeItem(at: logic.root) }

  let question = ModalDialog(
    text: "Also import tempo information?",
    buttons: ["No", "Import Tempo", "Cancel"])
  let panel = APanel(carriedBy: logic.driver) { driver in
    anImportThatLands(driver)
    driver.dialog = question
  }
  let (status, answer) = midiImport(file: theFile.path, logic: logic, panel: panel)

  #expect(status == 16, "Logic is waiting")
  #expect(try answer.failureCode() == "dialog_open")
  #expect(try answer.json()["data"] is NSNull, "a command that stopped answers nothing")
  #expect(
    try answer.failureDetails()["text"] as? String == "Also import tempo information?",
    "the person reads the question")
  #expect(
    try answer.failureDetails()["buttons"] as? [String] == ["No", "Import Tempo", "Cancel"],
    "and every answer it offers")
  #expect(
    try logic.driver.modalDialog() == question,
    "the dialog is still open, because logicctl pressed no button in it")

  _ = try #require(try answer.meta()["step"] as? String, "the attempt is kept")
  let step = try record(ofStep: 1, in: logic.session.folder)
  #expect(step["exitCode"] as? Int == 16)
}

/// A file that is not there is refused before Logic is asked anything.
@Test func aFileThatIsNotThereIsRefused() throws {
  let logic = try aLogic()
  defer { try? FileManager.default.removeItem(at: logic.root) }

  let panel = APanel(carriedBy: logic.driver, onImport: anImportThatLands)
  let missing = logic.root.appending(path: "nothing-is-here.mid").path
  let (status, answer) = midiImport(file: missing, logic: logic, panel: panel)

  #expect(status == 2, "an argument that is wrong")
  #expect(try answer.failureCode() == "invalid_argument")
  #expect(try answer.failureDetails()["field"] as? String == "--file")
  #expect(panel.moves.isEmpty, "Logic was asked nothing")
  #expect(steps(in: logic.session.folder) == 0, "and the session gained no step")
}

/// A project a person made is left alone until they say so.
@Test func aProjectLogicctlDidNotMakeNeedsConfirm() throws {
  let logic = try aLogic(madeByLogicctl: false)
  defer { try? FileManager.default.removeItem(at: logic.root) }

  let panel = APanel(carriedBy: logic.driver, onImport: anImportThatLands)
  let (status, answer) = midiImport(file: theFile.path, logic: logic, panel: panel)

  #expect(status == 7, "the guard stopped it")
  #expect(try answer.failureCode() == "confirm_required")
  #expect(panel.moves.isEmpty, "Logic was asked nothing")
  #expect(logic.driver.state?.tracks.count == 1, "so the project did not change")

  let allowed = try aLogic(madeByLogicctl: false)
  defer { try? FileManager.default.removeItem(at: allowed.root) }
  let second = APanel(carriedBy: allowed.driver, onImport: anImportThatLands)
  let said = midiImport(
    file: theFile.path, logic: allowed, panel: second, confirmed: true)
  #expect(said.status == 0, "and --confirm lets it through")
}

/// The panel opened a folder and landed somewhere else, so nothing is imported.
///
/// A file of the same name sits in more than one folder on any Mac. A route that pressed Import
/// here would put somebody else's notes in the project and report the path the person typed. The
/// Where popup is the only thing that says where the panel is, so a popup that never shows the
/// folder ends the walk, and the panel it left open is closed.
@Test func aPanelThatLandsInTheWrongFolderImportsNothing() throws {
  let logic = try aLogic()
  defer { try? FileManager.default.removeItem(at: logic.root) }

  let panel = APanel(
    carriedBy: logic.driver, landsIn: "Somewhere Else", onImport: anImportThatLands)
  let (status, answer) = midiImport(file: theFile.path, logic: logic, panel: panel)
  let asked = try ImportFile.live().facts(of: theFile.path).path.folders.first

  #expect(status == 6, "the walk stopped")
  #expect(try answer.failureCode() == "timeout")
  #expect(try answer.failureMessage().contains("Somewhere Else"), "the message says where it is")
  #expect(try answer.failureDetails()["folder"] as? String == asked, "the folder it asked for")
  #expect(try answer.failureDetails()["waitedMs"] as? Int == theLimit, "and what it was given")
  #expect(
    !panel.moves.contains(.pressed(Locators.importButton.name)),
    "and Import was never pressed")
  #expect(
    panel.moves.contains(.pressed(Locators.importCancelButton.name)),
    "the panel it left open is closed")
  #expect(logic.driver.state?.tracks.count == 1, "so the project did not change")
}

/// The file list kept another row selected, so nothing is imported.
///
/// Logic imports every file the panel has selected. A press with two rows selected would put two
/// files in the project and answer as though it put one.
@Test func aSelectionThatHoldsMoreImportsNothing() throws {
  let logic = try aLogic()
  defer { try? FileManager.default.removeItem(at: logic.root) }

  let panel = APanel(
    carriedBy: logic.driver, alsoSelected: "other.mid", onImport: anImportThatLands)
  let (status, answer) = midiImport(file: theFile.path, logic: logic, panel: panel)

  #expect(status == 20, "the selection holds more than the file")
  #expect(try answer.failureCode() == "selection_mismatch")
  #expect(
    try answer.failureDetails()["selected"] as? [String] == [
      theFile.lastPathComponent, "other.mid",
    ],
    "the person reads what else Logic had selected")
  #expect(
    !panel.moves.contains(.pressed(Locators.importButton.name)),
    "and Import was never pressed")
  #expect(logic.driver.state?.tracks.count == 1, "so the project did not change")
}

/// Every folder of the path is read for the hidden flag, and the file itself is not.
///
/// A file whose own name starts with a full stop sits in folders the panel can list, so it is
/// reachable and the command takes it.
@Test func theHiddenCheckReadsTheFoldersAndNotTheFile() throws {
  var asked: [String] = []
  let disk = ImportFile(
    resolve: { $0 },
    hidden: { folder in
      asked.append(folder)
      return false
    },
    read: { _ in Data([0x4d, 0x54, 0x68, 0x64]) })

  let facts = try disk.facts(of: "/Users/someone/Music/.hidden-notes.mid")

  #expect(
    asked == ["/Users", "/Users/someone", "/Users/someone/Music"],
    "every folder of the path, from the start up disk down")
  #expect(facts.path.folders == ["Users", "someone", "Music"])
  #expect(facts.path.name == ".hidden-notes.mid", "and the file is taken as it is")
}

/// The Import button is disabled, so nothing is pressed and nothing is imported.
///
/// Measured on Logic 12.3.1 on 2026-09-25: with Logic behind another application, the file row
/// selects and the button stays disabled. A press of a disabled button is taken by nobody, so a
/// command that pressed it and read the project too early would report an import that never
/// happened. The command reads the button instead, and says which control refused.
@Test func aDisabledImportButtonStopsTheCommand() throws {
  let logic = try aLogic()
  defer { try? FileManager.default.removeItem(at: logic.root) }

  let panel = APanel(
    carriedBy: logic.driver, importIsEnabled: false, onImport: anImportThatLands)
  let (status, answer) = midiImport(file: theFile.path, logic: logic, panel: panel)

  #expect(status == 5, "the button would take no press")
  #expect(try answer.failureCode() == "element_not_found")
  #expect(try answer.failureMessage().contains("OKButton"), "the message names the control")
  #expect(
    !panel.moves.contains(.pressed(Locators.importButton.name)),
    "and nothing was pressed")
  #expect(logic.driver.state?.tracks.count == 1, "so the project did not change")
}
