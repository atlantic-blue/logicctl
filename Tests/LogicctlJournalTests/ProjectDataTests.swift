import Foundation
import LogicctlJournal
import Testing

/// The name Logic gives the plugin whose knob moved between the two saves.
private let theChangedPlugin = "Channel EQ"

/// Where the two saved projects sit.
///
/// The folder is read from the source tree, and not as a resource of this test target, because it
/// sits beside the test targets rather than inside one, and a file outside a target is not a
/// resource any target can carry. The recorded trees of Logic are read the same way.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/projectdata")

/// A person moved one knob of one plugin, and the journal names that plugin and no other.
///
/// The two files are one project, saved twice in one session of Logic. Between the saves, Peak 1
/// Gain of a Channel EQ went from 8.3 to 7.3 decibels. Nothing else was touched. So a reader of
/// the journal can say what a person did to the sound: the plugin whose hash moved is the one they
/// opened, and a plugin whose hash reads the same as the step before was not touched at all.
///
/// The second half matters as much as the first. A save rewrites bytes that belong to no plugin,
/// here one byte of the song chunk, so a hash taken over the whole file moves at every save and
/// answers the question wrongly every time. Every plugin the person left alone keeps its hash
/// through a save that changed another one.
@Test func aKnobChangeChangesOnlyItsPluginHash() throws {
  let before = try ProjectData.pluginChunks(ofFileAt: fixtureFolder.appending(path: "before"))
  let after = try ProjectData.pluginChunks(ofFileAt: fixtureFolder.appending(path: "after"))

  try #require(
    !before.isEmpty, "the saved project holds plugins, and a run that reads none proves nothing")
  try #require(
    before.map(\.offset) == after.map(\.offset),
    "the two saves hold the same plugins in the same places")

  let moved = zip(before, after).filter { $0.stateHash != $1.stateHash }
  let names = moved.map { $0.0.name ?? "a plugin with no name" }
  #expect(moved.count == 1, "one knob moved, so one hash moved, and these moved: \(names)")
  #expect(
    moved.first?.0.name == theChangedPlugin,
    "the hash that moved belongs to the plugin whose knob moved")
  #expect(
    zip(before, after).filter { $0.stateHash == $1.stateHash }.count == before.count - 1,
    "every plugin the person left alone keeps its hash through the save")
}
