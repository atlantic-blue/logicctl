import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// The version of Logic the recorded tree came from.
private let renameRecordedVersion = "12.3.1"

/// Where the recorded trees sit. They are read from the source tree, because the folder sits
/// beside the test targets rather than inside one.
private let renameRecordedTrees = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(renameRecordedVersion)")

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class RenameTime {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// What one run of the command wrote, on each channel, and the number it exited with.
private final class RenameAnswer {
  var out = ""
  var err = ""
  var status: Int32 = 0

  func write(_ text: String) {
    out += text
  }

  func writeError(_ text: String) {
    err += text
  }

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// The row the answer carries under `data.track`.
  func row() throws -> [String: Any] {
    let data = try printed()["data"] as? [String: Any] ?? [:]
    return data["track"] as? [String: Any] ?? [:]
  }

  /// The code of the failure the answer carries, or nil when it carries none.
  func failureCode() throws -> String? {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["code"] as? String
  }

  /// What the failure says in `details`, or an empty object when it says nothing.
  func failureDetails() throws -> [String: Any] {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["details"] as? [String: Any] ?? [:]
  }
}

/// What the Logic of a test was asked to write, and where.
private final class Field {
  /// Every write that reached Logic, in the order it reached it.
  var written: [(locator: Locator, text: String)] = []

  /// The name of the field the last write went into.
  var lastLocatorName: String? {
    written.last?.locator.name
  }
}

/// A folder that carries no session, so nothing of a run reaches the disk.
private func noSessionFolder() -> URL {
  URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "logicctl-no-session")
}

/// A project that holds these tracks, open in Logic, saved nowhere.
private func aLogicHoldingTracks(_ tracks: [Track]) -> FakeLogicDriver {
  FakeLogicDriver(tracks: tracks)
}

/// Runs `logicctl tracks rename` against a Logic that holds these tracks.
///
/// The words go through the parser of the subcommand first, exactly as a command line does, so a
/// name with nothing in it is refused there and the Logic below is never asked anything. The write
/// is what Logic does when the text reaches the name field, so a test says what its Logic makes of
/// it.
private func tracksRename(
  _ line: [String],
  driver: FakeLogicDriver,
  field: Field,
  root: URL? = nil,
  write: @escaping (FakeLogicDriver, String) -> Void
) -> RenameAnswer {
  let answer = RenameAnswer()
  let time = RenameTime()
  do {
    let command = try Tracks.Rename.parse(line)
    let actions = TrackActions(
      press: { _ in },
      write: { locator, text in
        field.written.append((locator: locator, text: text))
        write(driver, text)
      })
    answer.status = Tracks.Rename.answer(
      driver: driver,
      actions: actions,
      index: command.track.index,
      name: command.name,
      confirmed: command.guarded.confirm,
      root: root ?? noSessionFolder(),
      limitMs: 50,
      argv: line,
      clock: time.read,
      sleeper: time.sleep,
      standardOutput: answer.write,
      standardError: answer.writeError)
  } catch {
    answer.status = Logicctl.report(
      error,
      arguments: line,
      standardOutput: answer.write,
      standardError: answer.writeError)
  }
  return answer
}

/// The Logic of a test takes the name and shows it in the header of the track at that number.
private func aLogicThatTakesTheName(atIndex index: Int) -> (FakeLogicDriver, String) -> Void {
  { fake, text in
    guard let place = fake.state?.tracks.firstIndex(where: { $0.index == index }) else {
      return
    }
    fake.state?.tracks[place].name = text
  }
}

/// A person or an agent renames a track, and reads back the name Logic shows.
///
/// The answer carries the row of that track as the project holds it now: the number that names it
/// to every other `tracks` command, the name in its header, and the three buttons. The name is
/// read from Logic after the write and not taken from the flag, so the one answer says the rename
/// happened rather than that it was asked for. An agent renames a track and moves on, with no
/// second command to find out whether it worked, and the journal records a name the project really
/// carried.
@Test func renameReadsTheNewNameBack() throws {
  let driver = aLogicHoldingTracks([Track(index: 1, name: "Deluxe Classic", type: .other)])
  let field = Field()

  let answer = tracksRename(
    ["--index", "1", "--name", "Bass"],
    driver: driver,
    field: field,
    write: aLogicThatTakesTheName(atIndex: 1))

  #expect(answer.status == 0, "the command worked")
  #expect(try answer.printed()["error"] is NSNull, "so it carries no failure")
  #expect(answer.err == "", "and standard error stays empty")

  let row = try answer.row()
  #expect(row["index"] as? Int == 1, "the track the person named")
  #expect(row["name"] as? String == "Bass", "the name Logic shows in the header now")
  #expect(row["type"] as? String == "other", "the header says nothing about the kind of track")
  #expect(row["mute"] as? Bool == false, "a rename leaves the mute button alone")
  #expect(row["solo"] as? Bool == false, "and the solo button")
  #expect(row["arm"] as? Bool == false, "and the record enable button")
  #expect(driver.state?.tracks.count == 1, "the project holds the one track it held")
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and a newline")
}

/// Logic gives the track a name of its own, and the row carries that one.
///
/// The text a person types is what logicctl asks for, and Logic decides what the track is called.
/// A command that printed the text from the flag would report a name the project does not hold,
/// and every later command that looked for that name would find nothing.
@Test func theRowCarriesTheNameLogicShowsAndNotTheNameThatWasAsked() throws {
  let driver = aLogicHoldingTracks([Track(index: 1, name: "Deluxe Classic", type: .other)])
  let field = Field()

  let answer = tracksRename(
    ["--index", "1", "--name", "Bass"],
    driver: driver,
    field: field
  ) { fake, _ in
    fake.state?.tracks[0].name = "Bass 1"
  }

  #expect(answer.status == 0, "the command worked")
  #expect(try answer.row()["name"] as? String == "Bass 1", "the name Logic shows, not the flag")
  #expect(field.written.last?.text == "Bass", "logicctl asked for the name the person typed")
}

/// The write goes into the name field of the header of the track the person named.
///
/// The number a person types counts from 1 and a track header counts from 0, so a command that
/// passed the number straight through would rename the track under the one that was asked for.
@Test func theWriteGoesIntoTheNameFieldOfTheTrackThatWasNamed() throws {
  let driver = aLogicHoldingTracks([
    Track(index: 1, name: "Bass", type: .other),
    Track(index: 2, name: "Drums", type: .other),
  ])
  let field = Field()

  let answer = tracksRename(
    ["--index", "2", "--name", "Kit"],
    driver: driver,
    field: field,
    write: aLogicThatTakesTheName(atIndex: 2))

  #expect(answer.status == 0, "the command worked")
  #expect(
    field.lastLocatorName == Locators.trackNameField(number: 1).name,
    "the name field of the second track header, which counts from 0")
  #expect(driver.state?.tracks.first?.name == "Bass", "the first track keeps its name")
  #expect(try answer.row()["index"] as? Int == 2, "the row is the track that was named")
  #expect(try answer.row()["name"] as? String == "Kit", "with the name Logic shows now")
}

/// The field the rename writes into is the field the name is read from.
///
/// Both walks are `Locators.trackNameField`, put here to the tree that `inspect` recorded from
/// Logic 12.3.1. The tree also says what the live route is up against: the field carries one
/// action, `AXPress`, and its value is `0` rather than the name, so Logic may refuse a write of
/// the value attribute. The live acceptance of phase 2 answers that, and this test says which
/// element the answer is about.
@Test func theRenameWritesIntoTheFieldTheNameIsReadFrom() throws {
  let recorded = try RecordedTree(
    contentsOf: renameRecordedTrees.appending(path: "one-track.json"))

  let field = try LocatorResolver.element(
    of: Locators.trackNameField(number: 0), in: recorded.root)
  let tracks = try TrackReader.tracks(in: recorded.root)

  #expect(field.role == "AXTextField", "the name field of the track header")
  #expect((field.help ?? "").hasPrefix("Name field"), "Logic says so in the help text")
  #expect(field.description == "Deluxe Classic", "the name of the track is its description")
  #expect(tracks.first?.name == field.description, "which is the name the reader answers")
  #expect(field.value == "0", "the value of the field is not the name")
  #expect(field.actions == ["AXPress"], "and the one action Logic offers on it is a press")
}

/// A person or an agent renames a track to the name it already carries.
///
/// Nothing changes, and that is the answer: the row goes out and the command exits 0. A command
/// that waited for the name to change would give up here and report `timeout` on a project that
/// holds exactly what was asked for, so a replay of a session would fail on its second run.
@Test func renamingATrackToTheNameItAlreadyHasPrintsItsRow() throws {
  let driver = aLogicHoldingTracks([Track(index: 1, name: "Bass", type: .other)])
  let field = Field()

  let answer = tracksRename(
    ["--index", "1", "--name", "Bass"],
    driver: driver,
    field: field
  ) { _, _ in }

  #expect(answer.status == 0, "the command worked")
  #expect(try answer.printed()["error"] is NSNull, "nothing failed")
  #expect(try answer.row()["name"] as? String == "Bass", "the name the track carries")
}

/// Logic takes the write and the name does not change.
///
/// The read back is the whole of the evidence that the write did what it was asked to do. A
/// command that printed a row here would report a rename that Logic refused. It gives up at the
/// limit instead, with `timeout`, and it says how long it gave Logic, so a person runs it again
/// with a longer `--timeout`.
@Test func aWriteThatChangedNoNameFailsWithTimeout() throws {
  let driver = aLogicHoldingTracks([Track(index: 1, name: "Deluxe Classic", type: .other)])
  let field = Field()

  let answer = tracksRename(
    ["--index", "1", "--name", "Bass"],
    driver: driver,
    field: field
  ) { _, _ in }

  #expect(answer.status == 6, "the number the design system gives timeout")
  #expect(try answer.failureCode() == "timeout", "Logic did not show the new name")
  #expect(try answer.failureDetails()["waitedMs"] as? Int == 50, "how long Logic was given")
  #expect(field.written.count == 1, "the name was written once, and once only")
  #expect(driver.state?.tracks.first?.name == "Deluxe Classic", "the track keeps its name")
}

/// A person or an agent names a track the project does not have.
///
/// The refusal comes before anything is written, so the project is as it was, and the answer names
/// the number that was asked for. An agent reads `track_not_found`, exit 10 and the index, lists
/// the tracks, and asks again.
@Test func anIndexThatNamesNoTrackFailsBeforeAnythingIsWritten() throws {
  let driver = aLogicHoldingTracks([Track(index: 1, name: "Deluxe Classic", type: .other)])
  let field = Field()

  let answer = tracksRename(
    ["--index", "9", "--name", "Bass"],
    driver: driver,
    field: field,
    write: aLogicThatTakesTheName(atIndex: 9))

  #expect(answer.status == 10, "the number the design system gives track_not_found")
  #expect(try answer.failureCode() == "track_not_found", "the project has no track 9")
  #expect(try answer.failureDetails()["index"] as? Int == 9, "the answer names the number asked")
  #expect(try answer.printed()["data"] is NSNull, "a refusal carries no answer")
  #expect(field.written.isEmpty, "nothing was written into Logic")
  #expect(driver.state?.tracks.first?.name == "Deluxe Classic", "the project is as it was")
}

/// A person or an agent gives `--name` nothing.
///
/// Every track of Logic carries a name, so there is no name to write and no name to read back. The
/// refusal happens where the arguments are read, so Logic is never asked anything, the project of
/// the person is untouched, and the journal gains no step for a flag that was typed by mistake.
/// The person gets the same answer as for any other wrong flag: `invalid_argument`, one line on
/// standard error, and exit 2.
@Test func anEmptyNameStopsBeforeLogic() throws {
  let driver = aLogicHoldingTracks([Track(index: 1, name: "Deluxe Classic", type: .other)])
  let field = Field()

  let answer = tracksRename(
    ["--index", "1", "--name", ""],
    driver: driver,
    field: field,
    write: aLogicThatTakesTheName(atIndex: 1))

  #expect(answer.status == 2, "the number the design system gives invalid_argument")
  #expect(try answer.failureCode() == "invalid_argument", "the arguments were wrong")
  #expect(field.written.isEmpty, "nothing was written into Logic")
  #expect(driver.state?.tracks.first?.name == "Deluxe Classic", "the project is as it was")

  let printed = try answer.printed()
  let meta = printed["meta"] as? [String: Any]
  #expect(meta?["session"] is NSNull, "Logic was never asked, so no session was opened")
  #expect(meta?["step"] is NSNull, "and no step was written")
}

/// A person opens a project they wrote themselves, and an agent asks logicctl to rename a track.
///
/// The work in that project is theirs, so logicctl does not change it on its own word. The agent
/// reads `confirm_required` and exit 7, nothing is written into the header, and the project is as
/// the person left it. The person then says `--confirm`, and the same command goes through.
@Test func renamingATrackInAProjectLogicctlDidNotMakeNeedsConfirm() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-rename-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let driver = FakeLogicDriver(
    tracks: [Track(index: 1, name: "Deluxe Classic", type: .other)],
    project: "Their Sketch",
    path: "/Users/someone/Music/Their Sketch.logicx")
  let field = Field()

  let answer = tracksRename(
    ["--index", "1", "--name", "Bass"],
    driver: driver,
    field: field,
    root: root,
    write: aLogicThatTakesTheName(atIndex: 1))

  #expect(answer.status == 7, "the number the design system gives confirm_required")
  #expect(try answer.failureCode() == "confirm_required", "logicctl did not make this project")
  #expect(field.written.isEmpty, "nothing was written into Logic")
  #expect(driver.state?.tracks.first?.name == "Deluxe Classic", "the project of the person holds")
}
