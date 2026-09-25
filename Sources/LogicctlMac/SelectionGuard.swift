import LogicctlCore

/// Puts the selection of the Event List on one row, and proves it is there alone before an edit.
///
/// Logic applies an edit to every item that is selected. So a command that quantizes note 1 while
/// the table still holds another row moves both notes, answers as though it moved one, and no
/// later read shows that the other one changed. The guard writes the selection, reads it back, and
/// stops the command when the readback holds anything besides the target.
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

  public init(select: @escaping Select, selection: @escaping ReadSelection) {
    self.select = select
    self.selection = selection
  }

  /// Selects one row alone, and throws when the selection holds anything else.
  ///
  /// The guard writes once. A table that answered another selection is a Logic that is doing
  /// something else, so a second write would aim an edit at a state nobody read.
  public func selectOnly(_ target: String) throws {
    try select([target])
    let held = try selection()
    guard held == [target] else {
      throw Refusal(target: target, selected: held)
    }
  }
}
