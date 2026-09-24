import Foundation
import LogicctlCore
import Testing

/// The state of a project with one track, before anything changed it.
private func aProjectWithOneTrack() -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: "Untitled"),
    transport: Transport(tempo: 120),
    tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
}

/// The same state, written with the keys in one order.
private let oneOrder = """
  {
    "transport": { "tempo": 120, "recording": false, "playing": false },
    "tracks": [
      {
        "type": "software-instrument", "solo": false, "regions": [], "plugins": [],
        "name": "Inst 1", "mute": false, "index": 1, "arm": false
      }
    ],
    "schema": 1,
    "project": { "savedAt": null, "name": "Untitled" },
    "logic": { "version": "12.3.1" }
  }
  """

/// The same state again, written with the keys in another order and with no white space.
private let anotherOrder = """
  {"project":{"name":"Untitled","savedAt":null},"schema":1,\
  "logic":{"version":"12.3.1"},\
  "transport":{"playing":false,"tempo":120,"recording":false},\
  "tracks":[{"index":1,"name":"Inst 1","type":"software-instrument","mute":false,\
  "solo":false,"arm":false,"regions":[],"plugins":[]}]}
  """

/// The one canonical text of that state.
private let canonicalText = """
  {"logic":{"version":"12.3.1"},"project":{"name":"Untitled","savedAt":null},"schema":1,\
  "tracks":[{"arm":false,"index":1,"mute":false,"name":"Inst 1","plugins":[],"regions":[],\
  "solo":false,"type":"software-instrument"}],\
  "transport":{"playing":false,"recording":false,"tempo":120}}
  """

/// The hash of that text, taken outside logicctl.
private let canonicalHash = "f5a4cb24fe7a6c72273c53be614a07546900c5433df4dcb2999cf4581f6d1579"

/// A person reads a session and asks one question of each step: what did this step change? The
/// answer has to be one line, not a whole state, or nobody reads it. Muting track 1 says
/// `/tracks/0/mute`, false before and true after, and says nothing else.
///
/// The hash answers the other question: are these two states the same one? Two states that hold
/// the same fields answer yes, whatever order the fields arrived in, so a command can compare
/// what Logic shows now with what the last step wrote without reading either state field by
/// field.
@Test func aMuteChangeIsOneDifference() throws {
  let before = aProjectWithOneTrack()
  var after = before
  after.tracks[0].mute = true

  let differences = StateDiff.between(before, after)
  let theMute = Difference(path: "/tracks/0/mute", before: .bool(false), after: .bool(true))
  #expect(differences.count == 1, "one field changed, so the step reports one line")
  #expect(differences == [theMute], "and the line names the field, what it held and what it holds")

  let one = try CanonicalJSON.value(of: oneOrder)
  let other = try CanonicalJSON.value(of: anotherOrder)
  #expect(
    CanonicalJSON.sha256(of: one) == CanonicalJSON.sha256(of: other),
    "the same state written two ways is the same state")
  #expect(
    CanonicalJSON.sha256(of: before) == CanonicalJSON.sha256(of: one),
    "and the state logicctl read is that state too")
  #expect(CanonicalJSON.text(of: before) == canonicalText, "the canonical text sorts the keys")
  #expect(CanonicalJSON.sha256(of: before) == canonicalHash, "and the hash is of that text")
}

/// A state that nothing changed reports nothing, so a step that changed nothing says so.
@Test func anUnchangedStateHasNoDifferences() {
  let state = aProjectWithOneTrack()
  #expect(StateDiff.between(state, state).isEmpty)
}

/// A track that Logic added is one added line. Nothing was there before, so the line carries no
/// before, which is not the same as a before that is null.
@Test func aTrackAddedIsOneDifferenceWithNoBefore() {
  let before = aProjectWithOneTrack()
  var after = before
  after.tracks.append(Track(index: 2, name: "Audio 1", type: .audio))

  let differences = StateDiff.between(before, after)
  #expect(differences.count == 1)
  #expect(differences.first?.path == "/tracks/1")
  #expect(differences.first?.before == nil, "the field was added, so there is no before")
  #expect(differences.first?.after != nil)
}

/// A tempo that a person changed reads as a number, not as a text, and the number carries no
/// fraction it does not need. The hash of two states that hold the same tempo must be the same
/// one, whichever of the two wrote it.
@Test func aNumberIsTheShortestExactDecimal() {
  #expect(CanonicalJSON.text(of: .number(120)) == "120")
  #expect(CanonicalJSON.text(of: .number(120.5)) == "120.5")
  #expect(CanonicalJSON.text(of: .number(-0.25)) == "-0.25")
  #expect(CanonicalJSON.text(of: .array([.number(1), .number(2)])) == "[1,2]")
}

/// A pointer names one field of the state, and it stays readable when a name carries one of the
/// two characters a pointer cannot say plainly.
@Test func aPointerEscapesTheTwoCharactersItCannotCarry() {
  let before = JSONValue.object(["a/b": .number(1), "c~d": .number(1)])
  let after = JSONValue.object(["a/b": .number(2), "c~d": .number(2)])
  #expect(StateDiff.between(before, after).map(\.path) == ["/a~1b", "/c~0d"])
}

/// `state.json` is read by a person through git, one field to a line, so a step shows what it
/// changed in the diff of the file as well as in its own list.
@Test func stateJsonIsSortedAndIndentedByTwoSpaces() {
  let text = CanonicalJSON.text(of: aProjectWithOneTrack(), indent: 2)
  let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  #expect(lines.first == "{")
  #expect(lines.contains("  \"logic\": {"))
  #expect(lines.contains("    \"version\": \"12.3.1\""))
  #expect(lines.last == "}")
}
