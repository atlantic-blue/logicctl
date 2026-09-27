import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// The version of Logic the recorded tree came from.
private let muteRecordedVersion = "12.3.1"

/// Where the recorded trees sit. They are read from the source tree, because the folder sits
/// beside the test targets rather than inside one.
private let muteRecordedTrees = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(muteRecordedVersion)")

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class MuteTime {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// What one run of the command wrote, on each channel, and the number it exited with.
private final class MuteAnswer {
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
private final class Buttons {
  var pressed: [Locator] = []

  /// The name of the control the last press went to.
  var lastLocatorName: String? {
    pressed.last?.name
  }
}

/// A folder that carries no session, so nothing of a run reaches the disk.
private func noSessionFolder() -> URL {
  URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "logicctl-no-session")
}

/// A project that holds these tracks, open in Logic, saved nowhere.
private func aLogicHoldingTracks(_ tracks: [Track]) -> FakeLogicDriver {
  FakeLogicDriver(tracks: tracks)
}

/// Runs `logicctl tracks mute` against a Logic that holds these tracks.
///
/// The words go through the parser of the subcommand first, exactly as a command line does, so a
/// line that gives neither `--on` nor `--off` is refused there and the Logic below is never asked
/// anything. The press is what Logic does when the mute button of a track header is pressed, so a
/// test says what its Logic makes of it.
private func tracksMute(
  _ line: [String],
  driver: FakeLogicDriver,
  buttons: Buttons,
  root: URL? = nil,
  press: @escaping (FakeLogicDriver) -> Void
) -> MuteAnswer {
  let answer = MuteAnswer()
  let time = MuteTime()
  do {
    let command = try Tracks.Mute.parse(line)
    let actions = TrackActions(click: { locator in
      buttons.pressed.append(locator)
      press(driver)
    })
    answer.status = Tracks.Mute.answer(
      driver: driver,
      actions: actions,
      index: command.track.index,
      muted: try command.muting.state(),
      confirmed: command.guarded.confirm,
      root: root ?? noSessionFolder(),
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

/// The Logic of a test turns the mute of the track at that number over, the way a check box does.
///
/// The button carries one action in the tree Logic 12.3.1 answers, and that action is a press, so
/// there is no way to ask Logic for a state. A press on a muted track unmutes it.
private func aLogicWhoseMuteButtonTurnsOver(atIndex index: Int) -> (FakeLogicDriver) -> Void {
  { fake in
    guard let place = fake.state?.tracks.firstIndex(where: { $0.index == index }) else {
      return
    }
    fake.state?.tracks[place].mute.toggle()
  }
}

/// A person or an agent says a track must be muted, and it is muted, however many times they ask.
///
/// The mute button of Logic is a check box: one press turns it over. So a command that pressed
/// every time would mute the track on the first call and unmute it on the second, and a script
/// that ran twice would leave the project in the state it was asked to leave. Here the state is
/// set. The second call reads the track, sees the state that was asked for, presses nothing, and
/// prints the same row. An agent asks for a state and gets it, with no read of its own first, and
/// a replay of a session gives what the session gave.
@Test func muteOnTwiceStaysOn() throws {
  let driver = aLogicHoldingTracks([Track(index: 1, name: "Bass", type: .other)])
  let buttons = Buttons()

  let first = tracksMute(
    ["--index", "1", "--on"],
    driver: driver,
    buttons: buttons,
    press: aLogicWhoseMuteButtonTurnsOver(atIndex: 1))

  #expect(first.status == 0, "the first call worked")
  #expect(try first.row()["mute"] as? Bool == true, "the track is muted")

  let second = tracksMute(
    ["--index", "1", "--on"],
    driver: driver,
    buttons: buttons,
    press: aLogicWhoseMuteButtonTurnsOver(atIndex: 1))

  #expect(second.status == 0, "the second call worked")
  #expect(try second.printed()["error"] is NSNull, "so it carries no failure")
  #expect(second.err == "", "and standard error stays empty")
  #expect(try second.row()["mute"] as? Bool == true, "and the track is muted still")
  #expect(driver.state?.tracks.first?.mute == true, "the project holds a muted track")
  #expect(buttons.pressed.count == 1, "the button was pressed once, by the call that needed it")
  #expect(second.out.filter(\.isNewline).count == 1, "one JSON object and a newline")
}

/// A person or an agent says a muted track must be heard again.
///
/// The row carries the state Logic shows after the press and not the flag, so the one answer says
/// the track is heard rather than that it was asked to be.
@Test func muteOffClearsMuteOnAMutedTrack() throws {
  let driver = aLogicHoldingTracks([Track(index: 1, name: "Bass", type: .other, mute: true)])
  let buttons = Buttons()

  let answer = tracksMute(
    ["--index", "1", "--off"],
    driver: driver,
    buttons: buttons,
    press: aLogicWhoseMuteButtonTurnsOver(atIndex: 1))

  #expect(answer.status == 0, "the command worked")
  #expect(try answer.printed()["error"] is NSNull, "so it carries no failure")

  let row = try answer.row()
  #expect(row["index"] as? Int == 1, "the track the person named")
  #expect(row["name"] as? String == "Bass", "which keeps its name")
  #expect(row["mute"] as? Bool == false, "and is heard again")
  #expect(row["solo"] as? Bool == false, "a mute leaves the solo button alone")
  #expect(row["arm"] as? Bool == false, "and the record enable button")
  #expect(buttons.pressed.count == 1, "the button was pressed once")
  #expect(driver.state?.tracks.first?.mute == false, "the project holds a track that is heard")
}

/// A person or an agent gives neither `--on` nor `--off`, or gives both.
///
/// A state is set and never turned over, so the flags are the whole of what the person asks for.
/// Neither of them leaves the wish unknown and both of them ask for two things at once. The
/// refusal happens where the arguments are read, so Logic is never asked anything, the project is
/// untouched, and the journal gains no step for a line that was typed by mistake.
@Test func mutingWithNeitherFlagOrWithBothStopsBeforeLogic() throws {
  for line in [["--index", "1"], ["--index", "1", "--on", "--off"]] {
    let driver = aLogicHoldingTracks([Track(index: 1, name: "Bass", type: .other)])
    let buttons = Buttons()

    let answer = tracksMute(
      line,
      driver: driver,
      buttons: buttons,
      press: aLogicWhoseMuteButtonTurnsOver(atIndex: 1))

    #expect(answer.status == 2, "the number the design system gives invalid_argument")
    #expect(try answer.failureCode() == "invalid_argument", "the arguments were wrong")
    #expect(buttons.pressed.isEmpty, "nothing in Logic was pressed")
    #expect(driver.state?.tracks.first?.mute == false, "the project is as it was")

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
@Test func anIndexThatNamesNoTrackFailsBeforeAnythingIsPressed() throws {
  let driver = aLogicHoldingTracks([Track(index: 1, name: "Bass", type: .other)])
  let buttons = Buttons()

  let answer = tracksMute(
    ["--index", "9", "--on"],
    driver: driver,
    buttons: buttons,
    press: aLogicWhoseMuteButtonTurnsOver(atIndex: 9))

  #expect(answer.status == 10, "the number the design system gives track_not_found")
  #expect(try answer.failureCode() == "track_not_found", "the project has no track 9")
  #expect(try answer.failureMessage() == "No track at index 9", "and the answer says so")
  #expect(try answer.failureDetails()["index"] as? Int == 9, "the answer names the number asked")
  #expect(try answer.printed()["data"] is NSNull, "a refusal carries no answer")
  #expect(buttons.pressed.isEmpty, "nothing in Logic was pressed")
  #expect(driver.state?.tracks.first?.mute == false, "the project is as it was")
}

/// Logic takes the press and the mute state does not change.
///
/// The read back is the whole of the evidence that the press did what it was asked to do. A
/// command that printed a row here would report a mute that Logic refused, and every later
/// command that trusted the row would work from a state the project does not hold. It gives up at
/// the limit instead, with `timeout`, and it says how long it gave Logic, so a person runs it
/// again with a longer `--timeout`.
@Test func aPressThatChangedNoStateFailsWithTimeout() throws {
  let driver = aLogicHoldingTracks([Track(index: 1, name: "Bass", type: .other)])
  let buttons = Buttons()

  let answer = tracksMute(
    ["--index", "1", "--on"],
    driver: driver,
    buttons: buttons
  ) { _ in }

  #expect(answer.status == 6, "the number the design system gives timeout")
  #expect(try answer.failureCode() == "timeout", "Logic did not show the state that was asked for")
  #expect(try answer.failureDetails()["waitedMs"] as? Int == 50, "how long Logic was given")
  #expect(buttons.pressed.count == 1, "the button was pressed once, and once only")
  #expect(driver.state?.tracks.first?.mute == false, "the track is heard, as it was")
}

/// The press goes to the mute button of the header of the track the person named.
///
/// The number a person types counts from 1 and a track header counts from 0, so a command that
/// passed the number straight through would mute the track under the one that was asked for.
@Test func thePressGoesToTheMuteButtonOfTheTrackThatWasNamed() throws {
  let driver = aLogicHoldingTracks([
    Track(index: 1, name: "Bass", type: .other),
    Track(index: 2, name: "Drums", type: .other),
  ])
  let buttons = Buttons()

  let answer = tracksMute(
    ["--index", "2", "--on"],
    driver: driver,
    buttons: buttons,
    press: aLogicWhoseMuteButtonTurnsOver(atIndex: 2))

  #expect(answer.status == 0, "the command worked")
  #expect(
    buttons.lastLocatorName == Locators.trackMuteButton(number: 1).name,
    "the mute button of the second track header, which counts from 0")
  #expect(driver.state?.tracks.first?.mute == false, "the first track is heard")
  #expect(try answer.row()["index"] as? Int == 2, "the row is the track that was named")
  #expect(try answer.row()["mute"] as? Bool == true, "with the state Logic shows now")
}

/// The button the mute presses is the button the state is read from.
///
/// Both walks are `Locators.trackMuteButton`, put here to the tree that `inspect` recorded from
/// Logic 12.3.1. The tree says what the live route is up against: the control is a check box whose
/// one action is a press, so there is no way to ask Logic for a state and the press turns the
/// state over. That is why the command reads before it presses.
@Test func theMuteWritesToTheButtonTheStateIsReadFrom() throws {
  let recorded = try RecordedTree(
    contentsOf: muteRecordedTrees.appending(path: "one-track.json"))

  let button = try LocatorResolver.element(
    of: Locators.trackMuteButton(number: 0), in: recorded.root)
  let tracks = try TrackReader.tracks(in: recorded.root)

  #expect(button.role == "AXCheckBox", "the mute button of the track header")
  #expect(button.description == "Mute", "Logic says so in the description")
  #expect(button.actions == ["AXPress"], "and the one action Logic offers on it is a press")
  #expect(button.value == "0", "the value says the track is heard")
  #expect(tracks.first?.mute == false, "which is what the reader answers")
}

/// A person opens a project they wrote themselves, and an agent asks logicctl to mute a track.
///
/// The work in that project is theirs, so logicctl does not change it on its own word. The agent
/// reads `confirm_required` and exit 7, nothing is pressed, and the project is as the person left
/// it. The person then says `--confirm`, and the same command goes through.
@Test func mutingATrackInAProjectLogicctlDidNotMakeNeedsConfirm() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-mute-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let driver = FakeLogicDriver(
    tracks: [Track(index: 1, name: "Bass", type: .other)],
    project: "Their Sketch",
    path: "/Users/someone/Music/Their Sketch.logicx")
  let buttons = Buttons()

  let answer = tracksMute(
    ["--index", "1", "--on"],
    driver: driver,
    buttons: buttons,
    root: root,
    press: aLogicWhoseMuteButtonTurnsOver(atIndex: 1))

  #expect(answer.status == 7, "the number the design system gives confirm_required")
  #expect(try answer.failureCode() == "confirm_required", "logicctl did not make this project")
  #expect(buttons.pressed.isEmpty, "nothing in Logic was pressed")
  #expect(driver.state?.tracks.first?.mute == false, "the project of the person holds")
}

/// Which road each command took to the check box, kept apart because the road is the whole of this
/// step: an event the window server delivered, or a press Accessibility performed.
private final class Routes {
  /// Every event the window server carried, in the order it carried it.
  var events: [InputGate.Event] = []

  /// Every control Accessibility was asked to press.
  var accessibilityPresses: [Locator] = []

  /// Every control the command asked the place of, so a test says which check box it aimed at.
  var aimedAt: [Locator] = []
}

/// The Logic of a test turns the solo of the track at that number over, the way a check box does.
private func aLogicWhoseSoloCheckBoxTurnsOver(atIndex index: Int) -> (FakeLogicDriver) -> Void {
  { fake in
    guard let place = fake.state?.tracks.firstIndex(where: { $0.index == index }) else {
      return
    }
    fake.state?.tracks[place].solo.toggle()
  }
}

/// Actions whose click goes through a real gate, with a Logic in front and no dialog open.
///
/// `elementAtThePoint` is what the window server finds under the point, so a test names another
/// element there to say what happens when the aim is wrong. `heard` is what Logic makes of a click
/// it took, and it runs on the release, because that is when a check box of Logic turns over.
///
/// The Accessibility press is given as well, and it records rather than acting, so a press that
/// this step took away is visible in the answer of the test rather than silently doing nothing.
private func actionsThatClickThroughAGate(
  target: AXUIElement,
  centre: CGPoint,
  elementAtThePoint: AXUIElement,
  routes: Routes,
  heard: @escaping () -> Void
) -> TrackActions {
  let gate = InputGate(
    frontmost: { true },
    modal: { false },
    elementAtPoint: { _ in elementAtThePoint },
    focus: { nil },
    sender: { event in
      routes.events.append(event)
      if case .mouseUp = event {
        heard()
      }
    })
  return TrackActions(
    pressInWindow: { locator in
      routes.accessibilityPresses.append(locator)
    },
    click: TrackActions.clickThroughTheGate(
      gate,
      readingTheTargetWith: { locator in
        routes.aimedAt.append(locator)
        return (element: target, centre: centre)
      }))
}

/// Runs `logicctl tracks mute` with the actions a test prepared, so the test says how the control
/// is reached as well as what Logic makes of it.
private func mutingThrough(
  actions: TrackActions, line: [String], driver: FakeLogicDriver
) -> MuteAnswer {
  let answer = MuteAnswer()
  let time = MuteTime()
  do {
    let command = try Tracks.Mute.parse(line)
    answer.status = Tracks.Mute.answer(
      driver: driver,
      actions: actions,
      index: command.track.index,
      muted: try command.muting.state(),
      confirmed: command.guarded.confirm,
      root: noSessionFolder(),
      limitMs: 50,
      argv: line,
      clock: time.read,
      sleeper: time.sleep,
      standardOutput: answer.write,
      standardError: answer.writeError)
  } catch {
    answer.status = Logicctl.report(
      error, arguments: line, standardOutput: answer.write, standardError: answer.writeError)
  }
  return answer
}

/// Runs `logicctl tracks solo` with the actions a test prepared.
private func soloingThrough(
  actions: TrackActions, line: [String], driver: FakeLogicDriver
) -> MuteAnswer {
  let answer = MuteAnswer()
  let time = MuteTime()
  do {
    let command = try Tracks.Solo.parse(line)
    answer.status = Tracks.Solo.answer(
      driver: driver,
      actions: actions,
      index: command.track.index,
      soloed: try command.soloing.state(),
      confirmed: command.guarded.confirm,
      root: noSessionFolder(),
      limitMs: 50,
      argv: line,
      clock: time.read,
      sleeper: time.sleep,
      standardOutput: answer.write,
      standardError: answer.writeError)
  } catch {
    answer.status = Logicctl.report(
      error, arguments: line, standardOutput: answer.write, standardError: answer.writeError)
  }
  return answer
}

/// A mute and a solo reach the check box with a click of the mouse, and no click leaves the gate.
///
/// Measured on Logic 12.3.1 on 2026-09-27: `AXUIElementPerformAction` on the mute check box of the
/// header of track 1 answers success and leaves the value at 0. It stayed at 0 after three presses,
/// so `tracks mute --index 1 --on` read the old state back until the wait ran out and answered
/// `timeout`. A left click at the centre of the same check box took the value to 1.
///
/// The gate carries the check box as the target of the click, so the two events reach Logic only
/// while the element the window server finds under the point is that check box. An aim that lands
/// anywhere else sends nothing at all, which is what keeps a mute of track 1 off track 2.
@Test func muteAndSoloClickTheCheckBoxThroughTheGate() throws {
  let checkBox = AXUIElementCreateApplication(601)
  let centre = CGPoint(x: 120, y: 340)
  let turnTheMuteOver = aLogicWhoseMuteButtonTurnsOver(atIndex: 1)

  let muting = aLogicHoldingTracks([Track(index: 1, name: "Bass", type: .other)])
  let mute = Routes()
  let muted = mutingThrough(
    actions: actionsThatClickThroughAGate(
      target: checkBox,
      centre: centre,
      elementAtThePoint: checkBox,
      routes: mute,
      heard: { turnTheMuteOver(muting) }),
    line: ["--index", "1", "--on"],
    driver: muting)

  #expect(muted.status == 0, "the mute worked")
  #expect(try muted.row()["mute"] as? Bool == true, "and Logic shows the track silent")
  #expect(
    mute.events == [.mouseDown(centre), .mouseUp(centre)],
    "one click at the centre of the check box, a press and a release, and no other event")
  #expect(mute.accessibilityPresses.isEmpty, "and Accessibility pressed nothing")
  #expect(
    mute.aimedAt == [Locators.trackMuteButton(number: 0)],
    "the click was aimed at the mute box of the header of the track that was named")

  let soloing = aLogicHoldingTracks([Track(index: 1, name: "Bass", type: .other)])
  let solo = Routes()
  let turnTheSoloOver = aLogicWhoseSoloCheckBoxTurnsOver(atIndex: 1)
  let soloed = soloingThrough(
    actions: actionsThatClickThroughAGate(
      target: checkBox,
      centre: centre,
      elementAtThePoint: checkBox,
      routes: solo,
      heard: { turnTheSoloOver(soloing) }),
    line: ["--index", "1", "--on"],
    driver: soloing)

  #expect(soloed.status == 0, "the solo worked")
  #expect(try soloed.row()["solo"] as? Bool == true, "and Logic shows the track soloed")
  #expect(
    solo.events == [.mouseDown(centre), .mouseUp(centre)],
    "one click at the centre of the check box, and no other event")
  #expect(solo.accessibilityPresses.isEmpty, "and Accessibility pressed nothing")
  #expect(
    solo.aimedAt == [Locators.trackSoloButton(number: 0)],
    "the click was aimed at the solo box of the header of the track that was named")

  let anotherControl = AXUIElementCreateApplication(602)
  let untouched = aLogicHoldingTracks([Track(index: 1, name: "Bass", type: .other)])
  let wrongAim = Routes()
  let refused = mutingThrough(
    actions: actionsThatClickThroughAGate(
      target: checkBox,
      centre: centre,
      elementAtThePoint: anotherControl,
      routes: wrongAim,
      heard: { turnTheMuteOver(untouched) }),
    line: ["--index", "1", "--on"],
    driver: untouched)
  let reason = try refused.failureDetails()["reason"] as? String ?? ""

  #expect(refused.status == 70, "the number the design system gives internal")
  #expect(try refused.failureCode() == "internal", "the gate refused, and no other code covers it")
  #expect(
    reason.contains("theElementAtThePointIsNotTheTarget"),
    "and the answer says what the gate refused")
  #expect(wrongAim.events.isEmpty, "the window server carried nothing, so Logic read no click")
  #expect(wrongAim.accessibilityPresses.isEmpty, "and nothing fell back to a press")
  #expect(untouched.state?.tracks.first?.mute == false, "so the track is heard still")
}
