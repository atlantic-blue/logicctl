import ArgumentParser
import Foundation
import LogicctlCore
import Testing

@testable import logicctl

/// The approved design system, read from the file in the repository root.
private struct DesignSystem {
  let values: [String: Any]

  init() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let raw = try Data(contentsOf: root.appending(path: "design-system.json"))
    let parsed = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
    values = parsed?["values"] as? [String: Any] ?? [:]
  }

  /// The two numbers the approved file gives a scale.
  func range(_ name: String) -> ClosedRange<Int>? {
    guard let pair = values[name] as? [Int], pair.count == 2 else { return nil }
    guard let low = pair.first, let high = pair.last else { return nil }
    return low...high
  }

  /// The values the approved file lists for a flag.
  func list(_ name: String) -> [String] {
    values[name] as? [String] ?? []
  }
}

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

  /// The code of the failure the answer carries, or nil when it carries none.
  func failureCode() throws -> String? {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["code"] as? String
  }
}

/// The velocity option a MIDI command will hold. No command holds one yet, so the test declares
/// it, to read a velocity the way that command will read it.
private struct VelocityArguments: ParsableArguments {
  @Option
  var velocity: Velocity
}

/// Runs whatever refuses the arguments, and writes the refusal the way logicctl writes every
/// refusal: one envelope, one line on standard error, and the number the process exits with.
private func refusal(into answer: Answer, of parse: () throws -> Void) -> Int32 {
  do {
    try parse()
    return 0
  } catch {
    return Logicctl.report(
      error,
      standardOutput: answer.write,
      standardError: answer.writeError)
  }
}

/// A person or an agent types a flag that logicctl does not have. They get back what every other
/// command gives them: one JSON object on standard output, with the code that says the arguments
/// were wrong, the answer null because there is none, and the exit number that belongs to that
/// code. Logic is never asked anything, so the answer names no session and no step, and the
/// person reading along gets one line on standard error saying the same thing.
@Test func anUnknownFlagPrintsInvalidArgument() throws {
  let answer = Answer()

  let status = Logicctl.run(
    arguments: ["--nope"],
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 2)
  let code = try answer.failureCode()
  #expect(code == "invalid_argument")

  let printed = try answer.printed()
  #expect(printed["data"] is NSNull)
  let meta = printed["meta"] as? [String: Any]
  #expect(meta?["session"] is NSNull)
  #expect(meta?["step"] is NSNull)

  let message = (printed["error"] as? [String: Any])?["message"] as? String
  #expect(answer.err == "logicctl: invalid_argument: \(message ?? "")\n")
  #expect(answer.out.hasSuffix("}\n"))
  #expect(answer.out.filter(\.isNewline).count == 1)
}

/// A state is set and never toggled, so `--on` and `--off` are the whole of it and a command needs
/// exactly one of them. Neither flag leaves the person's wish unknown, and both together ask for
/// two things at once. Either way the command is refused before it runs, with the same code and
/// the same exit number as any other wrong flag.
@Test func aStateFlagTakesExactlyOneOfOnAndOff() throws {
  for line in [[], ["--on", "--off"]] {
    let answer = Answer()

    let status = refusal(into: answer) {
      let toggle = try ToggleOption.parse(line)
      _ = try toggle.state()
    }

    #expect(status == 2)
    let code = try answer.failureCode()
    #expect(code == "invalid_argument")
  }

  #expect(try ToggleOption.parse(["--on"]).state() == true)
  #expect(try ToggleOption.parse(["--off"]).state() == false)
}

/// Velocity is the scale Logic shows, 1 to 127, so 128 is not a velocity. A value outside its
/// scale is refused where the arguments are read, before Logic is touched, and it comes back as
/// the same refusal a person gets for any other wrong flag.
@Test func aVelocityOf128FailsWithInvalidArgument() throws {
  let answer = Answer()

  let status = refusal(into: answer) { _ = try VelocityArguments.parse(["--velocity", "128"]) }

  #expect(status == 2)
  let code = try answer.failureCode()
  #expect(code == "invalid_argument")
  #expect(try VelocityArguments.parse(["--velocity", "127"]).velocity.value == 127)
}

/// Indexes are the numbers Logic shows, which start at 1, so there is no track 0. Flags are long
/// and spelled out, so a single letter is not a flag at all.
@Test func anIndexStartsAtOneAndFlagsAreLongOnly() throws {
  for line in [["--index", "0"], ["-i", "1"], ["--index", "one"]] {
    let answer = Answer()

    let status = refusal(into: answer) { _ = try TrackIndexOption.parse(line) }

    #expect(status == 2)
    let code = try answer.failureCode()
    #expect(code == "invalid_argument")
  }

  #expect(try TrackIndexOption.parse(["--index", "1"]).index.value == 1)
}

/// The scales a flag carries are the approved ones. The test reads design-system.json rather than
/// trusting the numbers written in the code, so a scale that moves in one place and not the other
/// is caught here.
@Test func everyValueKeepsTheScaleTheDesignSystemApproved() throws {
  let design = try DesignSystem()

  #expect(design.range("velocity") == Velocity.range)
  #expect(design.range("automationValue") == AutomationValue.range)
  #expect(design.range("quantizeStrength") == QuantizeStrength.range)
  #expect(design.list("quantize") == QuantizeValue.allCases.map(\.rawValue))

  #expect(AutomationValue(text: "128") == nil)
  #expect(AutomationValue(text: "0")?.value == 0)
  #expect(QuantizeStrength(text: "101") == nil)
  #expect(QuantizeStrength(text: "100")?.value == 100)
  #expect(QuantizeValue(rawValue: "1/3") == nil)

  #expect(DurationValue(text: "500ms")?.milliseconds == 500)
  #expect(DurationValue(text: "5s")?.milliseconds == 5000)
  #expect(DurationValue(text: "5") == nil)
  #expect(DurationValue(text: "5m") == nil)
  #expect(try TimeoutOption.parse([]).timeout == DurationValue.seconds(5))
}
