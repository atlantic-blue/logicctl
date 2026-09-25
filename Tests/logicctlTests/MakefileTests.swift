import Foundation
import Testing

/// The root of the repository, found from this file.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

/// What one run of make printed, on both channels, and the status it ended with.
private struct Run {
  let status: Int32
  let text: String
}

/// Runs one target of the Makefile at the root, with this name as the signing identity.
private func make(_ target: String, identity: String) throws -> Run {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["make", target]
  process.currentDirectoryURL = repositoryRoot
  var environment = ProcessInfo.processInfo.environment
  environment["LOGICCTL_SIGN_IDENTITY"] = identity
  process.environment = environment

  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  let printed = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()

  return Run(status: process.terminationStatus, text: String(decoding: printed, as: UTF8.self))
}

/// The text of the Makefile at the root, on one line, whatever it does with white space.
private func makefile() throws -> String {
  let raw = try String(contentsOf: repositoryRoot.appending(path: "Makefile"), encoding: .utf8)
  return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// The operator builds logicctl again, and the two grants this Mac gave it are still there.
///
/// macOS keys the Accessibility grant and the Screen Recording grant on the identity that signed
/// the binary. A build signed with a different identity, or not signed at all, is a different
/// program to macOS, so both grants go. The operator then opens System Settings and gives them
/// again, after every build. `make sign` is what stops that: it signs each build with the one
/// identity this Mac already granted, named in LOGICCTL_SIGN_IDENTITY.
///
/// So the run that costs the grants is the run with no identity to sign with. Signing with a guess
/// takes them away, and so does leaving the binary unsigned, and neither says anything at the time:
/// the next command fails much later, for a reason that is nowhere on the screen. This run stops
/// instead. It builds nothing, it signs nothing, it names the variable the operator has to set, and
/// it ends with a status that is not zero, so a script that calls `make sign` stops there too.
@Test func theSignTargetStopsWithoutAnIdentity() throws {
  let run = try make("sign", identity: "")

  #expect(run.status != 0, "a script that runs make sign must stop here, not carry on")
  #expect(
    run.text.contains("LOGICCTL_SIGN_IDENTITY"),
    "the operator is told which variable to set, so they can fix it")
  #expect(
    run.text.contains("swift build") == false,
    "the refusal comes first, so nothing is built and nothing is signed with a guess")

  let target = try makefile()
  #expect(
    target.contains("swift build --configuration release"),
    "the build it signs is the release build, the one the operator runs")
  #expect(
    target.contains(#"codesign --force --sign "$$LOGICCTL_SIGN_IDENTITY""#),
    "and the identity it signs with is the one in the environment, never a name in the repository")
}
