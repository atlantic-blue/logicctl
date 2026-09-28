import LogicctlCore

/// Puts the selection of the Event List on one row, and proves it is there alone before an edit.
///
/// Logic applies an edit to every item that is selected. So a command that quantizes note 1 while
/// the table still holds another row moves both notes, answers as though it moved one, and no
/// later read shows that the other one changed. The guard writes the selection, reads it back, and
/// stops the command when the readback holds anything besides the target.
///
/// A selection is also the work of the person at the keyboard: it is how they say which events
/// they are looking at. So the guard reads what the table held before it writes, and
/// `putTheSelectionBack` gives those rows back when the edit ends.
///
/// The write and the read are closures the caller gives, as they are for `InputGate` and
/// `SaveDialog`. A recorded tree carries no selection, so a test drives the guard with a table of
/// its own and the pipeline needs no Logic.
public struct SelectionGuard {
  /// Why the guard stopped the edit.
  ///
  /// The names of the rows go out with the failure, because a person reading `selection_mismatch`
  /// needs to know what else Logic had selected before they select again by hand.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// The row the edit was for, in the words the caller names it by, for example `note 1`.
    public let target: String

    /// Every row the table reported as selected, in the order it reported them. The target is one
    /// of them when the table kept it.
    public let selected: [String]

    public init(target: String, selected: [String]) {
      self.target = target
      self.selected = selected
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(
        code: .selectionMismatch,
        message: "The selection holds more than \(target), nothing changed",
        details: .object(["selected": .array(selected.map { JSONValue.string($0) })]))
    }
  }

  /// The rows Logic held selected before the guard wrote, and whether they went back.
  ///
  /// The guard is a value, and the command that holds it does not change while it acts, so what one
  /// edit read and what its write back answered live here. The run of the command reads them after
  /// the action, and joins them to the one answer it prints.
  public final class Kept {
    /// The rows the table reported before the guard wrote, or nothing when the guard never wrote.
    public private(set) var before: [String]?

    /// Whether the rows went back, or nothing when the guard wrote none back.
    public private(set) var restored: Bool?

    public init() {}

    /// What the answer of a command says about the selection, or nothing when there is nothing to
    /// say. Rows that went back change no answer.
    public var details: JSONValue? {
      guard restored == false, let before else {
        return nil
      }
      return .object([
        "selectionRestored": .bool(false),
        "selectionBefore": .array(before.map(JSONValue.string)),
      ])
    }

    /// Keeps the rows the table reported before a write.
    func read(_ rows: [String]) {
      before = rows
    }

    /// Keeps what the readback of the write back answered.
    func wentBack(_ answer: Bool) {
      restored = answer
    }
  }

  /// Sets the selected rows of the table to the rows named, and to nothing else.
  ///
  /// One closure takes the whole selection, so the caller decides whether Logic is told row by row
  /// or in one write, and the guard reads the same either way.
  public typealias Select = ([String]) throws -> Void

  /// Reads every row the table reports as selected.
  public typealias ReadSelection = () throws -> [String]

  /// Sets the selection of the table.
  public let select: Select

  /// Reads the selection of the table back.
  public let selection: ReadSelection

  /// What the guard read before it wrote, and what its write back answered.
  public let kept: Kept

  public init(select: @escaping Select, selection: @escaping ReadSelection, kept: Kept = Kept()) {
    self.select = select
    self.selection = selection
    self.kept = kept
  }

  /// Selects one row alone, and throws when the selection holds anything else.
  ///
  /// The selection is read first, because nothing else knows what the person had selected once the
  /// write has landed. The guard then writes once. A table that answered another selection is a
  /// Logic that is doing something else, so a second write would aim an edit at a state nobody
  /// read.
  public func selectOnly(_ target: String) throws {
    kept.read(try selection())
    try select([target])
    let held = try selection()
    guard held == [target] else {
      throw Refusal(target: target, selected: held)
    }
  }

  /// Selects the rows the table reported before the guard wrote, and reads them back.
  ///
  /// A selection is the progress of the person at the keyboard, so an edit gives it back when it
  /// ends. This never fails the command: the edit is done, and a selection that did not go back is
  /// something the answer says rather than something a caller acts on.
  public func putTheSelectionBack() {
    guard let before = kept.before else {
      return
    }
    do {
      try select(before)
      kept.wentBack(try selection() == before)
    } catch {
      kept.wentBack(false)
    }
  }
}
