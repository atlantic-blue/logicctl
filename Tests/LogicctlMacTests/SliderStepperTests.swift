import LogicctlCore
import LogicctlMac
import Testing

/// A slider of Logic, as the Event List answers one.
///
/// It takes no number: a write moves it one step toward the number written, and an action moves it
/// ten. It shows the step in the tree some reads after the move, the way Logic does, and a stuck
/// one shows nothing at all.
private final class ASlider {
  /// Where the slider is.
  private var value: Int

  /// What a read of the tree answers, which is where the slider was a moment ago.
  private var shown: Int

  /// False for a slider that takes the write and stays where it is.
  private let moves: Bool

  /// How many reads answer the old value before the tree carries the new one.
  private let readsBeforeItShows: Int

  /// How many reads answered the old value since the last move.
  private var oldReads = 0

  /// Every number the stepper wrote, in order.
  private(set) var writes: [Int] = []

  /// Every action the stepper asked for, in order.
  private(set) var actions: [SliderStepper.LargeStep] = []

  init(at value: Int, moves: Bool = true, readsBeforeItShows: Int = 0) {
    self.value = value
    self.shown = value
    self.moves = moves
    self.readsBeforeItShows = readsBeforeItShows
  }

  func read() -> Int {
    guard shown != value else {
      return shown
    }
    oldReads += 1
    if oldReads > readsBeforeItShows {
      shown = value
      oldReads = 0
    }
    return shown
  }

  func write(_ asked: Int) {
    writes.append(asked)
    guard moves, asked != value else {
      return
    }
    value += asked > value ? 1 : -1
  }

  func act(_ step: SliderStepper.LargeStep) {
    actions.append(step)
    guard moves else {
      return
    }
    value += step == .up ? SliderStepper.stepOfAnAction : -SliderStepper.stepOfAnAction
  }

  /// The stepper that drives this slider.
  var stepper: SliderStepper {
    SliderStepper(read: read, write: write, act: act)
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

/// A slider that takes the write and stays where it is has nothing more to give, so the command
/// says so once rather than writing at it until the limit runs out.
///
/// A velocity the note does not carry is worse than a refusal: the person reads 90 in the answer
/// and the note still plays at 40. The failure names both numbers, so they know how far it got.
@Test func theStepperStopsWhenTheValueDoesNotMove() {
  let slider = ASlider(at: 40, moves: false)
  let time = Time()

  #expect(throws: SliderStepper.Refusal(asked: 44, read: 40)) {
    _ = try slider.stepper.move(to: 44, clock: time.read, sleeper: time.sleep)
  }

  #expect(slider.writes == [44], "the stepper wrote once, and did not write at it again")
  #expect(slider.actions.isEmpty, "a slider four steps away is not moved by an action of ten")

  let refusal = SliderStepper.Refusal(asked: 44, read: 40)
  #expect(refusal.failure.code == .elementNotFound)
  #expect(refusal.failure.code.exitCode == 5, "the number the design system gives it")
  #expect(
    refusal.failure.details == .object(["asked": .number(44), "read": .number(40)]),
    "the failure names the value asked for and the value the slider read back")
}

/// Fifty steps of one write each would take fifty reads of Logic. The slider carries an action
/// that moves it ten, so the stepper spends five of those instead and the command answers sooner.
@Test func theStepperReachesTheValueInLargeSteps() throws {
  let slider = ASlider(at: 40)
  let time = Time()

  let reached = try slider.stepper.move(to: 90, clock: time.read, sleeper: time.sleep)

  #expect(reached == 90, "the stepper answers the value the slider reached")
  #expect(
    slider.actions == Array(repeating: SliderStepper.LargeStep.up, count: 5),
    "five steps of ten, and no more")
  #expect(slider.writes.isEmpty, "nothing was written one step at a time")
}

/// A slider that keeps moving but never arrives holds the session lock of the command open, so the
/// whole move has a limit and the answer says how long Logic had.
@Test func theStepperStopsAtTheLimitWhileTheSliderIsStillMoving() {
  let slider = ASlider(at: 0, readsBeforeItShows: 4)
  let time = Time()
  var stopped: Wait.RanOut?

  do {
    _ = try slider.stepper.move(to: 5, limitMs: 500, clock: time.read, sleeper: time.sleep)
  } catch let ranOut as Wait.RanOut {
    stopped = ranOut
  } catch {
    Issue.record("the stepper stopped with \(error) and not at the limit")
  }

  #expect(stopped?.failure.code == .timeout)
  #expect(stopped?.waitedMs == 500, "it gave Logic the whole limit and said how much that was")
  #expect(slider.writes.count == 3, "it stopped writing at the limit, not at the value")
}
