import Foundation
import LogicctlCore
import Testing

/// The approved design system, read from the file in the repository root.
private struct DesignSystem {
  let errors: [String: Int]
  let retiredErrors: [String: Int]

  init() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let raw = try Data(contentsOf: root.appending(path: "design-system.json"))
    let parsed = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
    errors = DesignSystem.numbers(parsed?["errors"])
    retiredErrors = DesignSystem.numbers(parsed?["retiredErrors"])
  }

  private static func numbers(_ raw: Any?) -> [String: Int] {
    guard let fields = raw as? [String: Any] else { return [:] }
    var found: [String: Int] = [:]
    for (name, value) in fields {
      if let number = value as? Int {
        found[name] = number
      }
    }
    return found
  }
}

/// What one run of the printer wrote, on each channel.
private final class Recorded {
  var out = ""
  var err = ""

  func printer(format: OutputFormat = .compact) -> EnvelopePrinter {
    EnvelopePrinter(
      format: format,
      standardOutput: { self.out += $0 },
      standardError: { self.err += $0 })
  }

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }
}

/// A person or an agent reads the number a command exited with, and always gets the same meaning
/// from it, because one approved file in the repository decides that number and the tool is held
/// to it here. A failure says the same thing on both channels: the envelope on standard output
/// carries the code, the sentence and nothing but the details, and standard error carries one line
/// for the person reading along.
@Test func everyErrorCodeExitsWithItsDesignSystemNumber() throws {
  let design = try DesignSystem()
  #expect(!design.errors.isEmpty, "the approved file was read")

  for (name, exitCode) in design.errors {
    guard let code = ErrorCode(rawValue: name) else {
      Issue.record("the design system gives \(name) a number, and logicctl cannot report it")
      continue
    }
    #expect(code.exitCode == Int32(exitCode), "\(name) exits with \(exitCode)")
  }

  for code in ErrorCode.allCases {
    #expect(design.errors[code.rawValue] != nil, "\(code.rawValue) is in the approved file")
  }

  #expect(design.retiredErrors["no_region_selected"] == 11, "11 stays with the code that retired")
  #expect(ErrorCode(rawValue: "no_region_selected") == nil, "and logicctl never reports it")
  #expect(!design.errors.values.contains(11), "so no other code is given 11")
  let takesEleven = ErrorCode.allCases.contains(where: { $0.exitCode == 11 })
  #expect(!takesEleven, "and nothing in logicctl exits with it")

  let failed = Recorded()
  let missing = Failure(
    code: .trackNotFound,
    message: "Track 9 is not in this project.",
    details: .object(["index": .number(9)]))
  let exitCode = failed.printer().write(.failure(missing, meta: Meta(version: "0.1.0")))

  #expect(exitCode == 10, "the exit code of a failure is the one its code carries")
  #expect(failed.out.hasSuffix("\n"), "the object ends with a newline")
  #expect(failed.out.filter { $0 == "\n" }.count == 1, "and the whole of it is one line")
  #expect(
    failed.err == "logicctl: track_not_found: Track 9 is not in this project.\n",
    "the person reading along gets one line")

  let envelope = try failed.printed()
  #expect(envelope.keys.sorted() == ["data", "error", "meta"], "the three keys are always there")
  #expect(envelope["data"] is NSNull, "a failure answers nothing")
  let error = envelope["error"] as? [String: Any] ?? [:]
  #expect(error.keys.sorted() == ["code", "details", "message"], "a failure carries these three")
  #expect(error["code"] as? String == "track_not_found", "by the name the design system gives")

  let worked = Recorded()
  let meta = Meta(version: "0.1.0", session: "aa11bb22", durationMs: 12)
  let good = worked.printer().write(.success(data: .object(["running": .bool(false)]), meta: meta))

  #expect(good == 0, "a command that worked exits with 0")
  #expect(worked.err.isEmpty, "and says nothing on standard error")
  let metaText =
    #""meta":{"durationMs":12,"externalChange":null,"session":"aa11bb22","#
    + #""step":null,"version":"0.1.0"}"#
  #expect(
    worked.out == #"{"data":{"running":false},"error":null,"# + metaText + "}\n",
    "one object, no white space, camel case keys, and a null for what nobody filled")
}

/// A person asks for the output they can read, and gets the same envelope laid out by two spaces
/// for each level, with the times in it written one way wherever they come from.
@Test func prettyOutputIndentsByTwoSpaces() throws {
  let recorded = Recorded()
  let start = Date(timeIntervalSince1970: 0)
  let data = JSONValue.object(["startedAt": .time(start), "name": .string("A \"quoted\" name")])
  recorded.printer(format: .pretty).write(.success(data: data, meta: Meta(version: "0.1.0")))

  let lines = recorded.out.split(separator: "\n", omittingEmptySubsequences: false)
  #expect(lines.first == "{", "the object opens on its own line")
  #expect(lines.contains("  \"data\": {"), "a key of the envelope is two spaces in")
  let quoted = "    \"name\": \"A \\\"quoted\\\" name\","
  #expect(lines.contains(quoted[...]), "its own keys are four spaces in, and a quote is escaped")
  let written = "    \"startedAt\": \"1970-01-01T00:00:00Z\""
  #expect(lines.contains(written[...]), "a time is RFC 3339 in UTC")
  #expect(recorded.err.isEmpty, "nothing goes to standard error")
}
