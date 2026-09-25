import LogicctlCore
import LogicctlMac
import Testing

/// A table of the Event List that reports one selection, whatever it is told to select.
///
/// Logic keeps rows selected that logicctl never asked for, which is the whole reason the guard
/// exists, so the table here answers a selection of its own rather than the rows it was given.
private final class Table {
  /// What the guard asked of the table, in the order it asked. A write reads `select note 1`, and
  /// a read of the selection reads `selection`.
  var asked: [String] = []

  /// What the table reports as selected.
  private let reports: [String]

  init(holding reports: [String]) {
    self.reports = reports
  }

  func select(_ rows: [String]) {
    asked.append("select \(rows.joined(separator: ", "))")
  }

  func selection() -> [String] {
    asked.append("selection")
    return reports
  }
}

/// A guard over one table.
private func guarding(_ table: Table) -> SelectionGuard {
  SelectionGuard(select: table.select, selection: table.selection)
}

/// The rows the guard wrote and read, and nothing after them.
private let oneWriteThenOneRead = ["select note 1", "selection"]

/// An edit of Logic reaches every row that is selected, and not the row a person named.
///
/// A person asks for note 1. The Event List still holds point 1 from whatever was done before, so
/// a quantize or a velocity change moves that point too, the command answers as though it moved
/// one thing, and nothing a person reads afterwards says the point changed. So the guard reads the
/// selection back before any edit runs, stops the command when the table kept another row, and
/// names both rows, so a person knows what Logic had selected.
@Test func anEditStopsWhenTheSelectionHoldsMore() throws {
  let table = Table(holding: ["point 1", "note 1"])
  let refused = #expect(throws: SelectionGuard.Refusal.self) {
    try guarding(table).selectOnly("note 1")
  }

  let failure = try #require(refused).failure
  #expect(failure.code == .selectionMismatch)
  #expect(failure.code.exitCode == 20, "the number the process exits with")
  #expect(failure.message == "The selection holds more than note 1, nothing changed")
  #expect(
    failure.details == .object(["selected": .array([.string("point 1"), .string("note 1")])]),
    "both rows, in the order Logic reported them")
  #expect(table.asked == oneWriteThenOneRead, "the guard stopped at the readback and wrote nothing")
}

/// The selection the guard asked for is the one the edit runs on, and the edit runs.
@Test func anEditRunsWhenTheSelectionHoldsItsTargetAlone() throws {
  let table = Table(holding: ["note 1"])

  try guarding(table).selectOnly("note 1")

  #expect(table.asked == oneWriteThenOneRead, "the guard wrote the selection once and read it back")
}

/// A selection that lost the target is as wrong as one that holds more.
///
/// The edit would reach point 1 and leave note 1 as it was, which is the same note changed that
/// nobody asked for, so the guard stops on any selection that is not the target alone.
@Test func anEditStopsWhenTheSelectionHoldsAnotherRowInsteadOfTheTarget() throws {
  let table = Table(holding: ["point 1"])
  let refused = #expect(throws: SelectionGuard.Refusal.self) {
    try guarding(table).selectOnly("note 1")
  }

  let failure = try #require(refused).failure
  #expect(failure.code == .selectionMismatch)
  #expect(failure.message == "The selection holds more than note 1, nothing changed")
  #expect(failure.details == .object(["selected": .array([.string("point 1")])]))
}

/// A table that selected nothing took the write and did something else with it.
///
/// An edit on an empty selection changes nothing in Logic and answers as though it worked, so the
/// guard stops there too rather than reporting a change that never happened.
@Test func anEditStopsWhenTheTableSelectedNothing() throws {
  let table = Table(holding: [])
  let refused = #expect(throws: SelectionGuard.Refusal.self) {
    try guarding(table).selectOnly("note 1")
  }

  let failure = try #require(refused).failure
  #expect(failure.code == .selectionMismatch)
  #expect(failure.details == .object(["selected": .array([])]))
}
