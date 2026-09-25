import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import Testing

@testable import logicctl

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

  /// The `data` of the answer, or an empty object when it carries none.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }
}

/// A clock and a sleep the test moves itself, so a wait of any length costs the suite no time.
private final class Time {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// The Mac the command drives, with one Logic on it.
///
/// It counts what the command asked of it, and it shows the window of Logic on the read the test
/// names. A Mac named with no read never shows a window at all, which is the Logic that hangs while
/// it starts.
private final class Mac {
  /// How many times the command asked macOS to start Logic.
  var starts = 0

  /// How many times the command read the Logic back.
  var reads = 0

  /// The process id this Logic runs as.
  let processID: Int32

  /// The read the window appears on, counted from 1, or nothing for a Logic that never shows one.
  let windowOnRead: Int?

  init(processID: Int32 = 981, windowOnRead: Int?) {
    self.processID = processID
    self.windowOnRead = windowOnRead
  }

  func control() -> AppControl {
    AppControl(
      start: { self.starts += 1 },
      read: {
        self.reads += 1
        let showing = self.windowOnRead.map { self.reads >= $0 } ?? false
        return RunningLogic(processID: self.processID, showsAWindow: showing)
      })
  }
}

/// A person or an agent starts Logic with one command, and the answer means Logic is ready to be
/// asked for something else.
///
/// Logic takes seconds to draw its window, and every other command of logicctl reads that window
/// through the Accessibility tree. A `launch` that answered the moment macOS was asked to start
/// Logic would report success against a Logic with nothing on the screen, and the next command
/// would fail on an empty tree over a Logic that is merely still starting. So the answer of this
/// command is the promise that the window is there: it comes at the read the window appeared on and
/// at no read before it, and one command starts one Logic however long that takes.
///
/// A Logic that never shows a window is the other half of the same promise. The wait ends, because
/// a command that read for ever would leave the caller with no code to act on and no number to act
/// with. It ends with `timeout`, which exits 6, and it says how many milliseconds Logic got, so the
/// caller gives Logic more time with `--timeout` and runs the command again.
@Test func launchWaitsForTheWindow() throws {
  let typed = try Logicctl.parseAsRoot(["launch"])
  #expect(typed is Launch, "a person can type logicctl launch")
  let asked = try Logicctl.parseAsRoot(["launch", "--timeout", "20s"])
  #expect((asked as? Launch)?.limitMs == 20_000, "--timeout sets the limit of the wait")

  let starting = Mac(windowOnRead: 3)
  let time = Time()
  let ready = Answer()
  let exited = Launch.answer(
    of: starting.control(),
    limitMs: 200,
    clock: time.read,
    sleeper: time.sleep,
    standardOutput: ready.write,
    standardError: ready.writeError)

  #expect(exited == 0)
  #expect(ready.err.isEmpty)
  #expect(ready.out.hasSuffix("}\n"))
  #expect(ready.out.filter(\.isNewline).count == 1)
  #expect(starting.starts == 1, "one command starts one Logic")
  #expect(
    starting.reads == 3,
    "the answer came at the read the window appeared on, and at no read before it")

  let read = try ready.printed()
  #expect(read["error"] is NSNull)
  let state = try ready.data()
  #expect(state["running"] as? Bool == true)
  #expect(state["pid"] as? Int == 981, "the answer names the Logic it started")
  #expect(state.keys.sorted() == ["pid", "running"])

  let meta = read["meta"] as? [String: Any]
  #expect(meta?["version"] as? String == Logicctl.version)
  #expect(meta?["session"] is NSNull, "Logic starts before a project is open, so there is none")
  #expect(meta?["step"] is NSNull)
  #expect(meta?["durationMs"] as? Int != nil)

  let hanging = Mac(windowOnRead: nil)
  let alsoTime = Time()
  let gaveUp = Answer()
  let failed = Launch.answer(
    of: hanging.control(),
    limitMs: 200,
    clock: alsoTime.read,
    sleeper: alsoTime.sleep,
    standardOutput: gaveUp.write,
    standardError: gaveUp.writeError)

  #expect(failed == 6, "timeout exits 6")
  #expect(hanging.starts == 1)
  #expect(alsoTime.now == 200, "Logic got the whole limit before the command gave up")
  #expect(gaveUp.out.filter(\.isNewline).count == 1)
  #expect(gaveUp.err.hasPrefix("logicctl: timeout: "))
  #expect(gaveUp.err.filter(\.isNewline).count == 1, "standard error carries one line")

  let refused = try gaveUp.printed()
  #expect(refused["data"] is NSNull)
  let failure = refused["error"] as? [String: Any]
  #expect(failure?["code"] as? String == "timeout")
  let details = failure?["details"] as? [String: Any]
  #expect(details?["waitedMs"] as? Int == 200, "the answer says how long Logic got")
}
