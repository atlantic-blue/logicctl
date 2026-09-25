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
    let table = try LocatorResolver.element(of: Locators.eventListTable, in: window)
    let rows = table.children.filter { $0.role == "AXRow" }
    return rows.compactMap(note(of:)).enumerated().map { place, note in
      var numbered = note
      numbered.note = place + 1
      return numbered
    }
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
    let cells = row.children.filter { $0.role == "AXCell" }
    guard let position = text(of: cells, at: .position),
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
