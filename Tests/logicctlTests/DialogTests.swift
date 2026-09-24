import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlTesting
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-dialog-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A git whose configuration signs every commit, with a signing program that always fails.
///
/// Every test here writes a real repository, and a session repository turns signing off for
/// itself. So no test reads or writes the configuration of the operator.
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

/// The project as logicctl last recorded it: one track, 120 beats a minute.
private func aProjectWithOneTrack() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// The session of that project, as an earlier command started it.
private func aSession() -> Session {
  Session(
    project: Session.Project(name: "Sketch", path: projectPath, createdByLogicctl: true),
    versions: Session.Versions(logicctl: "0.1.0", logic: "12.3.1", macos: "15.0"))
}

/// The dialog Logic opens when it imports a MIDI file, read from Logic 12.3.1 in the ingress
/// probe. It has no title, so a check that looks for a titled window misses it.
private let theTempoQuestion = ModalDialog(
  text: "Also import tempo information?",
  buttons: ["No", "Import Tempo", "Cancel"])

/// A command whose action leaves Logic waiting on that dialog, as the MIDI import does.
private struct ImportAMidiFile: LogicCommand {
  let name = "midi import"
  let argv = ["--file", "/tmp/offgrid.mid"]

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    guard let fake = driver as? FakeLogicDriver else {
      throw DriverRefusal.logicNotRunning
    }
    fake.dialog = theTempoQuestion
    return .object(["track": .number(2)])
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

/// Logic asks a question and waits for an answer, and logicctl is not allowed to answer it.
///
/// Importing a MIDI file makes Logic ask whether to import the tempo of the file as well. Both
/// answers change the project, and neither is what the person typed, so logicctl presses nothing
/// and stops. The person reads the question and the three answers in the output, goes to Logic,
/// and decides. A tool that pressed a button here would change the tempo of a project on its own.
@Test func aDialogAfterTheActionStopsTheCommand() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let recorded = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: recorded, git: git)
  let driver = FakeLogicDriver(state: recorded, path: projectPath)

  let answer = Run(driver: driver, root: root, version: "0.1.0", git: git)
    .run(command: ImportAMidiFile())

  #expect(answer.error?.code == .dialogOpen, "Logic is waiting, so the command did not finish")
  #expect(answer.exitCode == 16)
  #expect(answer.data == nil, "a command that stopped answers nothing")
  #expect(
    answer.error?.details
      == .object([
        "text": .string("Also import tempo information?"),
        "buttons": .array([.string("No"), .string("Import Tempo"), .string("Cancel")]),
      ]),
    "the person reads the question and every answer it offers")
  #expect(
    try driver.modalDialog() == theTempoQuestion,
    "the dialog is still open, because logicctl pressed no button in it")

  _ = try #require(answer.meta.step, "logicctl touched the project, so the attempt is kept")
  let attempt = try record(ofStep: 1, in: session.folder)
  #expect(attempt["command"] as? String == "midi import")
  #expect(attempt["exitCode"] as? Int == 16)
  let envelope = attempt["envelope"] as? [String: Any] ?? [:]
  let failure = envelope["error"] as? [String: Any] ?? [:]
  #expect(failure["code"] as? String == "dialog_open")
  let details = failure["details"] as? [String: Any] ?? [:]
  #expect(details["buttons"] as? [String] == ["No", "Import Tempo", "Cancel"])
}

/// The same question, asked of the driver instead of the run. Every driver must say whether Logic
/// is waiting, and must name a button a person can press, or the person is handed a dialog they
/// cannot answer.
@Test func theFakeNamesTheDialogLogicWaitsOn() throws {
  let project = Conformance.aProjectWithOneTrack
  let driver = FakeLogicDriver(state: project)
  driver.dialog = theTempoQuestion

  try Conformance.namesTheDialogLogicWaitsOn.run(against: driver, holding: project)
}

/// Reading the dialog is a read of Logic like the others, so a fake with no Logic refuses it. A
/// fake that answered "no dialog" here would let a command through that the real driver stops.
@Test func aFakeWithNoLogicRefusesTheDialogRead() {
  let driver = FakeLogicDriver()

  #expect(throws: DriverRefusal.logicNotRunning) { try driver.modalDialog() }
}
