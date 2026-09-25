import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
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

  /// The `error` of the answer, or an empty object when it carries none.
  func failure() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
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
/// It counts what the command asked of it. A Logic that holds its work does not go when it is asked
/// politely, which is the Logic of a project with unsaved changes, and it goes when it is ended.
private final class Mac {
  /// The process id this Logic runs as.
  let processID: Int32

  /// True while this Logic runs.
  var running = true

  /// True when a polite close ends this Logic. False is a Logic that holds unsaved work.
  var closesWhenAsked: Bool

  /// True when a save clears what the project was holding, so the close after it works.
  var savingClearsTheWork = true

  /// How many times the command asked Logic to close politely.
  var closes = 0

  /// How many times the command ended Logic, work and all.
  var ends = 0

  /// How many times the command asked Logic to write the project where it sits.
  var saves = 0

  init(processID: Int32 = 981, closesWhenAsked: Bool = true) {
    self.processID = processID
    self.closesWhenAsked = closesWhenAsked
  }

  func control() -> AppControl {
    AppControl(
      start: {},
      read: {
        self.running ? RunningLogic(processID: self.processID, showsAWindow: true) : nil
      },
      close: {
        self.closes += 1
        if self.closesWhenAsked {
          self.running = false
        }
      },
      end: {
        self.ends += 1
        self.running = false
      },
      save: {
        self.saves += 1
        if self.savingClearsTheWork {
          self.closesWhenAsked = true
        }
      })
  }
}

/// A Mac with no Logic on it at all.
private final class NoLogic {
  var reads = 0

  func control() -> AppControl {
    AppControl(
      start: {},
      read: {
        self.reads += 1
        return nil
      })
  }
}

/// The state of a project Logic has open.
private func stateOfAProject(named: String) -> State {
  State(
    logic: LogicVersion(version: "12.3.1"),
    project: Project(name: named),
    transport: Transport(tempo: 120),
    tracks: [])
}

/// A driver over a Logic with one project open at one path.
private func driverOfAProject(named: String, at path: String? = "/tmp/F-T0.logicx")
  -> FakeLogicDriver
{
  FakeLogicDriver(state: stateOfAProject(named: named), processID: 981, path: path)
}

/// The work of a session survives one word.
///
/// `quit` is the one command that can throw away hours in a moment, and the project a person is
/// working on holds changes that are on no disk yet. So Logic is the authority on whether there is
/// work to lose: a project with unsaved changes holds the request to close, and Logic is still
/// running when logicctl reads it back. logicctl reports that refusal as `unsaved_changes`, which
/// exits 8, and it names the project so the person reads which work is waiting. Logic stays open
/// with everything in it, nothing was written and nothing was lost, and the answer to the question
/// Logic asks belongs to the person: `quit --save` writes the project, and `quit --discard
/// --confirm` says in as many words that the work can go.
@Test func quitStopsOnUnsavedChanges() throws {
  let typed = try Logicctl.parseAsRoot(["quit"])
  #expect(typed is Quit, "a person can type logicctl quit")

  let holding = Mac(closesWhenAsked: false)
  let time = Time()
  let answer = Answer()
  let exited = Quit.answer(
    of: holding.control(),
    driver: driverOfAProject(named: "F-T0"),
    limitMs: 200,
    clock: time.read,
    sleeper: time.sleep,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 8, "unsaved_changes exits 8")
  #expect(holding.running, "Logic still runs, with the work still in it")
  #expect(holding.ends == 0, "nothing ended Logic, so nothing was lost")
  #expect(holding.saves == 0, "nothing was written either, because nobody asked for that")

  let failed = try answer.failure()
  #expect(failed["code"] as? String == "unsaved_changes")
  #expect(
    failed["message"] as? String == "F-T0 has unsaved changes",
    "the failure names the project whose work is waiting")
  #expect(failed["details"] is NSNull)
  #expect(try answer.printed()["data"] is NSNull)
  #expect(
    answer.err == "logicctl: unsaved_changes: F-T0 has unsaved changes\n",
    "the person reading along gets the one line")
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and a newline")
}

/// A person who did not say the work can go keeps it.
///
/// `--discard` is the one flag of this command that cannot be taken back, so it is refused before
/// Logic is read, let alone asked for anything.
@Test func discardWithoutConfirmClosesNothing() throws {
  let open = Mac()
  let answer = Answer()
  let exited = Quit.answer(
    of: open.control(),
    driver: driverOfAProject(named: "F-T0"),
    discarding: true,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 7, "confirm_required exits 7")
  #expect(open.running, "Logic was never asked to go")
  #expect(open.closes == 0)
  #expect(open.ends == 0)

  let failed = try answer.failure()
  #expect(failed["code"] as? String == "confirm_required")
  #expect(failed["details"] is NSNull)

  let meta = try answer.printed()["meta"] as? [String: Any]
  #expect(meta?["session"] is NSNull, "the command wrote no step to a session")
  #expect(meta?["step"] is NSNull)
}

/// `--discard --confirm` ends Logic, unsaved work and all.
@Test func discardWithConfirmEndsLogic() throws {
  let holding = Mac(closesWhenAsked: false)
  let time = Time()
  let answer = Answer()
  let exited = Quit.answer(
    of: holding.control(),
    driver: driverOfAProject(named: "F-T0"),
    discarding: true,
    confirmed: true,
    limitMs: 200,
    clock: time.read,
    sleeper: time.sleep,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 0)
  #expect(answer.err.isEmpty)
  #expect(holding.ends == 1, "the forced close is what ends Logic")
  #expect(holding.closes == 0, "the polite close is not tried first")
  #expect(holding.running == false)
  #expect(try answer.data()["running"] as? Bool == false)
}

/// `--save` writes the project where it sits, and then Logic goes.
@Test func saveWritesTheProjectAndThenLogicCloses() throws {
  let holding = Mac(closesWhenAsked: false)
  let time = Time()
  let answer = Answer()
  let exited = Quit.answer(
    of: holding.control(),
    driver: driverOfAProject(named: "F-T0"),
    saving: true,
    limitMs: 200,
    clock: time.read,
    sleeper: time.sleep,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 0)
  #expect(holding.saves == 1, "the project was written before anything closed")
  #expect(holding.closes == 1, "the close is the polite one, which Logic can still refuse")
  #expect(holding.ends == 0)
  #expect(holding.running == false)
}

/// A save that did not take is still a refusal, never a close.
///
/// The read after the close is what says whether the work is safe. A Logic that holds its project
/// after the save stops the command with `unsaved_changes`, so a save that did nothing cannot end
/// the work by way of the close behind it.
@Test func aSaveThatChangedNothingStillStopsTheQuit() throws {
  let holding = Mac(closesWhenAsked: false)
  holding.savingClearsTheWork = false
  let time = Time()
  let answer = Answer()
  let exited = Quit.answer(
    of: holding.control(),
    driver: driverOfAProject(named: "F-T0"),
    saving: true,
    limitMs: 200,
    clock: time.read,
    sleeper: time.sleep,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 8)
  #expect(holding.running)
  #expect(try answer.failure()["message"] as? String == "F-T0 has unsaved changes")
}

/// `--save` has nowhere to write a project that was never saved, so it stops before it acts.
@Test func saveOnAProjectThatWasNeverSavedIsRefused() throws {
  let open = Mac()
  let answer = Answer()
  let exited = Quit.answer(
    of: open.control(),
    driver: driverOfAProject(named: "Untitled", at: nil),
    saving: true,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 2, "invalid_argument exits 2")
  #expect(open.saves == 0)
  #expect(open.closes == 0)
  #expect(open.running, "Logic was never asked to go")

  let failed = try answer.failure()
  #expect(failed["code"] as? String == "invalid_argument")
  let sentence =
    "This project was never saved, so there is nowhere to write it. "
    + "Run save --path <path> first."
  #expect(failed["message"] as? String == sentence)
}

/// A project with nothing to save closes on the word.
@Test func quitClosesALogicThatHoldsNothing() throws {
  let open = Mac()
  let time = Time()
  let answer = Answer()
  let exited = Quit.answer(
    of: open.control(),
    driver: driverOfAProject(named: "F-T0"),
    limitMs: 200,
    clock: time.read,
    sleeper: time.sleep,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 0)
  #expect(answer.err.isEmpty)
  #expect(open.closes == 1)
  #expect(open.ends == 0, "a polite close that worked never forces anything")
  #expect(open.running == false)

  let state = try answer.data()
  #expect(state["running"] as? Bool == false)
  #expect(state.keys.sorted() == ["running"])
}

/// A Mac with no Logic on it has nothing to close.
@Test func quitOnAMacWithNoLogicFailsWithLogicNotRunning() throws {
  let bare = NoLogic()
  let answer = Answer()
  let exited = Quit.answer(
    of: bare.control(),
    driver: FakeLogicDriver(),
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 4, "logic_not_running exits 4")
  #expect(try answer.failure()["code"] as? String == "logic_not_running")
}

/// A Logic that outlives a forced close did not answer, and it has no work to blame for it.
@Test func aForcedCloseThatLogicOutlivesFailsWithTimeout() throws {
  let stuck = Mac(closesWhenAsked: false)
  let time = Time()
  let answer = Answer()
  // A Mac that keeps Logic alive whatever it is asked, which is the Logic that hangs.
  let control = AppControl(
    start: {},
    read: { RunningLogic(processID: stuck.processID, showsAWindow: true) },
    close: { stuck.closes += 1 },
    end: { stuck.ends += 1 },
    save: { stuck.saves += 1 })
  let exited = Quit.answer(
    of: control,
    driver: driverOfAProject(named: "F-T0"),
    discarding: true,
    confirmed: true,
    limitMs: 200,
    clock: time.read,
    sleeper: time.sleep,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 6, "timeout exits 6")
  let failed = try answer.failure()
  #expect(failed["code"] as? String == "timeout")
  #expect((failed["details"] as? [String: Any])?["waitedMs"] as? Int == 200)
  #expect(stuck.ends == 1)
}

/// The project with no name to read still says what stopped the command.
@Test func aRefusalNamesTheProjectItCanRead() throws {
  let holding = Mac(closesWhenAsked: false)
  let time = Time()
  let answer = Answer()
  // A Logic whose state logicctl cannot read is the Logic of this Mac today, because no driver
  // over the real Logic exists yet. The refusal still has to say what happened.
  let unreadable = FakeLogicDriver()
  let exited = Quit.answer(
    of: holding.control(),
    driver: unreadable,
    limitMs: 200,
    clock: time.read,
    sleeper: time.sleep,
    standardOutput: answer.write,
    standardError: answer.writeError)

  #expect(exited == 8)
  #expect(try answer.failure()["message"] as? String == "The project has unsaved changes")
}

/// Both flags together is a command that cannot be run, so it is refused before anything.
@Test func saveAndDiscardTogetherIsRefused() throws {
  var out = ""
  var err = ""
  let exited = Logicctl.run(
    arguments: ["quit", "--save", "--discard"],
    standardOutput: { out += $0 },
    standardError: { err += $0 })

  #expect(exited == 2, "invalid_argument exits 2")
  #expect(err.hasPrefix("logicctl: invalid_argument: "))
  let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
  #expect((parsed?["error"] as? [String: Any])?["code"] as? String == "invalid_argument")
}
