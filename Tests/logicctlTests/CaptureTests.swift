import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlTesting
import Testing

@testable import logicctl

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-capture-\(UUID().uuidString)")
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

/// The command a test drives the run with: it sets the tempo of the project Logic holds.
private struct SetTheTempo: LogicCommand {
  let name = "transport tempo"
  let argv: [String]
  let tempo: Double

  init(_ tempo: Double) {
    self.tempo = tempo
    self.argv = [String(Int(tempo))]
  }

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    guard let fake = driver as? FakeLogicDriver, var state = fake.state else {
      throw DriverRefusal.logicNotRunning
    }
    state.transport.tempo = tempo
    fake.state = state
    return .object(["tempo": .number(tempo)])
  }
}

/// A command that Logic dies in the middle of.
private struct SetTheTempoAndDie: LogicCommand {
  let name = "transport tempo"
  let argv = ["96"]

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    guard let fake = driver as? FakeLogicDriver else {
      throw DriverRefusal.logicNotRunning
    }
    fake.state = nil
    fake.runningProcessID = nil
    throw DriverRefusal.logicNotRunning
  }
}

/// Why a Mac took no picture. On a real Mac the usual reason is the Screen Recording grant, and
/// the reason reaches the answer whatever it is.
private struct TheMacTookNoPicture: Error, CustomStringConvertible {
  let description = "screencapture ended with status 1"
}

/// A Mac that will not take a picture of the window of Logic.
private struct ACaptureThatFails: WindowCapturer {
  func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    throw TheMacTookNoPicture()
  }
}

/// A Mac that takes the picture and answers its bytes.
private struct ACaptureThatWorks: WindowCapturer {
  /// The bytes the capture answers. A test reads them back out of the commit.
  let bytes: Data

  func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    bytes
  }
}

/// A Mac that counts how many times the run asked it for a picture.
private final class ACaptureThatCounts: WindowCapturer {
  private(set) var asked = 0

  func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    asked += 1
    throw TheMacTookNoPicture()
  }
}

/// What the `step.json` of one step holds.
private func record(ofStep sequence: Int, in folder: URL) throws -> [String: Any] {
  let file = stepFile(sequence, folder)
  let read = try JSONSerialization.jsonObject(with: try Data(contentsOf: file))
  return read as? [String: Any] ?? [:]
}

/// Where the `step.json` of one step sits.
private func stepFile(_ sequence: Int, _ folder: URL) -> URL {
  stepFolder(sequence, folder).appendingPathComponent("step.json")
}

/// Where one step keeps its files.
private func stepFolder(_ sequence: Int, _ folder: URL) -> URL {
  folder
    .appendingPathComponent("steps")
    .appendingPathComponent(SessionRepository.stepFolderName(ofSequence: sequence))
}

/// What the state of a session holds now.
private func storedState(in folder: URL) throws -> String {
  let data = try Data(contentsOf: folder.appendingPathComponent("state.json"))
  return String(decoding: data, as: UTF8.self)
}

/// What `meta` of an answer says about the picture, or nothing when it says nothing.
private func reasonForNoPicture(in meta: Meta) -> String? {
  guard case .object(let details)? = meta.details, case .string(let said)? = details["screenshot"]
  else {
    return nil
  }
  return said
}

/// What `meta` of a recorded answer says about the picture, read as a caller reads it.
private func reasonForNoPicture(inRecorded meta: [String: Any]) -> String? {
  let details = meta["details"] as? [String: Any]
  return details?["screenshot"] as? String
}

/// The files one commit of a session carries.
private func filesOfTheLastCommit(in folder: URL, with git: Git) throws -> [String] {
  try git.run(["show", "--name-only", "--format=", "HEAD"], in: folder)
    .split(separator: "\n", omittingEmptySubsequences: true)
    .map(String.init)
}

/// A Mac refuses to take the picture, and the command that worked still worked.
///
/// The picture is evidence of what Logic looked like, and evidence is not a gate. A Mac that has
/// not been given the Screen Recording grant, a window of Logic that sits behind another window,
/// a `screencapture` that ends badly: each of those would turn every command of a session into a
/// failure if the picture decided the answer. The tempo was set. The person is told the picture
/// is missing, and why, and they keep the result of the command they asked for.
@Test func aFailedCaptureDoesNotFailTheCommand() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let recorded = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: recorded, git: git)
  let driver = FakeLogicDriver(state: recorded, path: projectPath)

  let answer = Run(
    driver: driver, root: root, version: "0.1.0", git: git, capturer: ACaptureThatFails()
  ).run(command: SetTheTempo(96))

  #expect(answer.error == nil, "a picture that was not taken is not a failure of the command")
  #expect(answer.exitCode == 0, "so the command exits with the code it would have exited with")
  #expect(answer.data == .object(["tempo": .number(96)]), "and it still answers what it did")

  var afterwards = recorded
  afterwards.transport.tempo = 96
  #expect(
    try storedState(in: session.folder) == CanonicalJSON.text(of: afterwards, indent: 2) + "\n",
    "the tempo reached Logic and the session holds the project as Logic has it now")

  _ = try #require(answer.meta.step, "the command is in the record")
  let step = try record(ofStep: 1, in: session.folder)
  #expect(
    step["screenshot"] is NSNull,
    "there is no picture, and the record says so rather than naming a file that is not there")
  #expect(
    FileManager.default.fileExists(
      atPath: stepFolder(1, session.folder).appendingPathComponent("screenshot.png").path)
      == false,
    "and the step folder carries no picture")

  let said = try #require(reasonForNoPicture(in: answer.meta), "meta says there is no picture")
  #expect(
    said.contains("screencapture ended with status 1"),
    "and it says why, in the words of the Mac that refused")

  let envelope = step["envelope"] as? [String: Any] ?? [:]
  let keptMeta = envelope["meta"] as? [String: Any] ?? [:]
  #expect(
    reasonForNoPicture(inRecorded: keptMeta) != nil,
    "a person who reads the session tomorrow learns it too, not only the one at the terminal")
}

/// The picture of the window goes into the commit of the step, and the record names it.
///
/// This is what the picture is for: a person compares what logicctl did with what Logic showed,
/// one step at a time, months later. A record that names `screenshot.png` while the commit
/// carries no such file would send them looking for something that was never written.
@Test func thePictureOfTheWindowIsCommittedWithTheStep() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let recorded = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: recorded, git: git)
  let driver = FakeLogicDriver(state: recorded, path: projectPath)
  let taken = Data("a picture of the window of Logic".utf8)

  let answer = Run(
    driver: driver, root: root, version: "0.1.0", git: git,
    capturer: ACaptureThatWorks(bytes: taken)
  ).run(command: SetTheTempo(96))

  #expect(answer.error == nil)
  #expect(answer.meta.details == nil, "nothing went wrong, so meta adds nothing")

  let step = try record(ofStep: 1, in: session.folder)
  #expect(step["screenshot"] as? String == "screenshot.png", "the record names the picture")
  let file = stepFolder(1, session.folder).appendingPathComponent("screenshot.png")
  #expect(try Data(contentsOf: file) == taken, "and the picture is the one the Mac took")
  #expect(
    try filesOfTheLastCommit(in: session.folder, with: git)
      .contains("steps/000001/screenshot.png"),
    "the commit of the step carries it, so the history holds the picture and not the disk alone")
}

/// A command that Logic died in asks for no picture. There is no window of Logic left to
/// photograph, and the run must not wait on a Mac for a picture of a window that went away.
@Test func aCommandThatLogicDiedInTakesNoPicture() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let recorded = aProjectWithOneTrack()
  let session = try SessionRepository.start(
    session: aSession(), root: root, state: recorded, git: git)
  let driver = FakeLogicDriver(state: recorded, path: projectPath)
  let capturer = ACaptureThatCounts()

  let answer = Run(driver: driver, root: root, version: "0.1.0", git: git, capturer: capturer)
    .run(command: SetTheTempoAndDie())

  #expect(answer.error?.code == .logicCrashed)
  #expect(capturer.asked == 0, "no window of Logic was left to take a picture of")

  let step = try record(ofStep: 1, in: session.folder)
  #expect(step["screenshot"] is NSNull, "so the step carries no picture")
  let said = try #require(reasonForNoPicture(in: answer.meta), "and meta says why there is none")
  #expect(said.isEmpty == false)
}
