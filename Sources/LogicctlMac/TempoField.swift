import ApplicationServices
import Foundation
import LogicctlCore

/// The tempo display of the Control Bar, and how a number is written into it.
///
/// Logic keeps the tempo of the project in a slider, not in a text field, and a slider of Logic
/// takes no number: a write moves it one step toward the number written, and `AXIncrement` and
/// `AXDecrement` move it ten. Measured against Logic 12.3.1 on a copy: one action took 120 to 130
/// and back, a write of 96 from 120 gave 119, and a write of 200 from 119 gave 120. So a move to a
/// number is a run of steps, and `SliderStepper` is what makes it: an action while the distance is
/// ten or more, then one write for each step that is left, with a read back after every move.
///
/// Every operation is a closure the caller gives, as they are for `SaveDialog` and `TrackActions`.
/// The pipeline has no Logic, so a test drives the same route with a field of its own.
public struct TempoField {
  /// Why the route stopped. The reason reaches the answer of the command, so a person reads what
  /// Logic refused without going to look for a log.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// One short reason, in the words of the Mac that refused.
    public let reason: String

    /// The code a caller reads and exits with.
    public let code: ErrorCode

    public init(reason: String, code: ErrorCode = .elementNotFound) {
      self.reason = reason
      self.code = code
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(code: code, message: reason)
    }
  }

  /// The slider of the Control Bar that carries the tempo of the project.
  ///
  /// It is the one slider of the group that holds the displays, beside the playhead position and
  /// the time signature. It carries no identifier and no title, so its role and its place are the
  /// whole of what a path can name here. Logic writes the tempo into its value: the recorded tree
  /// of a project at 120 reads `120`.
  ///
  /// The locator sits in this file and not in `Locators.swift`, which holds every other walk,
  /// because another step writes that file at the same time as this one. It moves there, and into
  /// `Locators.all`, once that step lands.
  public static let tempoSlider = Locator(
    name: "transport.tempoField",
    path: [
      LocatorStep(role: "AXWindow"),
      LocatorStep(role: "AXGroup", index: 0),
      LocatorStep(role: "AXGroup", index: 0),
      LocatorStep(role: "AXSlider", index: 0),
    ])

  /// Reads the tempo the display shows, as a whole number.
  public typealias Read = () throws -> Int

  /// Writes one number into the slider. The slider moves one step toward it.
  public typealias Write = (Int) throws -> Void

  /// Asks the slider for one of its own steps, of ten.
  public typealias Act = (SliderStepper.LargeStep) throws -> Void

  /// Reads the tempo.
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

extension TempoField {
  /// Moves the display to one tempo, and answers the number it reached.
  ///
  /// A tempo the display already shows costs Logic nothing, because the stepper reads before it
  /// writes. A step that leaves the display where it was stops the move with `SliderStepper`
  /// refusing, which carries the number asked for and the number read, so a command never reports
  /// a tempo the project did not take.
  public func set(
    to tempo: Int,
    limitMs: Int = Wait.defaultLimitMs,
    pollMs: Int = Wait.defaultPollMs,
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds
  ) throws -> Int {
    let stepper = SliderStepper(read: read, write: write, act: act)
    return try stepper.move(
      to: tempo, limitMs: limitMs, pollMs: pollMs, clock: clock, sleeper: sleeper)
  }
}

extension TempoField {
  /// The tempo display of the Logic that runs on this Mac.
  ///
  /// Each operation walks to the element again rather than holding one, because Logic builds the
  /// Control Bar afresh as windows open and close, and an element read once is a handle to the
  /// element of that moment.
  public static func live() -> TempoField {
    TempoField(
      read: TempoField.readTheLogicOfThisMac,
      write: TempoField.writeIntoTheLogicOfThisMac,
      act: TempoField.stepTheLogicOfThisMac)
  }

  /// What the tempo display of this Mac shows, as a whole number.
  public static func readTheLogicOfThisMac() throws -> Int {
    let slider = try TempoField.sliderOfThisMac()
    let text = slider.valueDescription ?? slider.value ?? ""
    guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else {
      throw Refusal(reason: "The tempo display of Logic reads \(text), which is no tempo.")
    }
    return number
  }

  /// Writes one number into the tempo display of this Mac. The display moves one step toward it.
  public static func writeIntoTheLogicOfThisMac(_ tempo: Int) throws {
    let element = try TempoField.liveSliderOfThisMac()
    let answered = AXUIElementSetAttributeValue(
      element, kAXValueAttribute as CFString, String(tempo) as CFTypeRef)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused the write of \(tempo) into the tempo display, "
          + "error \(answered.rawValue).",
        code: .internalFailure)
    }
  }

  /// Asks the tempo display of this Mac for one of its own steps, which moves it ten.
  public static func stepTheLogicOfThisMac(_ step: SliderStepper.LargeStep) throws {
    let element = try TempoField.liveSliderOfThisMac()
    let action = step == .up ? kAXIncrementAction : kAXDecrementAction
    let answered = AXUIElementPerformAction(element, action as CFString)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused a step of the tempo display, error \(answered.rawValue).",
        code: .internalFailure)
    }
  }

  /// The tempo display of the Logic that runs, as an element of the tree.
  private static func sliderOfThisMac() throws -> any AXNode {
    guard let front = try AXDriver.treeOfRunningLogic()?.atTheFrontWindow() else {
      throw Refusal(reason: "Logic shows no window, so its tempo display is not there to reach.")
    }
    return try LocatorResolver.element(of: TempoField.tempoSlider, in: front.root)
  }

  /// The tempo display of the Logic that runs, as something this Mac can write into.
  private static func liveSliderOfThisMac() throws -> AXUIElement {
    let found = try TempoField.sliderOfThisMac()
    guard let live = found as? LiveAXNode else {
      throw Refusal(
        reason: "The tempo display was found in a recorded tree, which nothing can drive.",
        code: .internalFailure)
    }
    return live.element
  }
}
