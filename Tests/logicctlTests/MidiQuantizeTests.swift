import Foundation
import LogicctlCore
import Testing

@testable import logicctl

/// What one run of a command line wrote, on each channel, and the number it exited with.
private struct Answer {
  let out: String
  let err: String
  let status: Int32

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// The failure the answer carries, or an empty object when it carries none.
  func failure() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }
}

/// Runs one whole command line, the way a person types it.
///
/// The arguments go in as text and nothing is built by hand, because the refusal this proves comes
/// from the parser and a test that built a command would walk around it.
private func logicctl(_ arguments: [String]) -> Answer {
  var out = ""
  var err = ""
  let status = Logicctl.run(
    arguments: arguments,
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A quantize carries a grid, and a grid Logic does not offer must stop before Logic hears of it.
///
/// Logic applies a quantize to every note that is selected. A command that carried `1/3` to the
/// Time Quantize popup would either set a grid nobody asked for, or leave the popup on whatever
/// the last person left it on, and then press the button. The notes move either way, the answer
/// reads as though the command worked, and no later read of the region shows what happened,
/// because the notes sit on a grid in both cases. The only place this can be caught is before the
/// command talks to Logic, so `1/3` stops at the flag with `invalid_argument` and exit 2.
///
/// The first line is what holds the proof honest. An unknown subcommand is also `invalid_argument`
/// and also exit 2, so a check of the code alone reads green on a logicctl that has no `quantize`
/// at all. The same command line with `1/16` parses, which says the refusal underneath came from
/// the value and from nothing else.
@Test func quantizeRefusesAValueLogicDoesNotOffer() throws {
  #expect(
    throws: Never.self,
    "1/16 is one of the eleven values, so this line names a command logicctl has"
  ) {
    try Logicctl.parseAsRoot([
      "midi", "quantize", "--track", "4", "--region", "1", "--value", "1/16", "--strength", "100",
    ])
  }

  let answer = logicctl([
    "midi", "quantize", "--track", "4", "--region", "1", "--value", "1/3", "--strength", "100",
  ])

  let failure = try answer.failure()
  #expect(failure["code"] as? String == "invalid_argument", "a wrong flag is refused as one")
  #expect(answer.status == 2, "the number the design system gives invalid_argument")
  #expect(try answer.printed()["data"] is NSNull, "a failure carries no data")

  let message = failure["message"] as? String ?? ""
  #expect(message.contains("--value"), "the refusal names the flag that was wrong")
  #expect(message.contains("1/3"), "the refusal names the value that was refused")

  let lines = answer.err.split(whereSeparator: \.isNewline)
  #expect(lines.count == 1, "standard error carries one line for the person reading along")
  #expect(
    answer.err.hasPrefix("logicctl: invalid_argument: "),
    "the one line reads logicctl: <code>: <message>")
}
