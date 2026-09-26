import Foundation
import LogicctlMac
import Testing

/// A tree as `inspect` writes one: several elements, at more than one depth, and each of them
/// leaving out the keys Logic carried nothing for. The elements are the ones the probe read from
/// Logic 12.3.1, and the last of them is a slider of the Event List, which shows one number and
/// holds another.
private let recordedText = """
  {
    "logicVersion": "12.3.1",
    "root": {
      "role": "AXApplication",
      "title": "Logic Pro",
      "children": [
        {
          "role": "AXWindow",
          "title": "T3b - Tracks",
          "identifier": "_NS:32",
          "actions": ["AXRaise"],
          "children": [
            {
              "role": "AXGroup",
              "description": "Tracks header",
              "children": [
                {
                  "role": "AXLayoutItem",
                  "title": "Track 2 “Deluxe Classic”",
                  "help": "Track 2",
                  "actions": ["AXPress"],
                  "children": []
                },
                {
                  "role": "AXButton",
                  "description": "audio plug-in",
                  "help": "Audio Effect slot",
                  "value": "Compressor",
                  "actions": ["AXPress", "AXShowMenu"],
                  "children": []
                }
              ]
            }
          ]
        },
        {
          "role": "AXWindow",
          "title": "Mixer",
          "children": []
        },
        {
          "role": "AXWindow",
          "title": "T3b - MIDI Region - Event List",
          "children": [
            {
              "role": "AXSlider",
              "value": "3358588928",
              "valueDescription": "100",
              "actions": ["AXIncrement", "AXDecrement"]
            }
          ]
        }
      ]
    }
  }
  """

/// A command that walks the tree of Logic is proved where no Logic runs.
///
/// The pipeline has no Logic, so a driver that reads a running application alone can be built
/// there and never tested. `inspect` writes down the tree that Logic 12.3.1 showed, and this
/// reader answers from that file: the same roles, the same titles and the same children, at every
/// depth, and nothing where the file wrote nothing. What a locator finds in the file is therefore
/// what it finds in the Logic the file came from.
@Test func aRecordedTreeReadsBackAsWritten() throws {
  let file = try writeToATemporaryFile(recordedText)
  defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

  let tree = try RecordedTree(contentsOf: file)
  let written = try asObject(recordedText)
  let writtenRoot = try #require(written["root"] as? [String: Any])

  #expect(tree.logicVersion == written["logicVersion"] as? String, "the version of Logic")
  let read = compare(tree.root, with: writtenRoot, at: "root")
  #expect(read == 8, "every element the file carries reads back, and none is dropped")
}

/// A number Logic shows on a slider is not the number the slider holds.
///
/// The velocity of a note reads 100 in the Event List, and the value under it is 3358588928, a
/// scaled 32 bit number that no reader turns back into a velocity. So the text Logic shows is the
/// only place the velocity is, and a file that drops it cannot answer what a note was played at.
/// The file a person records on this Mac is the only route to a pipeline with no Logic, so the
/// tree goes out through the writer, comes back through the reader, and still says 100.
@Test func aSliderKeepsTheNumberLogicShowsOnIt() throws {
  let written = try JSONDecoder().decode(RecordedTree.self, from: Data(recordedText.utf8))
  let slider = try #require(sliderOfTheEventList(in: written.root), "the tree carries the slider")
  #expect(slider.valueDescription == "100", "the reader carries what Logic shows")
  #expect(slider.value == "3358588928", "and the number under it, which is not the same")

  let file = try aTemporaryFile()
  defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
  try TreeWriter.write(
    LogicTree(logicVersion: written.logicVersion, root: written.root), depth: 5, to: file)

  let readBack = try RecordedTree(contentsOf: file)
  #expect(readBack == written, "every element survives the file it was written to")
  #expect(
    sliderOfTheEventList(in: readBack.root)?.valueDescription == "100",
    "the writer keeps what Logic shows on the slider")
}

/// The slider of the Event List window, or nothing when the tree carries none.
private func sliderOfTheEventList(in root: RecordedAXNode) -> RecordedAXNode? {
  for window in root.recordedChildren where window.title?.hasSuffix("Event List") == true {
    return window.recordedChildren.first { $0.role == "AXSlider" }
  }
  return nil
}

/// Compares one element with what the file wrote for it, and answers how many elements it read:
/// this one and every element under it.
@discardableResult
private func compare(_ node: any AXNode, with written: [String: Any], at path: String) -> Int {
  #expect(node.role == written["role"] as? String, "role at \(path)")
  #expect(node.title == written["title"] as? String, "title at \(path)")
  #expect(node.identifier == written["identifier"] as? String, "identifier at \(path)")
  #expect(node.value == written["value"] as? String, "value at \(path)")
  #expect(
    node.valueDescription == written["valueDescription"] as? String,
    "valueDescription at \(path)")
  #expect(node.description == written["description"] as? String, "description at \(path)")
  #expect(node.help == written["help"] as? String, "help at \(path)")
  #expect(node.orientation == written["orientation"] as? String, "orientation at \(path)")
  #expect(node.actions == (written["actions"] as? [String] ?? []), "actions at \(path)")

  let writtenChildren = written["children"] as? [[String: Any]] ?? []
  #expect(node.children.count == writtenChildren.count, "children at \(path)")

  var read = 1
  for (index, child) in node.children.enumerated() where index < writtenChildren.count {
    read += compare(child, with: writtenChildren[index], at: "\(path).children[\(index)]")
  }
  return read
}

/// Writes the text to a file in a folder of its own, and answers the file.
private func writeToATemporaryFile(_ text: String) throws -> URL {
  let file = try aTemporaryFile()
  try text.write(to: file, atomically: true, encoding: .utf8)
  return file
}

/// A file in a folder of its own, for a tree to be written to.
private func aTemporaryFile() throws -> URL {
  let folder = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "logicctl-recorded-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder.appending(path: "tree.json")
}

/// The object a piece of JSON text carries, read by a reader that is not the one under test.
private func asObject(_ text: String) throws -> [String: Any] {
  let read = try JSONSerialization.jsonObject(with: Data(text.utf8))
  return read as? [String: Any] ?? [:]
}
