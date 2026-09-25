import CryptoKit
import Foundation
import LogicctlCore
import Testing

@testable import logicctl

/// Where the fixture pair sits. The folder is read from the source tree, and not as a resource of
/// this test target, because it sits beside the test targets rather than inside one.
private let fixtureFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures")

/// A folder no other test writes into, for one test.
private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-midi-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A file of notes with a note that is never played.
private let aNoteWithNoVelocity = """
  {
    "tempo": 120,
    "notes": [{ "pitch": 60, "velocity": 0, "start": 0, "length": 1 }]
  }
  """

/// What one run wrote, on each channel.
private final class Answer {
  var out = ""
  var err = ""

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

  /// What the command answered with, or nothing when it failed.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }

  /// Why the command failed, or nothing when it worked.
  func failure() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }
}

/// The command line was not the one this test drives.
private struct NotTheCommand: Error {}

/// The command a person typed, read the way the tool reads it.
///
/// It goes through the root command, so a `midi write-file` that nobody can type does not reach
/// this test: the parser answers with something else, or with nothing, and the test stops here.
private func typed(_ arguments: [String]) throws -> Midi.WriteFile {
  guard let command = try Logicctl.parseAsRoot(arguments) as? Midi.WriteFile else {
    throw NotTheCommand()
  }
  return command
}

/// Some bytes as lowercase hexadecimal.
private func hexadecimal(of bytes: Data) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}

/// The first byte two files differ at, so one red run says which byte to look at.
private func difference(between written: Data, and recorded: Data) -> String {
  for (position, byte) in written.enumerated() where position < recorded.count {
    if byte != recorded[position] {
      return "byte \(position) is \(byte) and the recorded file carries \(recorded[position])"
    }
  }
  if written.count != recorded.count {
    return "the file is \(written.count) bytes and the recorded file is \(recorded.count)"
  }
  return "the two files are the same"
}

/// An agent asks for a file of notes and gets the same bytes every time.
///
/// Replay reads a session back and runs it again, and a session of phase 3 imports the MIDI file
/// that is kept in its step. So the bytes are worth something on their own: a writer that left the
/// notes in the order a person typed them, or that wrote a time of its own, would make every
/// replay of that session report a difference, and the difference would be in logicctl and not in
/// Logic. Here the same notes are written twice, to two paths, and both are the file that was
/// written from the format itself and recorded beside them.
///
/// The refusal carries the same value from the other side. A file with a note that is never
/// played stops at the command line. Nothing reaches Logic, no file is left where the good one
/// would have gone, and the answer names the field a person has to change.
@Test func theSameNotesGiveTheSameBytes() throws {
  let folder = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: folder) }

  let notes = fixtureFolder.appending(path: "notes.json")
  let recorded = try Data(contentsOf: fixtureFolder.appending(path: "notes.mid"))
  try #require(!recorded.isEmpty, "the recorded file carries no bytes, so this run proves nothing")

  let first = folder.appending(path: "first.mid")
  let second = folder.appending(path: "second.mid")
  let once = Answer()
  let again = Answer()
  let onceCode = try typed(["midi", "write-file", "--in", notes.path, "--out", first.path])
    .answer(standardOutput: once.write, standardError: once.writeError)
  let againCode = try typed(["midi", "write-file", "--in", notes.path, "--out", second.path])
    .answer(standardOutput: again.write, standardError: again.writeError)

  #expect(onceCode == 0, "writing a file of notes is not a failure: \(once.err)")
  #expect(againCode == 0, "the second run is not a failure either: \(again.err)")
  #expect(once.err == "", "nothing went wrong, so a person reading along is told nothing")

  let written = try Data(contentsOf: first)
  let writtenAgain = try Data(contentsOf: second)
  #expect(
    written == recorded,
    "the bytes are the file the format asks for: \(difference(between: written, and: recorded))")
  #expect(
    writtenAgain == recorded,
    "the same notes give the same bytes: \(difference(between: writtenAgain, and: recorded))")

  let answered = try once.data()
  #expect(answered["path"] as? String == first.path, "the answer names the file it wrote")
  #expect(answered["notes"] as? Int == 8, "the answer counts the notes it wrote")
  #expect(
    answered["sha256"] as? String == hexadecimal(of: Data(SHA256.hash(data: recorded))),
    "the answer carries the hash of the bytes, so two runs are compared without the files")

  let printed = try once.printed()
  #expect(printed["error"] is NSNull, "a run that worked carries no failure")
  let meta = printed["meta"] as? [String: Any]
  #expect(meta?["session"] is NSNull, "this command never reads Logic, so it has no session")
  #expect(meta?["step"] is NSNull, "and it writes no step")

  let silent = folder.appending(path: "silent.json")
  try Data(aNoteWithNoVelocity.utf8).write(to: silent)
  let refused = folder.appending(path: "silent.mid")
  let stopped = Answer()
  let stoppedCode = try typed(["midi", "write-file", "--in", silent.path, "--out", refused.path])
    .answer(standardOutput: stopped.write, standardError: stopped.writeError)

  #expect(stoppedCode == 2, "a file logicctl cannot use is a wrong argument, which exits 2")
  let why = try stopped.failure()
  #expect(why["code"] as? String == "invalid_argument", "the code a caller reads")
  #expect(
    why["message"] as? String == "notes[0].velocity must be 1 to 127",
    "the sentence says which field is wrong and what it must be")
  #expect(
    why["details"] as? [String: String] == ["field": "notes[0].velocity"],
    "details carries the field and nothing else")
  #expect(try stopped.printed()["data"] is NSNull, "a run that failed answers no data")
  #expect(
    stopped.err == "logicctl: invalid_argument: notes[0].velocity must be 1 to 127\n",
    "the person reading along is told the same thing in one line")
  #expect(
    !FileManager.default.fileExists(atPath: refused.path),
    "a refused run writes no file, so nothing is left for a later run to read as its own")
}
