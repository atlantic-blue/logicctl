import ApplicationServices
import Foundation
import LogicctlCore

/// Reads the notes of a region out of the Event List window of Logic.
///
/// The Event List is one table of everything the region holds, and a note is one kind of row in
/// it. A region that carries volume automation shows a `Fader` row at every point, in the same
/// columns as a note and with a number where a velocity sits. So the Status cell is what says
/// which rows are notes, and the rows that say anything else are left out.
///
/// The notes are numbered from 1 in the order the table answers them, which is the order Logic
/// shows them, which is time order. That number is what `--note` takes in every later command, so
/// a reader that numbered anything else would send an edit to an event nobody named.
public enum EventList {
  /// What the Status cell of a note row reads.
  public static let noteStatus = "Note"

  /// What the title of an Event List window ends with. The rest of the title is the name of the
  /// project, so this is the whole of what a window of any project has in common.
  public static let windowTitle = " - Event List"

  /// The cells of a row, in the order the table answers them: the two markers Logic keeps at the
  /// left, the position, the status, the channel, the pitch, the velocity and the length.
  private enum Cell: Int {
    case position = 2
    case status = 3
    case channel = 4
    case pitch = 5
    case velocity = 6
    case length = 7
  }

  /// One note of a region, as `midi notes` prints it.
  public struct Note: Equatable, Sendable {
    /// The number of the note, from 1, in time order. This is the number `--note` takes.
    public var note: Int

    /// Where the note starts, as the Event List shows it: bar, beat, division and tick.
    public var position: String

    /// Which key, 0 to 127. Logic writes `C3` on the slider and holds 60 under it, and the number
    /// is what a MIDI file carries, so the number is what this answers.
    public var pitch: Int

    /// How hard the key was struck, 1 to 127.
    public var velocity: Int

    /// How long the note sounds, as the Event List shows it: bar, beat, division and tick.
    public var length: String

    /// Which of the 16 MIDI channels the note is on.
    public var channel: Int

    public init(
      note: Int, position: String, pitch: Int, velocity: Int, length: String, channel: Int
    ) {
      self.note = note
      self.position = position
      self.pitch = pitch
      self.velocity = velocity
      self.length = length
      self.channel = channel
    }

    /// The note as a JSON value, as part 5a of the data model says.
    public var json: JSONValue {
      .object([
        "note": .number(Double(note)),
        "position": .string(position),
        "pitch": .number(Double(pitch)),
        "velocity": .number(Double(velocity)),
        "length": .string(length),
        "channel": .number(Double(channel)),
      ])
    }
  }

  /// The notes the Event List shows, read from the window it is showing them in.
  ///
  /// A row the reader cannot read every field of is left out with the faders. A half read note
  /// would take a number that a later command then sends an edit to.
  public static func notes(in window: any AXNode) throws -> [Note] {
    try rows(in: window).compactMap { row in
      guard let number = row.note, var read = note(of: row.row) else {
        return nil
      }
      read.note = number
      return read
    }
  }

  /// One row of the table, as a command that changes one event reads it.
  ///
  /// A command that edits one event needs the row itself: Logic applies an edit to every row it
  /// holds selected, and the velocity of a note is a slider inside its row.
  public struct Row {
    /// The row, as Logic answers it.
    public let row: any AXNode

    /// The number `--note` takes for this row, or nothing when the row holds no note.
    public let note: Int?

    /// What the Status cell says, for example `Note` or `Fader`, or nothing when the cell is
    /// not there.
    public let status: String?

    /// Where the row sits in the table, from 1.
    public let place: Int

    public init(row: any AXNode, note: Int?, status: String?, place: Int) {
      self.row = row
      self.note = note
      self.status = status
      self.place = place
    }
  }

  /// Every row of the table, in the order the table answers them, with the notes numbered.
  ///
  /// The numbering happens here and nowhere else, so a row `notes` leaves out carries no number
  /// either, and no edit can reach an event that `midi notes` did not show.
  public static func rows(in window: any AXNode) throws -> [Row] {
    let table = try LocatorResolver.element(of: Locators.eventListTable, in: window)
    var notes = 0
    return table.children.filter { $0.role == "AXRow" }.enumerated().map { place, row in
      guard note(of: row) != nil else {
        return Row(
          row: row, note: nil, status: text(of: cells(of: row), at: .status), place: place + 1)
      }
      notes += 1
      return Row(row: row, note: notes, status: noteStatus, place: place + 1)
    }
  }

  /// The slider that holds the velocity of one row, or nothing when the row carries none.
  ///
  /// Logic writes the velocity on this slider and holds a scaled 32 bit number under it, so a
  /// command that changes a velocity moves this element and reads what it says afterwards.
  public static func velocitySlider(of row: any AXNode) -> (any AXNode)? {
    guard let element = under(cells(of: row), at: .velocity), element.role == "AXSlider" else {
      return nil
    }
    return element
  }

  /// The window of the tree that is showing an Event List, or nothing when no window is.
  ///
  /// The walk cannot name the window by its title, because the title carries the name of the
  /// project. So the end of the title is what a window of any project is known by.
  public static func window(of tree: LogicTree) -> (any AXNode)? {
    windows(under: tree.root).first { ($0.title ?? "").hasSuffix(windowTitle) }
  }

  /// One row read as a note, or nothing when the row is not a note or does not read.
  private static func note(of row: any AXNode) -> Note? {
    let cells = EventList.cells(of: row)
    guard text(of: cells, at: .status) == noteStatus,
      let position = text(of: cells, at: .position),
      let length = text(of: cells, at: .length),
      let pitch = number(of: cells, at: .pitch, from: { $0.value }),
      let velocity = number(of: cells, at: .velocity, from: { $0.valueDescription }),
      let channel = number(of: cells, at: .channel, from: { $0.value })
    else {
      return nil
    }
    return Note(
      note: 0,
      position: trimmed(position),
      pitch: pitch,
      velocity: velocity,
      length: trimmed(length),
      channel: channel)
  }

  /// The cells of one row, in the order the table answers them.
  private static func cells(of row: any AXNode) -> [any AXNode] {
    row.children.filter { $0.role == "AXCell" }
  }

  /// What one cell says, from the element under it, or nothing when the cell is not there.
  ///
  /// Logic writes the text of a cell on the element inside it rather than on the cell, and a
  /// position sits on the group that holds one slider per segment.
  private static func text(of cells: [any AXNode], at cell: Cell) -> String? {
    under(cells, at: cell)?.description
  }

  /// What one cell holds as a number, read from the field that carries it.
  ///
  /// The pitch is read from the value, because Logic writes `C3` on the slider and holds 60 under
  /// it. The velocity is read the other way round: Logic writes 100 on the slider and holds a
  /// scaled 32 bit number under it, which no reader turns back into a velocity.
  private static func number(
    of cells: [any AXNode], at cell: Cell, from field: (any AXNode) -> String?
  ) -> Int? {
    guard let element = under(cells, at: cell), let carried = field(element) else {
      return nil
    }
    return Int(trimmed(carried))
  }

  /// The element inside one cell of a row, or nothing when the row is shorter than that.
  private static func under(_ cells: [any AXNode], at cell: Cell) -> (any AXNode)? {
    guard cell.rawValue < cells.count else {
      return nil
    }
    return cells[cell.rawValue].children.first
  }

  /// The text without the space Logic writes after a position.
  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespaces)
  }

  /// Every window of the tree, a level at a time, so a window of the application comes before
  /// anything a window holds.
  private static func windows(under node: any AXNode) -> [any AXNode] {
    var level: [any AXNode] = [node]
    var found: [any AXNode] = []
    while !level.isEmpty {
      found += level.filter { $0.role == "AXWindow" }
      level = level.flatMap { $0.children }
    }
    return found
  }
}

extension EventList {
  /// What Logic is asked to do to the rows of the Event List.
  ///
  /// Logic applies an edit to every row it holds selected, so a command holds one row, reads the
  /// selection back through `SelectionGuard`, and only then moves a slider of that row. Each
  /// operation is a closure the caller gives, as they are for `PianoRoll` and `SaveDialog`, so a
  /// test drives the same route against a table of its own and the pipeline needs no Logic.
  public struct Actions {
    /// Holds one row selected, or lets it go.
    public typealias Select = (any AXNode, Bool) throws -> Void

    /// Reads whether Logic holds one row selected.
    public typealias ReadSelected = (any AXNode) throws -> Bool

    /// The stepper that moves one slider of a row to a value.
    public typealias StepperFor = (any AXNode) -> SliderStepper

    public let select: Select
    public let selected: ReadSelected
    public let stepper: StepperFor

    public init(
      select: @escaping Select,
      selected: @escaping ReadSelected,
      stepper: @escaping StepperFor
    ) {
      self.select = select
      self.selected = selected
      self.stepper = stepper
    }

    /// The Event List of the Logic that runs on this Mac.
    public static func live() -> Actions {
      Actions(
        select: EventList.selectInTheLogicOfThisMac,
        selected: EventList.selectedInTheLogicOfThisMac,
        stepper: EventList.stepperForTheLogicOfThisMac)
    }
  }
}

extension EventList {
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

  /// Holds one row of the table selected, or lets it go, by writing `AXSelected` on it.
  public static func selectInTheLogicOfThisMac(_ row: any AXNode, _ holding: Bool) throws {
    let live = try liveElement(of: row)
    let carried: CFBoolean = holding ? kCFBooleanTrue : kCFBooleanFalse
    let answered = AXUIElementSetAttributeValue(live, kAXSelectedAttribute as CFString, carried)
    guard answered == .success else {
      throw Trouble(
        reason: "Logic refused the write into a row of the Event List, error \(answered.rawValue).")
    }
  }

  /// Reads whether Logic holds one row of the table selected.
  ///
  /// A row that answers nothing reads as a row Logic does not hold, because the guard compares
  /// what it asked for with what the table answers, and an attribute that is not there is not a
  /// selection.
  public static func selectedInTheLogicOfThisMac(_ row: any AXNode) throws -> Bool {
    let live = try liveElement(of: row)
    var carried: CFTypeRef?
    let answered = AXUIElementCopyAttributeValue(
      live, kAXSelectedAttribute as CFString, &carried)
    guard answered == .success else {
      return false
    }
    return carried as? Bool == true
  }

  /// The stepper that moves one slider of a row.
  ///
  /// A slider of Logic takes no number wherever it sits: a write moves it one step toward the
  /// number written, and its own two actions move it ten. So the sliders of the Event List are
  /// driven the way the sliders of the Piano Roll are.
  public static func stepperForTheLogicOfThisMac(_ slider: any AXNode) -> SliderStepper {
    PianoRoll.stepperForTheLogicOfThisMac(slider)
  }

  /// The element of the running Logic behind one node.
  private static func liveElement(of node: any AXNode) throws -> AXUIElement {
    guard let live = node as? LiveAXNode else {
      throw Trouble(
        reason: "a row of the Event List was read from a recorded tree, which nothing can change.")
    }
    return live.element
  }
}
