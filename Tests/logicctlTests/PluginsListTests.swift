import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// The version of Logic every recorded tree came from.
private let recordedVersion = "12.3.1"

/// Where the recorded trees sit. They are read from the source tree, because the folder sits beside
/// the test targets rather than inside one.
private let recordedTrees = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// What one run of the command wrote, on each channel, and the number it exited with.
private struct Answer {
  let out: String
  let err: String
  let status: Int32

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// What the answer carries under `data`.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }

  /// The rows the answer carries under `data.plugins`.
  func rows() throws -> [[String: Any]] {
    try data()["plugins"] as? [[String: Any]] ?? []
  }

  /// The error the answer carries, or an empty object when it carried none.
  func error() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }
}

/// A tree of one window, as `inspect` recorded it from Logic 12.3.1.
private func recorded(_ tree: String) throws -> LogicTree {
  let read = try RecordedTree(contentsOf: recordedTrees.appending(path: tree))
  return LogicTree(logicVersion: read.logicVersion, root: read.root)
}

/// The project the Mixer tree was recorded from: one software instrument track, named as Logic
/// names both the track and its channel strip.
private func aProjectOfOneTrack() -> [Track] {
  [Track(index: 1, name: "Deluxe Classic", type: .other)]
}

/// Runs `logicctl plugins list --track <n>` against a Logic that shows this window.
///
/// The project sits nowhere, which is a project that was never saved, so there is no session to
/// write a step into and nothing of this run touches the disk.
private func pluginsList(
  of window: LogicTree, track: String = "1", tracks: [Track] = aProjectOfOneTrack()
) throws -> Answer {
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(["plugins", "list", "--track", track])
  let list = try #require(typed as? Plugins.List)
  let status = list.answer(
    driver: FakeLogicDriver(tracks: tracks),
    of: { window },
    root: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A person asks what is on a track, and reads the chain Logic has on it, in the order Logic has
/// it in.
///
/// The chain is the answer to the question. An agent that is about to insert a compressor reads
/// this first to see whether one is there, and a person comparing a session with what they did by
/// hand reads it to see what the session put on the track. Two things make the answer worthless.
///
/// A channel strip holds more than its plugins, and one of the things it holds looks like a plugin
/// from below: the automation group carries a check box and a button named `list`, in the shape a
/// plugin slot carries them. A reader that takes every group of the strip prints that group as
/// slot 1, so the first plugin of the track is a control that nobody calls a plugin, and every
/// slot number after it is one too high. An empty slot is the same problem the other way: Logic
/// keeps a button for every slot a person can fill, so a strip of two plugins prints five rows,
/// two of which are named `audio plug-in`.
///
/// And the order is what the slot number means. Logic answers the children of a strip from the
/// bottom of the strip upwards, while slot order runs from the instrument down the channel strip.
/// It is the second order that Logic writes the plugin chunks of a saved project in, and the
/// journal matches those chunks against this list by position to hash the settings of each plugin.
/// So a reader that keeps the order Accessibility answers prints the chain upside down, and the
/// journal then records the settings of one plugin under the name of another.
///
/// The tree is the one `inspect` recorded from Logic 12.3.1 for a project of one track. Logic
/// shows an E-Piano and a Channel EQ on it, and the order is the order the saved project of four
/// tracks reads in `WatchRunTests`, where the same two plugins were measured from the file.
@Test func pluginsListInSlotOrder() throws {
  let answer = try pluginsList(of: recorded("mixer.json"))

  let rows = try answer.rows()
  try #require(rows.count == 2, "the strip holds two plugins, and five slots that are not plugins")

  #expect(try answer.data()["track"] as? Int == 1, "the number the command took")
  let first = try #require(rows.first)
  #expect(first["slot"] as? Int == 1, "the slot the plugin sits in, from 1")
  #expect(first["name"] as? String == "E-Piano", "the instrument of the track is the first slot")
  #expect(first["stateHash"] is NSNull, "no project was saved, so no settings were hashed")

  let names = rows.compactMap { $0["name"] as? String }
  #expect(
    names == ["E-Piano", "Channel EQ"],
    "the order Logic writes the plugins of the track in, and not the order it answers them in")
  #expect(rows.map { $0["slot"] as? Int } == [1, 2], "numbered from 1, in slot order")
  #expect(rows.allSatisfy { $0["stateHash"] is NSNull }, "a hash comes from a save, not a window")
  #expect(
    names.allSatisfy { !theSlotsThatAreNotPlugins.contains($0) },
    "no empty slot, no insert bar and no automation group is printed as a plugin")
  #expect(answer.status == 0, "the command exits 0")
  #expect(answer.err == "", "standard error stays empty when a command worked")
}

/// What the strip carries beside its plugins, which no row of the answer names.
private let theSlotsThatAreNotPlugins = [
  "audio plug-in", "MIDI plug-in", "insert bar", "Read, automation enabled",
]

/// A number that names no track is refused before the Mixer is read.
///
/// The Mixer shows the output strip and the master strip after the strips of the tracks, so the
/// second strip of a project of one track is `Stereo Out`. A command that took the strip at the
/// number it was given would print the plugins of the output of the project as the plugins of
/// track 2, and the answer would say track 2. The state says how many tracks there are, so the
/// number is refused against it first.
@Test func aNumberThatNamesNoTrackStopsWithTrackNotFound() throws {
  let answer = try pluginsList(of: recorded("mixer.json"), track: "2")

  #expect(answer.status == 10, "the exit number of track_not_found")
  #expect(try answer.error()["code"] as? String == "track_not_found", "the code a caller reads")
  #expect(
    try (answer.error()["message"] as? String)?.contains("2") == true,
    "the message names the number that was asked for")
  #expect(try answer.rows().isEmpty, "nothing of the Mixer is printed for a track that is not one")
}

/// Logic shows the channel strips in the Mixer, and logicctl does not open it.
///
/// A person who runs this with the Mixer closed reads a sentence that says to open it, rather than
/// an empty list that reads exactly like a track with no plugin on it.
@Test func aProjectWithNoMixerSaysToOpenIt() throws {
  let answer = try pluginsList(of: recorded("one-track.json"))

  #expect(answer.status == 5, "the exit number of element_not_found")
  #expect(try answer.error()["code"] as? String == "element_not_found", "the code a caller reads")
  #expect(
    try (answer.error()["message"] as? String)?.contains("Open the Mixer") == true,
    "the message says what to do")
}
