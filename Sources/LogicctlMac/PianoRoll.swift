import ApplicationServices
import Foundation
import LogicctlCore

/// Quantizes the notes Logic shows in the Piano Roll of one region.
///
/// Logic quantizes what is selected, and the Piano Roll is the one window where a note can be
/// selected: setting `AXSelected` on a region row of the Event List selects the region, not its
/// notes. So the walk selects every note item of the window, sets the grid and the strength beside
/// the Time Quantize button, and presses it.
///
/// Each of the three things Logic is asked to do is a closure the caller gives, as they are for
/// `TrackActions`, `SelectionGuard` and `InputGate`. The pipeline has no Logic, so a test drives
/// the same quantize against the tree `inspect` recorded and nothing on the Mac moves.
public struct PianoRoll {
  /// What the title of a Piano Roll window ends with. The rest of the title is the name of the
  /// project, so this is the whole of what a window of any project has in common.
  public static let windowTitle = " - Piano Roll"

  /// What the description of a note item starts with, for example `Note at 1 bar 4 divisions ,
  /// D3`. The rest of it is where the note sits and which key it is.
  public static let noteDescription = "Note at "

  /// What the help text of the Time Quantize button starts with.
  public static let timeQuantizeButtonHelp = "Time Quantize button"

  /// What the help text of the popup that holds the grid starts with.
  public static let timeQuantizePopUpHelp = "Time Quantize pop-up menu"

  /// What the help text of the Strength slider starts with.
  ///
  /// The help is what tells the Strength slider from the Swing slider, and nothing else does. Both
  /// carry the description `Strength`, so a walk that read the description would find two elements
  /// and set the swing of the region where a person asked for the strength of the quantize. The
  /// Velocity slider is the same trap the other way round: its description reads `Transpose`.
  public static let strengthSliderHelp = "Strength slider"

  /// The walk found no element, or more than one, where it needs exactly one.
  ///
  /// A walk that took the first of several would press a button nobody named, and no later read of
  /// the region could tell that it happened.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// What the walk was looking for, in words a person reads, for example `the Strength slider`.
    public let looked: String

    /// How many elements it found. Anything other than one stops the command.
    public let matched: Int

    public init(looked: String, matched: Int) {
      self.looked = looked
      self.matched = matched
    }

    public var failure: Failure {
      Failure(
        code: .elementNotFound,
        message: "The Piano Roll shows \(matched) of \(looked), and a quantize needs one",
        details: .object([
          "looked": .string(looked),
          "matched": .number(Double(matched)),
        ]))
    }
  }

  /// Logic did not take the grid that was written into the Time Quantize popup.
  ///
  /// Nothing is pressed after this. Logic quantizes to whatever the popup holds, so a press on a
  /// popup that kept its old grid would move every selected note onto a grid nobody asked for, and
  /// the answer would read as though the command worked.
  public struct GridRefused: FailureCarrying, Equatable, Sendable {
    /// The text the walk wrote into the popup.
    public let asked: String

    /// What the popup read back as, or nothing when it holds no text at all.
    public let read: String?

    public init(asked: String, read: String?) {
      self.asked = asked
      self.read = read
    }

    public var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "The Time Quantize popup reads \(read ?? "nothing") after \(asked) was written into it, "
          + "so nothing was quantized",
        details: .object([
          "asked": .string(asked),
          "read": read.map { JSONValue.string($0) } ?? .null,
        ]))
    }
  }

  /// Selects every note of the Piano Roll, and nothing else.
  public typealias Select = ([any AXNode]) throws -> Void

  /// Writes one text into the popup that holds the grid.
  public typealias Choose = (any AXNode, String) throws -> Void

  /// Presses one element of the Piano Roll.
  public typealias Press = (any AXNode) throws -> Void

  /// The stepper that moves one slider of the Piano Roll to a value.
  public typealias StepperFor = (any AXNode) -> SliderStepper

  public let select: Select
  public let choose: Choose
  public let press: Press
  public let stepper: StepperFor

  public init(
    select: @escaping Select,
    choose: @escaping Choose,
    press: @escaping Press,
    stepper: @escaping StepperFor
  ) {
    self.select = select
    self.choose = choose
    self.press = press
    self.stepper = stepper
  }

  /// Quantizes every note of the Piano Roll to one grid.
  ///
  /// The window is read again between the steps rather than held, because each thing Logic is
  /// asked to do can change the window, and an element read before a change belongs to the tree it
  /// was read from. The press comes last: Logic quantizes what the popup and the slider hold at
  /// the moment the button is pressed, so a press before either one is set quantizes to whatever
  /// the last person left there.
  public func quantize(
    _ value: QuantizeValue,
    strength: QuantizeStrength,
    inWindowFrom window: () throws -> any AXNode
  ) throws {
    let notes = PianoRoll.notes(in: try window())
    guard !notes.isEmpty else {
      throw Refusal(looked: "a note", matched: 0)
    }
    try select(notes)

    let grid = PianoRoll.menuText(for: value)
    try choose(try PianoRoll.timeQuantizePopUp(in: try window()), grid)
    let read = try PianoRoll.timeQuantizePopUp(in: try window()).value
    guard read == grid else {
      throw GridRefused(asked: grid, read: read)
    }

    _ = try stepper(try PianoRoll.strengthSlider(in: try window())).move(to: strength.value)

    try press(try PianoRoll.timeQuantizeButton(in: try window()))
  }
}

extension PianoRoll {
  /// The window of the tree that is showing a Piano Roll, or nothing when no window is.
  ///
  /// The walk cannot name the window by its title, because the title carries the name of the
  /// project. So the end of the title is what a window of any project is known by.
  public static func window(of tree: LogicTree) -> (any AXNode)? {
    windows(under: tree.root).first { ($0.title ?? "").hasSuffix(windowTitle) }
  }

  /// The note items the Piano Roll shows, in the order Accessibility answers them, which is the
  /// order Logic draws them in.
  public static func notes(in window: any AXNode) -> [any AXNode] {
    under(window).filter {
      $0.role == "AXLayoutItem" && ($0.description ?? "").hasPrefix(noteDescription)
    }
  }

  /// The button that quantizes the selected notes.
  public static func timeQuantizeButton(in window: any AXNode) throws -> any AXNode {
    try one("the Time Quantize button", in: window, role: "AXButton", help: timeQuantizeButtonHelp)
  }

  /// The popup that holds the grid the notes move to.
  public static func timeQuantizePopUp(in window: any AXNode) throws -> any AXNode {
    try one(
      "the Time Quantize popup", in: window, role: "AXPopUpButton", help: timeQuantizePopUpHelp)
  }

  /// The slider that holds how far each note moves to the grid.
  public static func strengthSlider(in window: any AXNode) throws -> any AXNode {
    try one("the Strength slider", in: window, role: "AXSlider", help: strengthSliderHelp)
  }

  /// The text Logic shows for one grid in the Time Quantize popup.
  ///
  /// Only `1/16 Note` was read from Logic 12.3.1, and the other ten follow the same shape without
  /// having been read. A text Logic does not offer is caught rather than guessed at: the grid is
  /// written, read back, and the command stops with `element_not_found` before it presses
  /// anything. The live acceptance of phase 4 is what reads the other ten.
  public static func menuText(for value: QuantizeValue) -> String {
    let raw = value.rawValue
    guard raw.hasSuffix("t") else {
      return "\(raw) Note"
    }
    return "\(raw.dropLast()) Note Triplet"
  }

  /// The one element of a role whose help text starts with these words.
  private static func one(
    _ looked: String, in window: any AXNode, role: String, help: String
  ) throws -> any AXNode {
    let found = under(window).filter {
      $0.role == role && ($0.help ?? "").hasPrefix(help)
    }
    guard found.count == 1, let element = found.first else {
      throw Refusal(looked: looked, matched: found.count)
    }
    return element
  }

  /// Every element under one, a level at a time.
  private static func under(_ node: any AXNode) -> [any AXNode] {
    var level: [any AXNode] = node.children
    var found: [any AXNode] = []
    while !level.isEmpty {
      found += level
      level = level.flatMap { $0.children }
    }
    return found
  }

  /// Every window of the tree, a level at a time, so a window of the application comes before
  /// anything a window holds.
  private static func windows(under node: any AXNode) -> [any AXNode] {
    ([node] + under(node)).filter { $0.role == "AXWindow" }
  }
}

extension PianoRoll {
  /// The Piano Roll of the Logic that runs on this Mac.
  public static func live() -> PianoRoll {
    PianoRoll(
      select: PianoRoll.selectInTheLogicOfThisMac,
      choose: PianoRoll.chooseInTheLogicOfThisMac,
      press: PianoRoll.pressInTheLogicOfThisMac,
      stepper: PianoRoll.stepperForTheLogicOfThisMac)
  }

  /// Sets `AXSelected` on each element, which is how the probe selected notes.
  public static func selectInTheLogicOfThisMac(_ notes: [any AXNode]) throws {
    for note in notes {
      try write(kAXSelectedAttribute, of: note, to: kCFBooleanTrue, called: "a note")
    }
  }

  /// Writes one text into the popup that holds the grid.
  ///
  /// A popup of Logic can refuse this, the way the Automation Mode popup opens no menu that
  /// Accessibility can see. The caller reads the popup back afterwards and stops the command when
  /// it did not take, so a refusal here never reaches the press.
  public static func chooseInTheLogicOfThisMac(_ element: any AXNode, _ text: String) throws {
    try write(
      kAXValueAttribute, of: element, to: text as CFTypeRef, called: "the Time Quantize popup")
  }

  /// Presses one element through Accessibility, which is not a mouse event and so does not go
  /// through the input gate.
  public static func pressInTheLogicOfThisMac(_ element: any AXNode) throws {
    let live = try liveElement(of: element, called: "the element to press")
    let answered = AXUIElementPerformAction(live, kAXPressAction as CFString)
    guard answered == .success else {
      throw Trouble(
        reason: "Logic refused the press in the Piano Roll, error \(answered.rawValue).")
    }
  }

  /// The stepper that moves one slider of the Piano Roll.
  ///
  /// A slider of Logic takes no number: a write moves it one step toward the number written, and
  /// `AXIncrement` and `AXDecrement` move it ten. The stepper is what turns that into a value.
  public static func stepperForTheLogicOfThisMac(_ slider: any AXNode) -> SliderStepper {
    SliderStepper(
      read: { try PianoRoll.number(of: slider) },
      write: { asked in
        try write(
          kAXValueAttribute, of: slider, to: String(asked) as CFTypeRef, called: "a slider")
      },
      act: { step in
        let live = try liveElement(of: slider, called: "a slider")
        let action = step == .up ? kAXIncrementAction : kAXDecrementAction
        let answered = AXUIElementPerformAction(live, action as CFString)
        guard answered == .success else {
          throw Trouble(reason: "Logic refused a step of a slider, error \(answered.rawValue).")
        }
      })
  }

  /// What a slider of the Piano Roll holds, as a whole number.
  ///
  /// The Strength slider writes its number in the value. A slider that carries something else
  /// there, as the Velocity slider does, reads as no number at all rather than as a value the
  /// stepper would then chase.
  static func number(of slider: any AXNode) throws -> Int {
    let text = slider.valueDescription ?? slider.value ?? ""
    guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else {
      throw Trouble(reason: "A slider of the Piano Roll reads \(text), which is no value.")
    }
    return number
  }

  /// Why the Mac gave no change. The reason reaches the answer of the command.
  public struct Trouble: FailureCarrying, Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
      self.reason = reason
    }

    public var failure: Failure {
      Failure(code: .internalFailure, message: reason)
    }
  }

  /// Writes one attribute of an element of the running Logic.
  private static func write(
    _ attribute: String, of element: any AXNode, to carried: CFTypeRef?, called name: String
  ) throws {
    let live = try liveElement(of: element, called: name)
    let answered = AXUIElementSetAttributeValue(
      live, attribute as CFString, carried ?? "" as CFTypeRef)
    guard answered == .success else {
      throw Trouble(reason: "Logic refused the write into \(name), error \(answered.rawValue).")
    }
  }

  /// The element of the running Logic behind one node.
  private static func liveElement(of node: any AXNode, called name: String) throws -> AXUIElement {
    guard let live = node as? LiveAXNode else {
      throw Trouble(reason: "\(name) was found in a recorded tree, which nothing can change.")
    }
    return live.element
  }
}
