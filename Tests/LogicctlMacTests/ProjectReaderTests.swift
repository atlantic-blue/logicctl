import Foundation
import LogicctlCore
import LogicctlMac
import Testing

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

/// A reader of a Mac where Logic runs, with the document and the title the test gives it.
private func reader(
  document: String? = nil,
  title: String? = nil,
  logic: RunningLogic? = RunningLogic(processID: 4321, showsAWindow: true)
) -> ProjectReader {
  ProjectReader(logic: { logic }, document: { document }, title: { title })
}

/// A command writes its work into the history of the project a person has open, and of no other.
///
/// A session is found by the path of the project, so this one read decides which journal every step
/// of every command lands in. A reader that answers the path of another project writes the work of
/// this one into the history of that one, and nothing later in the run can tell that it happened. A
/// reader that answers a path for a project Logic never saved is worse: it starts a history for a
/// project that is nowhere on disk, and the next command opens a second one.
@Test func projectReaderAnswersThePathOfTheOpenProject() throws {
  let open = reader(document: "file:///tmp/a%20b/Song.logicx/", title: "F-T13.logicx - Tracks")
  #expect(try open.path() == "/tmp/a b/Song.logicx", "where the project Logic has open sits")
  #expect(try open.name() == "F-T13", "what that project is called")
  #expect(try open.processID() == 4321, "the Logic the path was read from")

  let neverSaved = reader(document: nil, title: "F-T13.logicx - Tracks")
  #expect(try neverSaved.path() == nil, "a project Logic never saved sits nowhere")

  let noLogic = reader(logic: nil)
  #expect(throws: DriverRefusal.logicNotRunning) { try noLogic.path() }
  #expect(throws: DriverRefusal.logicNotRunning) { try noLogic.name() }
  #expect(throws: DriverRefusal.logicNotRunning) { try noLogic.processID() }
}

/// The name of a project can carry the words that separate it from the rest of the title.
///
/// Logic writes the title as the file of the project, then a dash, then what the window shows of
/// it. A cut at the first dash takes `A - B` down to `A`, and the journal of that project is then
/// named after a project that does not exist. The cut is made at the extension, which Logic writes
/// once.
@Test func aProjectNameCanCarryTheWordsThatSeparateItFromTheTitle() throws {
  #expect(try reader(title: "A - B.logicx - Tracks").name() == "A - B")
  #expect(try reader(title: "F-T0.logicx - Mixer: Tracks").name() == "F-T0", "the Mixer window")
  #expect(try reader(title: "Logic Pro").name() == nil, "a window that shows no project")
  #expect(try reader(title: nil).name() == nil, "a Logic that shows no window")
}

/// The name is read from a title Logic wrote, and not from one this test made up.
@Test func theNameOfARecordedProjectComesFromTheTitleOfItsWindow() throws {
  let recorded = try RecordedTree(contentsOf: fixtureFolder.appending(path: "one-track.json"))
  #expect(try reader(title: recorded.root.title).name() == "F-T0")
}

/// Logic writes the document of a window as a string, and an element can carry a url object there.
///
/// Measured on Logic 12.3.1 through System Events on 2026-09-25: the attribute of the main window
/// reads as the string `file:///private/tmp/logicctl-fixtures/F-T13.logicx/`. A reader that took
/// the string alone would answer nothing on a Mac that carries the url object, and every command
/// would then start a second history for the project that is open.
@Test func logicNamesItsDocumentAsAStringOrAsAUrlAndBothReadBack() throws {
  let written = "file:///private/tmp/logicctl-fixtures/F-T13.logicx/"
  let asUrl = try #require(URL(string: written))

  #expect(ProjectReader.text(ofDocument: written as AnyObject) == written)
  #expect(ProjectReader.text(ofDocument: asUrl as AnyObject) == written)
  #expect(ProjectReader.text(ofDocument: nil) == nil, "a window that carries no document")
  #expect(ProjectReader.text(ofDocument: 7 as AnyObject) == nil, "a number is no document")
}

/// Every form Logic writes a file url in reads back as the same path.
///
/// The measured form carries percent escapes and a trailing slash. Neither is promised, and a path
/// that keeps either one matches no session: `/tmp/a%20b/Song.logicx/` and `/tmp/a b/Song.logicx`
/// are two names for one project, and a session is found by the name.
@Test func everyFormOfTheDocumentUrlReadsBackAsOnePath() throws {
  #expect(try reader(document: "file:///tmp/Song.logicx").path() == "/tmp/Song.logicx")
  #expect(try reader(document: "file:///tmp/a%20b/Song.logicx/").path() == "/tmp/a b/Song.logicx")
  #expect(try reader(document: "file:///tmp/a b/Song.logicx/").path() == "/tmp/a b/Song.logicx")
}

/// A document that names no file is refused, rather than read as a path.
///
/// A text that is not a file url is a thing logicctl did not measure. Answering nothing there would
/// read as a project Logic never saved, and the command would start a history for a project that is
/// on disk. So the reader says what Logic answered and stops.
@Test func aDocumentThatNamesNoFileIsRefusedRatherThanReadAsAPath() throws {
  let refusal = try #require(throws: ProjectReader.Refusal.self) {
    try reader(document: "Song.logicx").path()
  }

  #expect(refusal.failure.code == .internalFailure)
  #expect(refusal.failure.message.contains("Song.logicx"), "what Logic answered")
}
