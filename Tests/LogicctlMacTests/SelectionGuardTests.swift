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

/// The selection the guard read, the row it wrote, and the readback it stopped at.
private let oneReadThenAWriteAndAReadback = ["selection", "select note 1", "selection"]

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
  #expect(
    table.asked == oneReadThenAWriteAndAReadback,
    "the guard read the selection, wrote its own, and stopped at the readback")
}

/// The selection the guard asked for is the one the edit runs on, and the edit runs.
@Test func anEditRunsWhenTheSelectionHoldsItsTargetAlone() throws {
  let table = Table(holding: ["note 1"])

  try guarding(table).selectOnly("note 1")

  #expect(
    table.asked == oneReadThenAWriteAndAReadback,
    "the guard read the selection before it wrote, wrote once, and read it back")
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

/// A table that answers the selection it was last given, the way a table that works answers one.
///
/// The table above reports a selection of its own, which is the Logic the guard refuses. This one
/// takes a write and reads back what it took, so a test drives the write back and reads what Logic
/// holds at the end of an edit.
private final class ATableThatKeeps {
  /// The table refused a write.
  struct Refused: Error {}

  /// What the table holds selected, in the order it answers the rows.
  private(set) var holding: [String]

  /// What the guard asked of the table, in the order it asked.
  private(set) var asked: [String] = []

  /// True while the table takes a write and holds what it held, which is the Logic that keeps a
  /// row after an edit.
  var takesNoMoreWrites = false

  /// True while the table answers every write with an error.
  var refusesEveryWrite = false

  init(holding: [String]) {
    self.holding = holding
  }

  func select(_ rows: [String]) throws {
    asked.append("select \(rows.joined(separator: ", "))")
    if refusesEveryWrite {
      throw Refused()
    }
    guard !takesNoMoreWrites else {
      return
    }
    holding = rows
  }

  func selection() -> [String] {
    asked.append("selection")
    return holding
  }
}

/// A guard over one table that keeps what it is given.
private func guarding(_ table: ATableThatKeeps) -> SelectionGuard {
  SelectionGuard(select: table.select, selection: table.selection)
}

/// The rows a person had selected are the rows Logic holds when the edit ends.
///
/// A selection is work: it is how a person says which events they are looking at. The guard takes
/// it away to aim one edit, so the guard is what gives it back, and it reads the table before it
/// writes because nothing else knows what was there.
@Test func theGuardPutsBackTheRowsItReadBeforeItWrote() throws {
  let table = ATableThatKeeps(holding: ["note 2", "note 3"])
  let guarded = guarding(table)

  try guarded.selectOnly("note 1")
  guarded.putTheSelectionBack()

  #expect(table.holding == ["note 2", "note 3"], "the rows the person had selected are back")
  #expect(guarded.kept.before == ["note 2", "note 3"], "the guard kept what it read")
  #expect(guarded.kept.restored == true, "the readback answered the rows the write back wrote")
  #expect(guarded.kept.details == nil, "a selection that went back changes no answer")
  #expect(
    table.asked == [
      "selection", "select note 1", "selection", "select note 2, note 3", "selection",
    ],
    "the guard read, wrote its row, read that back, wrote the rows back and read those back")
}

/// A table that held nothing goes back to holding nothing.
///
/// An empty selection is a state a person can be in, and a write back that left the edited row
/// selected would be a change the person did not make.
@Test func theGuardPutsBackAnEmptySelectionAsEmpty() throws {
  let table = ATableThatKeeps(holding: [])
  let guarded = guarding(table)

  try guarded.selectOnly("note 1")
  guarded.putTheSelectionBack()

  #expect(table.holding == [], "Logic holds no row, as it held none before the edit")
  #expect(guarded.kept.before == [], "an empty selection is a selection the guard read")
  #expect(guarded.kept.restored == true, "the readback answered the empty selection it wrote")
  #expect(guarded.kept.details == nil, "a selection that went back changes no answer")
}

/// The guard writes back no selection that it did not read.
///
/// A command that stopped before it selected anything left the table as the person had it, so a
/// write back there would be the guard making up a selection of its own.
@Test func theGuardWritesBackNothingWhenItReadNothing() {
  let table = ATableThatKeeps(holding: ["note 2"])
  let guarded = guarding(table)

  guarded.putTheSelectionBack()

  #expect(table.asked == [], "the table was neither read nor written")
  #expect(table.holding == ["note 2"], "Logic holds what it held")
  #expect(guarded.kept.before == nil, "the guard read no selection")
  #expect(guarded.kept.details == nil, "there is nothing to say about a selection nobody wrote")
}

/// A Logic that keeps the row of the edit says so in the answer, and fails no command.
///
/// The edit is done by then. So the rows that did not go back are a note the answer carries, with
/// the names of the rows in it, and a person selects them again without opening Logic to look.
@Test func theGuardSaysSoWhenTheRowsDoNotGoBack() throws {
  let table = ATableThatKeeps(holding: ["note 2", "note 3"])
  let guarded = guarding(table)

  try guarded.selectOnly("note 1")
  table.takesNoMoreWrites = true
  guarded.putTheSelectionBack()

  #expect(table.holding == ["note 1"], "Logic kept the row the edit was aimed at")
  #expect(guarded.kept.restored == false, "the readback answered another selection")
  #expect(
    guarded.kept.details
      == .object([
        "selectionRestored": .bool(false),
        "selectionBefore": .array([.string("note 2"), .string("note 3")]),
      ]),
    "the answer names the rows the person had selected, in the order the table reported them")
}

/// A write back the table refuses is a selection that did not go back, and never a failure.
@Test func theGuardSaysSoWhenTheTableRefusesTheWriteBack() throws {
  let table = ATableThatKeeps(holding: ["note 2"])
  let guarded = guarding(table)

  try guarded.selectOnly("note 1")
  table.refusesEveryWrite = true
  guarded.putTheSelectionBack()

  #expect(guarded.kept.restored == false, "the table refused, so the rows are not back")
  #expect(
    guarded.kept.details
      == .object([
        "selectionRestored": .bool(false),
        "selectionBefore": .array([.string("note 2")]),
      ]),
    "the answer says the same thing whether Logic kept a row or refused the write")
}
