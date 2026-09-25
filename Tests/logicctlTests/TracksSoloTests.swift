import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// The version of Logic the recorded tree came from.
private let soloRecordedVersion = "12.3.1"

/// Where the recorded trees sit. They are read from the source tree, because the folder sits
/// beside the test targets rather than inside one.
private let soloRecordedTrees = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(soloRecordedVersion)")

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class SoloTime {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// What one run of the command wrote, on each channel, and the number it exited with.
private final class SoloAnswer {
  var out = ""
  var err = ""
  var status: Int32 = 0

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

  /// The row the answer carries under `data.track`.
  func row() throws -> [String: Any] {
    let data = try printed()["data"] as? [String: Any] ?? [:]
    return data["track"] as? [String: Any] ?? [:]
  }

  /// The code of the failure the answer carries, or nil when it carries none.
  func failureCode() throws -> String? {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["code"] as? String
  }

  /// What the failure says, or nil when it carries none.
  func failureMessage() throws -> String? {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["message"] as? String
  }

  /// What the failure says in `details`, or an empty object when it says nothing.
  func failureDetails() throws -> [String: Any] {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["details"] as? [String: Any] ?? [:]
  }
}

/// Every press that reached the window of Logic, in the order it reached it.
private final class SoloButtons {
  var pressed: [Locator] = []

  /// The name of the control the last press went to.
  var lastLocatorName: String? {
    pressed.last?.name
  }
}

/// A folder that carries no session, so nothing of a run reaches the disk.
private func noSoloSessionFolder() -> URL {
  URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "logicctl-no-session")
}

/// A project that holds these tracks, open in Logic, saved nowhere.
private func aLogicHoldingTheseTracks(_ tracks: [Track]) -> FakeLogicDriver {
  FakeLogicDriver(tracks: tracks)
}

/// Runs `logicctl tracks solo` against a Logic that holds these tracks.
///
/// The words go through the parser of the subcommand first, exactly as a command line does, so a
/// line that gives neither `--on` nor `--off` is refused there and the Logic below is never asked
/// anything. The press is what Logic does when the solo button of a track header is pressed, so a
/// test says what its Logic makes of it.
private func tracksSolo(
  _ line: [String],
  driver: FakeLogicDriver,
  buttons: SoloButtons,
  root: URL? = nil,
  press: @escaping (FakeLogicDriver) -> Void
) -> SoloAnswer {
  let answer = SoloAnswer()
  let time = SoloTime()
  do {
    let command = try Tracks.Solo.parse(line)
    let actions = TrackActions(pressInWindow: { locator in
      buttons.pressed.append(locator)
      press(driver)
    })
    answer.status = Tracks.Solo.answer(
      driver: driver,
      actions: actions,
      index: command.track.index,
      soloed: try command.soloing.state(),
      confirmed: command.guarded.confirm,
      root: root ?? noSoloSessionFolder(),
      limitMs: 50,
      argv: line,
      clock: time.read,
      sleeper: time.sleep,
      standardOutput: answer.write,
      standardError: answer.writeError)
  } catch {
    answer.status = Logicctl.report(
      error,
      arguments: line,
      standardOutput: answer.write,
      standardError: answer.writeError)
  }
  return answer
}

/// The Logic of a test turns the solo of the track at that number over, the way a check box does.
///
/// The button carries one action in the tree Logic 12.3.1 answers, and that action is a press, so
/// there is no way to ask Logic for a state. A press on a soloed track takes the solo off it.
private func aLogicWhoseSoloButtonTurnsOver(atIndex index: Int) -> (FakeLogicDriver) -> Void {
  { fake in
    guard let place = fake.state?.tracks.firstIndex(where: { $0.index == index }) else {
      return
    }
    fake.state?.tracks[place].solo.toggle()
  }
}

/// A person or an agent takes the solo off a track that Logic is soloing, and the whole project is
/// heard again.
///
/// The one row that comes back is the whole of what they get to read, so it says what Logic shows
/// and not what the flag asked for. A command that printed the flag back would report a solo that
/// Logic refused, and every later command would work from a state the project does not hold. Here
/// the state the person asked for is the state the answer carries, so an agent reads the row and
/// knows the project.
@Test func soloOffClearsSolo() throws {
  let driver = aLogicHoldingTheseTracks([Track(index: 1, name: "Bass", type: .other, solo: true)])
  let buttons = SoloButtons()

  let answer = tracksSolo(
    ["--index", "1", "--off"],
    driver: driver,
    buttons: buttons,
    press: aLogicWhoseSoloButtonTurnsOver(atIndex: 1))

  #expect(answer.status == 0, "the command worked")
  #expect(try answer.printed()["error"] is NSNull, "so it carries no failure")
  #expect(answer.err == "", "and standard error stays empty")

  let row = try answer.row()
  #expect(row["index"] as? Int == 1, "the track the person named")
  #expect(row["name"] as? String == "Bass", "which keeps its name")
  #expect(row["solo"] as? Bool == false, "and is soloed no longer")
  #expect(row["mute"] as? Bool == false, "a solo leaves the mute button alone")
  #expect(row["arm"] as? Bool == false, "and the record enable button")
  #expect(driver.state?.tracks.first?.solo == false, "the project holds a track that is not soloed")
  #expect(buttons.pressed.count == 1, "the button was pressed once")
}

/// A person or an agent says a track must be soloed, and it is soloed, however many times they ask.
///
/// The solo button of Logic is a check box: one press turns it over. So a command that pressed
/// every time would solo the track on the first call and unsolo it on the second, and a script that
/// ran twice would leave the project in the state it was asked to leave. Here the state is set. The
/// second call reads the track, sees the state that was asked for, presses nothing, and prints the
/// same row.
@Test func soloOnTwiceStaysOn() throws {
  let driver = aLogicHoldingTheseTracks([Track(index: 1, name: "Bass", type: .other)])
  let buttons = SoloButtons()

  let first = tracksSolo(
    ["--index", "1", "--on"],
    driver: driver,
    buttons: buttons,
    press: aLogicWhoseSoloButtonTurnsOver(atIndex: 1))

  #expect(first.status == 0, "the first call worked")
  #expect(try first.row()["solo"] as? Bool == true, "the track is soloed")

  let second = tracksSolo(
    ["--index", "1", "--on"],
    driver: driver,
    buttons: buttons,
    press: aLogicWhoseSoloButtonTurnsOver(atIndex: 1))

  #expect(second.status == 0, "the second call worked")
  #expect(try second.row()["solo"] as? Bool == true, "and the track is soloed still")
  #expect(driver.state?.tracks.first?.solo == true, "the project holds a soloed track")
  #expect(buttons.pressed.count == 1, "the button was pressed once, by the call that needed it")
  #expect(second.out.filter(\.isNewline).count == 1, "one JSON object and a newline")
}

/// A person or an agent gives neither `--on` nor `--off`, or gives both.
///
/// A state is set and never turned over, so the flags are the whole of what the person asks for.
/// Neither of them leaves the wish unknown and both of them ask for two things at once. The refusal
/// happens where the arguments are read, so Logic is never asked anything, the project is
/// untouched, and the journal gains no step for a line that was typed by mistake.
@Test func soloingWithNeitherFlagOrWithBothStopsBeforeLogic() throws {
  for line in [["--index", "1"], ["--index", "1", "--on", "--off"]] {
    let driver = aLogicHoldingTheseTracks([Track(index: 1, name: "Bass", type: .other)])
    let buttons = SoloButtons()

    let answer = tracksSolo(
      line,
      driver: driver,
      buttons: buttons,
      press: aLogicWhoseSoloButtonTurnsOver(atIndex: 1))

    #expect(answer.status == 2, "the number the design system gives invalid_argument")
    #expect(try answer.failureCode() == "invalid_argument", "the arguments were wrong")
    #expect(buttons.pressed.isEmpty, "nothing in Logic was pressed")
    #expect(driver.state?.tracks.first?.solo == false, "the project is as it was")

    let printed = try answer.printed()
    let meta = printed["meta"] as? [String: Any]
    #expect(meta?["session"] is NSNull, "Logic was never asked, so no session was opened")
    #expect(meta?["step"] is NSNull, "and no step was written")
  }
}

/// A person or an agent names a track the project does not have.
///
/// The refusal comes before anything is pressed, so the project is as it was, and the answer names
/// the number that was asked for. An agent reads `track_not_found`, exit 10 and the index, lists
/// the tracks, and asks again.
@Test func anIndexThatNamesNoTrackFailsBeforeTheSoloButtonIsPressed() throws {
  let driver = aLogicHoldingTheseTracks([Track(index: 1, name: "Bass", type: .other)])
  let buttons = SoloButtons()

  let answer = tracksSolo(
    ["--index", "9", "--on"],
    driver: driver,
    buttons: buttons,
    press: aLogicWhoseSoloButtonTurnsOver(atIndex: 9))

  #expect(answer.status == 10, "the number the design system gives track_not_found")
  #expect(try answer.failureCode() == "track_not_found", "the project has no track 9")
  #expect(try answer.failureMessage() == "No track at index 9", "and the answer says so")
  #expect(try answer.failureDetails()["index"] as? Int == 9, "the answer names the number asked")
  #expect(try answer.printed()["data"] is NSNull, "a refusal carries no answer")
  #expect(buttons.pressed.isEmpty, "nothing in Logic was pressed")
  #expect(driver.state?.tracks.first?.solo == false, "the project is as it was")
}

/// Logic takes the press and the solo state does not change.
///
/// The read back is the whole of the evidence that the press did what it was asked to do. A command
/// that printed a row here would report a solo that Logic refused, and every later command that
/// trusted the row would work from a state the project does not hold. It gives up at the limit
/// instead, with `timeout`, and it says how long it gave Logic, so a person runs it again with a
/// longer `--timeout`.
@Test func aSoloPressThatChangedNoStateFailsWithTimeout() throws {
  let driver = aLogicHoldingTheseTracks([Track(index: 1, name: "Bass", type: .other)])
  let buttons = SoloButtons()

  let answer = tracksSolo(
    ["--index", "1", "--on"],
    driver: driver,
    buttons: buttons
  ) { _ in }

  #expect(answer.status == 6, "the number the design system gives timeout")
  #expect(try answer.failureCode() == "timeout", "Logic did not show the state that was asked for")
  #expect(try answer.failureDetails()["waitedMs"] as? Int == 50, "how long Logic was given")
  #expect(buttons.pressed.count == 1, "the button was pressed once, and once only")
  #expect(driver.state?.tracks.first?.solo == false, "the track is not soloed, as it was")
}

/// The press goes to the solo button of the header of the track the person named.
///
/// The number a person types counts from 1 and a track header counts from 0, so a command that
/// passed the number straight through would solo the track under the one that was asked for.
@Test func thePressGoesToTheSoloButtonOfTheTrackThatWasNamed() throws {
  let driver = aLogicHoldingTheseTracks([
    Track(index: 1, name: "Bass", type: .other),
    Track(index: 2, name: "Drums", type: .other),
  ])
  let buttons = SoloButtons()

  let answer = tracksSolo(
    ["--index", "2", "--on"],
    driver: driver,
    buttons: buttons,
    press: aLogicWhoseSoloButtonTurnsOver(atIndex: 2))

  #expect(answer.status == 0, "the command worked")
  #expect(
    buttons.lastLocatorName == Locators.trackSoloButton(number: 1).name,
    "the solo button of the second track header, which counts from 0")
  #expect(driver.state?.tracks.first?.solo == false, "the first track is not soloed")
  #expect(try answer.row()["index"] as? Int == 2, "the row is the track that was named")
  #expect(try answer.row()["solo"] as? Bool == true, "with the state Logic shows now")
}

/// The button the solo presses is the button the state is read from.
///
/// Both walks are `Locators.trackSoloButton`, put here to the tree that `inspect` recorded from
/// Logic 12.3.1. The tree says what the live route is up against: the control is a check box whose
/// one action is a press, so there is no way to ask Logic for a state and the press turns the state
/// over. That is why the command reads before it presses.
@Test func theSoloWritesToTheButtonTheStateIsReadFrom() throws {
  let recorded = try RecordedTree(
    contentsOf: soloRecordedTrees.appending(path: "one-track.json"))

  let button = try LocatorResolver.element(
    of: Locators.trackSoloButton(number: 0), in: recorded.root)
  let tracks = try TrackReader.tracks(in: recorded.root)

  #expect(button.role == "AXCheckBox", "the solo button of the track header")
  #expect(button.description == "Solo", "Logic says so in the description")
  #expect(button.actions == ["AXPress"], "and the one action Logic offers on it is a press")
  #expect(button.value == "0", "the value says the track is not soloed")
  #expect(tracks.first?.solo == false, "which is what the reader answers")
}

/// A person opens a project they wrote themselves, and an agent asks logicctl to solo a track.
///
/// The work in that project is theirs, so logicctl does not change it on its own word. The agent
/// reads `confirm_required` and exit 7, nothing is pressed, and the project is as the person left
/// it. The person then says `--confirm`, and the same command goes through.
@Test func soloingATrackInAProjectLogicctlDidNotMakeNeedsConfirm() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-solo-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let driver = FakeLogicDriver(
    tracks: [Track(index: 1, name: "Bass", type: .other)],
    project: "Their Sketch",
    path: "/Users/someone/Music/Their Sketch.logicx")
  let buttons = SoloButtons()

  let answer = tracksSolo(
    ["--index", "1", "--on"],
    driver: driver,
    buttons: buttons,
    root: root,
    press: aLogicWhoseSoloButtonTurnsOver(atIndex: 1))

  #expect(answer.status == 7, "the number the design system gives confirm_required")
  #expect(try answer.failureCode() == "confirm_required", "logicctl did not make this project")
  #expect(buttons.pressed.isEmpty, "nothing in Logic was pressed")
  #expect(driver.state?.tracks.first?.solo == false, "the project of the person holds")
}
