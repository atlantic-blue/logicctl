import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import Testing

@testable import logicctl

/// The sentence the approved mockup of this command carries.
private let missingGrant = "Grant Accessibility and Screen Recording to logicctl"

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

/// A Mac that granted what the two flags say, and that remembers every prompt it was asked for.
private final class Mac {
  let accessibility: Bool
  let screenRecording: Bool
  var wasAskedForAccessibility = false
  var wasAskedForScreenRecording = false

  init(accessibility: Bool, screenRecording: Bool) {
    self.accessibility = accessibility
    self.screenRecording = screenRecording
  }

  /// The grants of this Mac, as the command reads them.
  var grants: Grants {
    Grants(
      accessibility: { self.accessibility },
      screenRecording: { self.screenRecording },
      promptForAccessibility: { self.wasAskedForAccessibility = true },
      promptForScreenRecording: { self.wasAskedForScreenRecording = true })
  }
}

/// A person or an agent asks logicctl whether it may drive Logic at all, and this Mac granted only
/// one of the two things it needs.
///
/// Nothing is asked of Logic. The answer is a refusal with its own code and its own exit number, so
/// an agent stops on this one cause and a script reads 3 and goes no further. It names both grants
/// and their state, so the person knows which switch to move, and it says the prompt of macOS
/// opened, so they know where to look. The prompt went to the grant that was missing and to nothing
/// else.
///
/// The same Mac with both grants answers the other way: both flags true, no failure, exit 0,
/// nothing on standard error, and nobody is asked for a prompt they already gave.
@Test func aMissingPermissionPrintsPermissionMissing() throws {
  let mac = Mac(accessibility: false, screenRecording: true)
  let answer = Answer()

  let typed = try Logicctl.parseAsRoot(["permissions"])
  #expect(typed is Permissions)

  let status = Permissions.answer(
    of: mac.grants,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(status == 3)
  let code = try answer.failureCode()
  #expect(code == "permission_missing")

  let printed = try answer.printed()
  #expect(printed["data"] is NSNull)
  let failure = printed["error"] as? [String: Any]
  #expect(failure?["message"] as? String == missingGrant)
  let details = failure?["details"] as? [String: Any]
  #expect(details?["accessibility"] as? Bool == false)
  #expect(details?["screenRecording"] as? Bool == true)
  #expect(details?["prompted"] as? Bool == true)
  #expect(mac.wasAskedForAccessibility)
  #expect(mac.wasAskedForScreenRecording == false)

  let meta = printed["meta"] as? [String: Any]
  #expect(meta?["version"] as? String == Logicctl.version)
  #expect(meta?["session"] is NSNull)
  #expect(meta?["step"] is NSNull)
  #expect(meta?["durationMs"] as? Int != nil)
  #expect(answer.err == "logicctl: permission_missing: \(missingGrant)\n")
  #expect(answer.out.hasSuffix("}\n"))
  #expect(answer.out.filter(\.isNewline).count == 1)

  let granted = Mac(accessibility: true, screenRecording: true)
  let second = Answer()

  let allowed = Permissions.answer(
    of: granted.grants,
    standardOutput: second.write,
    standardError: second.writeError)

  #expect(allowed == 0)
  let read = try second.printed()
  #expect(read["error"] is NSNull)
  let data = read["data"] as? [String: Any]
  #expect(data?["accessibility"] as? Bool == true)
  #expect(data?["screenRecording"] as? Bool == true)
  #expect(data?.keys.sorted() == ["accessibility", "screenRecording"])
  #expect(granted.wasAskedForAccessibility == false)
  #expect(granted.wasAskedForScreenRecording == false)
  #expect(second.err.isEmpty)
}
