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

/// The tempo a test hands the reader. The display of the running Logic is what answers it on this
/// Mac, and a pipeline has no running Logic.
private let aTempo = 96

/// A person reads whether Logic plays, and whether it records, from the two buttons Logic shows.
///
/// Every command reads the state before it acts and again after, so this pair goes into the
/// journal of every session. A read that answered the wrong control would write a transport there
/// that Logic never showed, and nothing later could tell that it happened.
///
/// The two trees are the same window in the two states. In the stopped one both buttons read 0. In
/// the playing one, recorded on this Mac while the copy played, the Play button reads 1 and the
/// Record button reads 0. The value the Record button takes while Logic records was not measured,
/// so nothing here says what it is.
///
/// The last two are what the reader refuses. A window that is not the Tracks window carries no
/// Play button at all, and the walk stops with the name of the locator, because that name is the
/// whole address a person has when a later Logic moves the path. A check box that carries the
/// title of the play button and is described as another control stops it too: Logic writes a title
/// for the language it runs in, so the title alone is not enough to believe the control.
@Test func transportReaderReadsThePlayButton() throws {
  let stopped = try TransportReader.transport(in: treeRoot(of: "one-track.json"), tempo: { aTempo })

  #expect(stopped.playing == false, "the Play button of the stopped window reads 0")
  #expect(stopped.recording == false, "the Record button of the stopped window reads 0")
  #expect(stopped.tempo == Double(aTempo), "the tempo the display answered")

  let playing = try TransportReader.transport(
    in: treeRoot(of: "control-bar-playing.json"), tempo: { aTempo })

  #expect(playing.playing == true, "Logic played while this tree was recorded")
  #expect(playing.recording == false, "it recorded nothing while it played")

  let missing = #expect(throws: LocatorResolver.Refusal.self) {
    try TransportReader.transport(in: treeRoot(of: "mixer.json"), tempo: { aTempo })
  }

  let noPlayButton = try #require(missing)
  #expect(noPlayButton.failure.code == .elementNotFound, "the code a caller reads")
  #expect(noPlayButton.failure.code.exitCode == 5, "the number the process exits with")
  #expect(
    locatorNamed(in: noPlayButton.failure) == Locators.transportPlayButton.name,
    "the failure names the walk that found nothing")

  let moved = try treeRead(from: aBarThatMoved).root
  let described = #expect(throws: TransportReader.Refusal.self) {
    try TransportReader.transport(in: moved, tempo: { aTempo })
  }

  let wrongControl = try #require(described)
  #expect(wrongControl.found == "Cycle", "what Logic said the control at the end of the walk was")
  #expect(wrongControl.failure.code == .elementNotFound, "the code a caller reads")
  #expect(
    locatorNamed(in: wrongControl.failure) == Locators.transportPlayButton.name,
    "the failure names the walk that reached the wrong control")
}

/// A Control Bar whose check box carries the title of the play button and is another control.
private let aBarThatMoved = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXWindow",
      "children": [
        {
          "role": "AXGroup",
          "children": [
            {
              "role": "AXCheckBox",
              "title": "Play",
              "description": "Cycle",
              "value": "1"
            }
          ]
        }
      ]
    }
  }
  """

/// A tree written in a test, read back the way a recorded tree is read.
private func treeRead(from text: String) throws -> RecordedTree {
  try JSONDecoder().decode(RecordedTree.self, from: Data(text.utf8))
}

/// The locator a failure names, or nil when it names none.
private func locatorNamed(in failure: Failure) -> String? {
  guard case .object(let fields)? = failure.details,
    case .string(let name)? = fields["locator"]
  else {
    return nil
  }
  return name
}
