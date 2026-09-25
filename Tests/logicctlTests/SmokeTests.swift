import Foundation
import Testing

/// The root of the repository, found from this file.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

/// The windows Logic holds open while every read answers, measured on this Mac on 2026-09-25.
private let windowsToOpen = "the Mixer open and the Event List of the region open"

/// What one smoke run printed, on both channels, and the status it ended with.
private struct Run {
  let status: Int32
  let text: String
}

/// A logicctl that answers each read and writes down every command it was asked.
///
/// The pipeline has no Logic, so the run under test drives this binary instead of the signed one.
/// The file it writes is the evidence of a refusal: a run that stops before the first read leaves
/// it empty, and a run that stops after `status` leaves one line in it.
private struct Stub {
  /// The folder that holds the program and its record.
  let folder: URL

  /// What the run is given as the binary to drive.
  var binary: URL { folder.appending(path: "logicctl.ts") }

  /// Where the program writes one line per command.
  var record: URL { folder.appending(path: "asked.txt") }

  /// The commands the program was asked, in the order they reached it.
  func asked() -> [String] {
    guard let text = try? String(contentsOf: record, encoding: .utf8) else {
      return []
    }
    return text.split(separator: "\n").map(String.init)
  }
}

/// The program the stub runs. It answers the shape of each envelope, never a recorded one.
private let stubProgram = """
  #!/usr/bin/env -S node --experimental-strip-types
  import { appendFileSync } from "node:fs";

  const asked = process.argv.slice(2).join(" ");
  appendFileSync(process.env.SMOKE_RECORD ?? "", `${asked}\\n`);

  const meta = {
    version: "0.1.0+stub",
    session: null,
    step: null,
    externalChange: null,
    durationMs: 1,
  };

  if (asked === (process.env.SMOKE_FAILING ?? "")) {
    const error = {
      code: "element_not_found",
      message: "Nothing matched the locator eventList.table.",
      details: { locator: "eventList.table" },
    };
    console.log(JSON.stringify({ data: null, error, meta }));
    process.exit(5);
  }

  const noun = asked.split(" ")[0] ?? "";
  const answers: Record<string, unknown> = {
    status: {
      running: true,
      frontmost: true,
      window: process.env.SMOKE_WINDOW ?? "F-T13.logicx - Tracks",
      version: "12.3.1",
    },
    tracks: { tracks: [] },
    midi: { notes: [] },
    automation: { points: [] },
    plugins: { plugins: [] },
  };
  console.log(JSON.stringify({ data: answers[noun] ?? {}, error: null, meta }));
  """

/// Writes the stub into a folder of its own, and answers where it sits.
private func stub(under folder: URL) throws -> Stub {
  let made = Stub(folder: folder.appending(path: "stub"))
  try FileManager.default.createDirectory(at: made.folder, withIntermediateDirectories: true)
  try stubProgram.write(to: made.binary, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: made.binary.path)
  return made
}

/// Runs the smoke script over the stub, as `make smoke` runs it.
private func smokeRun(
  project: String,
  over stub: Stub,
  track: String = "1",
  region: String = "1",
  window: String = "F-T13.logicx - Tracks",
  failing: String = ""
) throws -> Run {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["node", "--experimental-strip-types", "scripts/smoke.ts"]
  process.currentDirectoryURL = repositoryRoot

  var environment = ProcessInfo.processInfo.environment
  environment["PROJECT"] = project
  environment["TRACK"] = track
  environment["REGION"] = region
  environment["LOGICCTL_BINARY"] = stub.binary.path
  environment["SMOKE_RECORD"] = stub.record.path
  environment["SMOKE_WINDOW"] = window
  environment["SMOKE_FAILING"] = failing
  process.environment = environment

  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  let printed = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()

  return Run(status: process.terminationStatus, text: String(decoding: printed, as: UTF8.self))
}

/// Makes a folder with a project in it, and answers the path of the project.
private func project(named name: String, under folder: URL) throws -> String {
  let made = folder.appending(path: name)
  try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
  return made.path
}

/// The text of the Makefile at the root, on one line, whatever it does with white space.
private func makefile() throws -> String {
  let raw = try String(contentsOf: repositoryRoot.appending(path: "Makefile"), encoding: .utf8)
  return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// Whether this Mac has the Node the smoke run needs.
private func nodeIsThere() -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["node", "--version"]
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  do {
    try process.run()
  } catch {
    return false
  }
  process.waitUntilExit()
  return process.terminationStatus == 0
}

/// One command tells the operator that every read only command answers the real Logic with no
/// error, and it can never read a project of a person.
///
/// The five reads are the whole of what logicctl can ask Logic without changing the project, and
/// each one of them can go wrong on its own: a locator that moved, a window that is not open, a
/// grant this Mac took back. A person who has to type five commands and read five envelopes checks
/// none of them, so the merge before which nobody checked ships a tool that answers
/// `element_not_found` to every read.
///
/// The other half is the guard. A read only command still selects a region and opens the Event
/// List of it, so a run aimed at the wrong project puts the windows of somebody's own work in a
/// state they did not ask for, and the journal of it holds steps nobody typed. So a run reads a
/// copy under `/tmp` or it reads nothing at all, and the refusal lands before the first read.
///
/// Node is what the run is written in. A Mac without it fails this scenario, because a scenario
/// that passes by running nothing says the reads work when nobody asked them anything.
@Test func smokeRunReadsTheRealLogic() throws {
  try #require(nodeIsThere(), "the smoke run is Node, so a Mac without Node cannot prove it")

  let scratch = URL(fileURLWithPath: "/tmp")
    .appending(path: "logicctl-smoke-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: scratch) }

  let outside = repositoryRoot.appending(path: ".build/logicctl-smoke-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: outside) }

  let copy = try project(named: "F-T13.logicx", under: scratch)
  let ownWork = try project(named: "F-T13.logicx", under: outside)

  let everyRead = try stub(under: scratch)
  let read = try smokeRun(project: copy, over: everyRead, track: "3", region: "1")

  #expect(
    read.status == 0,
    "every read answered with no error, so the run says the tool works: \(read.text)")
  #expect(
    everyRead.asked() == [
      "status",
      "tracks list",
      "midi notes --track 3 --region 1",
      "automation list --track 3 --region 1",
      "plugins list --track 3",
    ],
    "the five reads of the tool ran, each with the track and the region the operator named")
  #expect(
    read.text.contains("\"window\":\"F-T13.logicx - Tracks\""),
    "the operator reads the envelope of each one, as Logic answered it")
  #expect(
    read.text.contains("reads: 5"),
    "and a count, so a run that asked nothing cannot read as a run that asked everything")

  let ownStub = try stub(under: outside)
  let refused = try smokeRun(project: ownWork, over: ownStub)

  #expect(
    refused.status != 0,
    "a project outside /tmp is somebody's own work, so the run stops: \(refused.text)")
  #expect(
    ownStub.asked().isEmpty,
    "and it stops before the first read, so the work is untouched")
  #expect(
    refused.text.contains(ownWork),
    "the refusal names the path it was given, so the operator sees which one it read")

  let mistaken = try stub(under: scratch.appending(path: "mistaken"))
  let wrong = try smokeRun(
    project: copy, over: mistaken, window: "Sketches.logicx - Tracks")

  #expect(
    wrong.status != 0,
    "a copy under /tmp that Logic does not have open is the same danger: \(wrong.text)")
  #expect(
    mistaken.asked() == ["status"],
    "so the run reads the window title and stops there, before the four reads that select a region")

  let broken = try stub(under: scratch.appending(path: "broken"))
  let red = try smokeRun(
    project: copy, over: broken, track: "3", failing: "automation list --track 3 --region 1")

  #expect(
    red.status != 0,
    "one read that fails fails the run, so a green run means every read answered: \(red.text)")
  #expect(
    red.text.contains("element_not_found"),
    "the code Logic answered reaches the operator")
  #expect(
    red.text.contains(windowsToOpen),
    "with the windows a read needs open, which is what that code usually means")

  let target = try makefile()
  #expect(
    target.contains("node --experimental-strip-types scripts/smoke.ts"),
    "make smoke is how the operator runs it, so it is one command and not five")
  #expect(
    target.contains("PROJECT"),
    "and it takes the copy from the operator, because no read only command answers the path")
  #expect(
    target.contains(windowsToOpen),
    "the Makefile says which windows to open, so the operator does not learn it from a failure")
  #expect(
    target.contains("codesign --verify"),
    "it drives the signed binary, because the two grants of this Mac key on the signature")
}
