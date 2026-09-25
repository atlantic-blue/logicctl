import Foundation
import LogicctlCore
import LogicctlMac
import Testing

/// Where the trees that `inspect` recorded from Logic 12.3.1 sit.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(Locators.recordedFrom)")

/// The element a recorded tree starts at.
private func treeRoot(of file: String) throws -> any AXNode {
  try RecordedTree(contentsOf: fixtureFolder.appending(path: file)).root
}

/// Everything the question about the tempo says, heading first.
///
/// The second line is why a person would answer No: the tempo of the file replaces the tempo of
/// the project, and the audio that is already recorded goes out of time with it. A read that kept
/// the heading alone would ask the person to choose with the cost of the choice left out.
private let theTempoQuestion =
  "Also import tempo information?\n"
  + "This will replace the project\u{2019}s current tempo information in the range of the MIDI "
  + "file. Consider that the sequencer tempo will get out of sync with any previously recorded "
  + "audio tracks, unless those are in Flex mode!"

/// A person reads what Logic asked, and which answers it offers, without opening Logic.
///
/// logicctl answers no dialog. So a command that meets one stops with `dialog_open`, and what the
/// window says is all the person has to go on. A read that dropped a button would leave the way
/// out of it unnamed, and a read that kept one line of two would leave them choosing without the
/// part that tells them which answer they want.
///
/// The second half is the closure doing its job. A tree on its own is not a dialog. Logic shows
/// windows all the time and waits on almost none of them, and a command that stopped for one of
/// those would refuse work Logic was ready to take.
@Test func dialogReaderReadsTheTempoQuestion() throws {
  let tree = try treeRoot(of: "tempo-question.json")

  let waiting = DialogReader(modal: { _ in true }).dialog(in: tree)

  #expect(waiting?.text == theTempoQuestion, "everything the window says, in the order it reads")
  #expect(
    waiting?.buttons == ["No", "Import Tempo", "Cancel"],
    "the answers Logic offers, in the order it offers them")

  let nothingWaiting = DialogReader(modal: { _ in false }).dialog(in: tree)

  #expect(nothingWaiting == nil, "a window Logic is not waiting on stops no command")
}
