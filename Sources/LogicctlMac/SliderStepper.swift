import Foundation
import LogicctlCore

/// Moves a value slider of Logic to a number, one step of the slider at a time.
///
/// The velocity slider of the Event List and the value slider of a region automation point take no
/// number: a write of any number moves the slider one step toward it, and the slider answers with
/// the value it reached (ingress probe, Logic 12.3.1). Logic writes that value into the tree after
/// a delay, so each step is read back before the next one goes out. A command that wrote 100 once
/// and reported it would name a velocity the note does not carry.
///
/// Every operation is a closure the caller gives, as they are for `SaveDialog`. The pipeline has
/// no Logic, so a test drives the same route with a slider of its own.
public struct SliderStepper {
  /// A write that left the value where it was.
  ///
  /// The slider answered, and it answered the same number, so there is nothing left to try: the
  /// element under the locator does not take what the command has to give it. The value asked for
  /// and the value read both go out, because a person reading `element_not_found` needs to know
  /// how far the slider got before it stopped.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// The value the command asked the slider for.
    public let asked: Int

    /// The value the slider read back, after the write and before it.
    public let read: Int

    public init(asked: Int, read: Int) {
      self.asked = asked
      self.read = read
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(
        code: .elementNotFound,
        message: "the slider stayed at \(read) after a write, so it does not reach \(asked)",
        details: .object([
          "asked": .number(Double(asked)),
          "read": .number(Double(read)),
        ]))
    }
  }

  /// Which way one action of the slider moves it.
  ///
  /// The live caller asks for `AXIncrement` to go up and `AXDecrement` to go down. Both move the
  /// slider by `stepOfAnAction`, and neither takes a number.
  public enum LargeStep: Sendable, Equatable {
    case up
    case down
  }

  /// How far one action of the slider moves it, measured against Logic 12.3.1.
  public static let stepOfAnAction = 10

  /// Reads the value the slider shows, as a whole number.
  public typealias Read = () throws -> Int

  /// Writes one number into the slider. The slider moves one step toward it.
  public typealias Write = (Int) throws -> Void

  /// Asks the slider for one of its own steps, of `stepOfAnAction`.
  public typealias Act = (LargeStep) throws -> Void

  /// Reads the value of the slider.
  public let read: Read

  /// Writes a number into the slider.
  public let write: Write

  /// Asks the slider to move by one action.
  public let act: Act

  public init(read: @escaping Read, write: @escaping Write, act: @escaping Act) {
    self.read = read
    self.write = write
    self.act = act
  }
}

extension SliderStepper {
  /// How long one step of the slider has to reach the tree before the slider counts as stuck.
  ///
  /// Logic writes the step some time after the write, so a read that still answers the old value
  /// says nothing on its own. A slider that answers the old value for this long answers it because
  /// it did not move, and the command stops rather than writing at it again.
  public static let settleMs = 500

  /// Moves the slider to one value, one step at a time, and answers with the value it reached.
  ///
  /// The action of the slider moves it `stepOfAnAction`, so the stepper spends one of those while
  /// the value is that far away and a write of one step after that. It stops at the value, with
  /// `Refusal` when a step did not move the slider, and with `Wait.RanOut` when the whole move
  /// passed its limit. A value the slider already shows costs Logic nothing.
  public func move(
    to value: Int,
    limitMs: Int = Wait.defaultLimitMs,
    pollMs: Int = Wait.defaultPollMs,
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds
  ) throws -> Int {
    let started = clock()
    var shown = try read()
    while shown != value {
      let waited = clock() - started
      if waited >= limitMs {
        throw Wait.RanOut(waitedMs: waited)
      }
      let before = shown
      if abs(value - before) >= SliderStepper.stepOfAnAction {
        try act(before < value ? .up : .down)
      } else {
        try write(value)
      }
      let settle = min(SliderStepper.settleMs, limitMs - (clock() - started))
      do {
        try Wait.until(limitMs: settle, pollMs: pollMs, clock: clock, sleeper: sleeper) {
          shown = try read()
          return shown != before
        }
      } catch is Wait.RanOut {
        let waitedInAll = clock() - started
        if waitedInAll >= limitMs {
          throw Wait.RanOut(waitedMs: waitedInAll)
        }
        throw Refusal(asked: value, read: before)
      }
    }
    return shown
  }
}
