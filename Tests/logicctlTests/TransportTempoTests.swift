import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// A folder no other test writes into, for one part of the scenario.
private func aFolderOfItsOwn() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-tempo-\(UUID().uuidString)")
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

/// Where the project of this scenario sits.
private let projectPath = "/Users/someone/Music/Sketch.logicx"

/// The tempo every project of this scenario starts at, which is what Logic gives a new one.
private let tempoAtTheStart = 120

/// The tempo the person asks for.
private let tempoAsked = 96

/// How long Logic is given to reach the tempo, in milliseconds.
private let theLimit = 2000

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class TempoTime {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// What one move of the tempo display was.
private enum Move: Equatable {
  /// One `AXIncrement` or `AXDecrement`, which Logic moves by ten.
  case step(SliderStepper.LargeStep)

  /// One write of a number, which Logic moves by one toward that number.
  case write(Int)
}

/// The tempo display of Logic 12.3.1, and the project behind it.
///
/// Measured on Logic 12.3.1 on a copy, on 2026-09-25: one `AXIncrement` or `AXDecrement` moves the
/// display by ten, and a write of a number moves it one step toward that number and no further. A
/// write of 96 from 120 gave 119, and a write of 200 from 119 gave 120. The display here answers
/// the same way, so a command that wrote once and reported the number it wrote is caught here
/// rather than on a person's project.
///
/// The display and the state are the same tempo, as they are in Logic: the slider is what the
/// Control Bar shows, and the project carries what the slider reached.
private final class ATempoDisplay {
  /// What the display shows now.
  private(set) var showing: Int

  /// Every move the command made, in the order it made them.
  private(set) var moves: [Move] = []

  /// The Logic whose project follows the display, or none when the display moves on its own.
  private let carriedBy: FakeLogicDriver?

  /// Whether the display takes the moves at all. A display that is stuck answers every move and
  /// stays where it is, which is the Logic that refuses what the command has to give it.
  private let stuck: Bool

  init(at tempo: Int, carriedBy: FakeLogicDriver? = nil, stuck: Bool = false) {
    showing = tempo
    self.carriedBy = carriedBy
    self.stuck = stuck
    carriedBy?.state?.transport.tempo = Double(tempo)
  }

  /// The display the command is given.
  var field: TempoField {
    TempoField(
      read: { self.showing },
      write: { asked in
        self.moves.append(.write(asked))
        self.move(by: asked > self.showing ? 1 : (asked < self.showing ? -1 : 0))
      },
      act: { step in
        self.moves.append(.step(step))
        self.move(by: step == .up ? SliderStepper.stepOfAnAction : -SliderStepper.stepOfAnAction)
      })
  }

  /// Moves the display, and the project with it.
  private func move(by span: Int) {
    guard !stuck else {
      return
    }
    showing += span
    carriedBy?.state?.transport.tempo = Double(showing)
  }
}

/// The project Logic has open: one software instrument track, and the tempo of a new project.
private func aProject() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Sketch"),
    transport: Transport(playing: false, recording: false, tempo: Double(tempoAtTheStart)),
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

/// The subjects of every commit of a session, newest first.
private func subjects(of folder: URL, with git: Git) throws -> [String] {
  try git.run(["log", "--format=%s"], in: folder)
    .split(separator: "\n", omittingEmptySubsequences: true)
    .map(String.init)
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

/// A person or an agent sets the tempo, and then plays a part against it.
///
/// The number in the answer has to be the number the project carries, because that is what every
/// note after it is played against. The tempo display of Logic takes no number in one go: a write
/// moves it one step and no further, so a command that wrote 96 once and printed 96 would leave
/// the project at 119 and report 96. The person hears that only after the take is recorded, and by
/// then the performance is gone. So the display is moved a step at a time and read back after each
/// move, and the number in the answer is read from the project once the move is done.
///
/// Five things can happen, and each one is answered on its own terms. The tempo is reached, and
/// the answer carries what the project holds. The tempo is outside what Logic carries, so the
/// command stops before it reads Logic at all and the project keeps the tempo it had. The display
/// takes the moves and never changes, so the command fails with the number it asked for and the
/// number it read. The display reaches the number and the project does not follow, so the command
/// gives up at its limit rather than printing what the control shows. The project belongs to a
/// person, so the command refuses until they say `--confirm`.
///
/// One tempo is one step of the session, so a person reads what logicctl set and a replay sets it
/// again.
@Test func tempoReadsTheNewTempoBack() throws {
  let logic = try aLogic()
  let stuck = try aLogic()
  let alone = try aLogic()
  let theirs = try aLogic(madeByLogicctl: false)
  defer {
    for folder in [logic.root, stuck.root, alone.root, theirs.root] {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  let typed = try Logicctl.parseAsRoot(["transport", "tempo", "96"])
  #expect(typed is TransportCommand.Tempo, "the noun and the verb of the design system")
  #expect(
    logic.driver.state?.transport.tempo == Double(tempoAtTheStart),
    "the project carries the tempo of a new project before the command runs")

  let display = ATempoDisplay(at: tempoAtTheStart, carriedBy: logic.driver)
  let answer = Printed()
  let time = TempoTime()

  let status = TransportCommand.Tempo.answer(
    driver: logic.driver,
    field: display.field,
    tempo: tempoAsked,
    confirmed: false,
    root: logic.root,
    version: "0.1.0",
    limitMs: theLimit,
    argv: ["96"],
    clock: time.read,
    sleeper: time.sleep,
    git: logic.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 0, "Logic reached the tempo")
  let printed = try answer.json()
  #expect(printed["error"] is NSNull, "nothing failed")
  #expect(try answer.data()?["tempo"] as? Int == tempoAsked, "the tempo Logic shows")
  #expect(try answer.data()?.keys.sorted() == ["tempo"], "and nothing else")
  #expect(
    logic.driver.state?.transport.tempo == Double(tempoAsked),
    "the project carries the tempo, which is what a part is played against")
  #expect(answer.out.contains("\"tempo\":96"), "a whole number, not 96.0")
  #expect(answer.err.isEmpty, "standard error is empty on success")
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and one newline")

  #expect(
    display.moves == [
      .step(.down), .step(.down), .write(96), .write(96), .write(96), .write(96),
    ],
    "a step of ten while the distance is ten or more, then one write for each step that is left")
  #expect(display.showing == tempoAsked, "the display stopped at the tempo and went no further")

  let meta = try answer.meta()
  #expect(meta["session"] as? String == logic.session.session.id)
  let commit = try #require(meta["step"] as? String, "the tempo is in the record")
  #expect(!commit.isEmpty)
  #expect(
    try subjects(of: logic.session.folder, with: logic.git) == [
      "1 transport tempo", "session \(logic.session.session.shortId)",
    ],
    "the tempo the command set is one step of the session")
  let step = try record(ofStep: 1, in: logic.session.folder)
  #expect(step["command"] as? String == "transport tempo")
  #expect(step["argv"] as? [String] == ["96"], "the tempo a person typed")
  #expect(step["exitCode"] as? Int == 0)

  // A tempo Logic does not carry. The command stops where the arguments are read, so nothing
  // reaches Logic and no project changes.
  let refused = Printed()

  let stopped = Logicctl.run(
    arguments: ["transport", "tempo", "5"],
    standardOutput: refused.write,
    standardError: refused.writeError)

  #expect(stopped == 2, "the number the design system gives invalid_argument")
  #expect(try refused.failureCode() == "invalid_argument", "5 is no tempo of Logic")
  #expect(try refused.json()["data"] is NSNull, "a refusal carries no answer")
  #expect(try refused.meta()["session"] is NSNull, "Logic was never asked")
  #expect(try refused.meta()["step"] is NSNull, "so the session gained no step")
  #expect(refused.err.hasPrefix("logicctl: invalid_argument: "), "one line for the person")

  // The display takes every move and stays where it is, which is the Logic that refuses what the
  // command has to give it. The command says how far it got, rather than reporting the tempo.
  let stiff = ATempoDisplay(at: tempoAtTheStart, carriedBy: stuck.driver, stuck: true)
  let gaveUp = Printed()
  let waited = TempoTime()

  let neverMoved = TransportCommand.Tempo.answer(
    driver: stuck.driver,
    field: stiff.field,
    tempo: tempoAsked,
    confirmed: false,
    root: stuck.root,
    version: "0.1.0",
    limitMs: theLimit,
    argv: ["96"],
    clock: waited.read,
    sleeper: waited.sleep,
    git: stuck.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: gaveUp.write,
    standardError: gaveUp.writeError)

  #expect(neverMoved == 5, "the number the design system gives element_not_found")
  #expect(try gaveUp.failureCode() == "element_not_found", "the display did not take the tempo")
  #expect(try gaveUp.failureDetails()["asked"] as? Int == tempoAsked, "what it was asked for")
  #expect(
    try gaveUp.failureDetails()["read"] as? Int == tempoAtTheStart, "and what it kept reading")
  #expect(try gaveUp.json()["data"] is NSNull, "no tempo is made up for a display that is stuck")
  #expect(
    stuck.driver.state?.transport.tempo == Double(tempoAtTheStart), "the project is as it was")
  #expect(
    try record(ofStep: 1, in: stuck.session.folder)["exitCode"] as? Int == 5,
    "the step records what the command answered")

  // The display answers every move and the project does not follow. The number in the answer is
  // read from the project and never from the control logicctl drove, so the command gives up at
  // its limit rather than printing the tempo the display shows.
  let ownWay = ATempoDisplay(at: tempoAtTheStart)
  let lost = Printed()
  let counted = TempoTime()

  let neverArrived = TransportCommand.Tempo.answer(
    driver: alone.driver,
    field: ownWay.field,
    tempo: tempoAsked,
    confirmed: false,
    root: alone.root,
    version: "0.1.0",
    limitMs: theLimit,
    argv: ["96"],
    clock: counted.read,
    sleeper: counted.sleep,
    git: alone.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: lost.write,
    standardError: lost.writeError)

  #expect(neverArrived == 6, "the number the design system gives timeout")
  #expect(try lost.failureCode() == "timeout", "the project never took the tempo")
  #expect(try lost.failureDetails()["waitedMs"] as? Int == theLimit, "how long Logic was given")
  #expect(try lost.json()["data"] is NSNull, "no tempo is read off the control that was driven")
  #expect(ownWay.showing == tempoAsked, "the display reached the number, and it was not enough")
  #expect(
    alone.driver.state?.transport.tempo == Double(tempoAtTheStart),
    "the project is what the answer is about")

  // The project belongs to a person. The tempo is part of their project, so the command changes
  // nothing until they say --confirm.
  let guarded = Printed()
  let ofTheirs = ATempoDisplay(at: tempoAtTheStart, carriedBy: theirs.driver)

  let refusedTheirs = TransportCommand.Tempo.answer(
    driver: theirs.driver,
    field: ofTheirs.field,
    tempo: tempoAsked,
    confirmed: false,
    root: theirs.root,
    version: "0.1.0",
    limitMs: theLimit,
    argv: ["96"],
    clock: TempoTime().read,
    sleeper: { _ in },
    git: theirs.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: guarded.write,
    standardError: guarded.writeError)

  #expect(refusedTheirs == 7, "the number the design system gives confirm_required")
  #expect(try guarded.failureCode() == "confirm_required", "logicctl did not make this project")
  #expect(ofTheirs.moves.isEmpty, "the display was not touched")
  #expect(
    theirs.driver.state?.transport.tempo == Double(tempoAtTheStart), "their tempo is as it was")

  let saidYes = Printed()

  let wentAhead = TransportCommand.Tempo.answer(
    driver: theirs.driver,
    field: ofTheirs.field,
    tempo: tempoAsked,
    confirmed: true,
    root: theirs.root,
    version: "0.1.0",
    limitMs: theLimit,
    argv: ["96", "--confirm"],
    clock: TempoTime().read,
    sleeper: { _ in },
    git: theirs.git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: saidYes.write,
    standardError: saidYes.writeError)

  #expect(wentAhead == 0, "--confirm is the way past the guard")
  #expect(try saidYes.data()?["tempo"] as? Int == tempoAsked, "and the tempo of their project")
}

/// The walk to the tempo display, proved against the trees `inspect` recorded from Logic 12.3.1.
///
/// The pipeline has no Logic, so this is what says the command is aimed at the right element. The
/// display carries no identifier and no title, so the path names its role and its place, and a
/// path that matches two elements is refused rather than taking the first.
@Test func theTempoFieldIsTheSliderOfTheControlBar() throws {
  let folder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

  for file in ["empty.json", "one-track.json", "region.json"] {
    let tree = try RecordedTree(contentsOf: folder.appending(path: file))
    let found = try LocatorResolver.element(of: TempoField.tempoSlider, in: tree.root)

    #expect(found.role == "AXSlider", "the tempo is a slider and not a text field, in \(file)")
    #expect(found.description == "Tempo", "and it is the one Logic calls Tempo, in \(file)")
    #expect(
      found.actions.contains("AXIncrement") && found.actions.contains("AXDecrement"),
      "the two steps of ten the move is made of, in \(file)")
    #expect(Int(found.value ?? "") == tempoAtTheStart, "the recorded projects sit at 120")
  }
}
