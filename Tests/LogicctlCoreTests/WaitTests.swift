import Foundation
import LogicctlCore
import Testing

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class Time {
  var now = 0
  var sleeps: [Int] = []

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    sleeps.append(span)
    now += span
  }
}

/// A read that fails is not a read that says no.
private enum Probe: Error, Equatable {
  case theTreeWentAway
}

/// A command that asks Logic for something Logic never does still ends, and says how long it
/// gave Logic before it gave up.
///
/// Every command reads the Accessibility tree again until the change it asked for is there.
/// Without a limit, such a command holds the session lock and prints nothing, so the person or
/// the agent that ran it waits with no code to act on and no number to act with. This wait ends
/// at five seconds with `timeout`, which exits 6, and it reports the milliseconds it waited, so
/// the caller can give Logic more time with `--timeout` and run the command again. The number is
/// measured against the real clock here, because a wait that reports a span it did not wait is
/// worth nothing to whoever reads it.
@Test func aWaitThatRunsOutFailsWithTimeout() throws {
  var reported: Int?

  do {
    try Wait.until { false }
  } catch let ranOut as Wait.RanOut {
    reported = ranOut.waitedMs
    #expect(ranOut.failure.code == .timeout, "the command exits 6")
    #expect(
      ranOut.failure.details == .object(["waitedMs": .number(Double(ranOut.waitedMs))]),
      "the details carry the span, and nothing else")
  }

  let waited = try #require(reported, "the wait ended instead of reading for ever")
  #expect(waited >= Wait.defaultLimitMs, "Logic got the whole five seconds")
  #expect(
    waited <= Wait.defaultLimitMs + Wait.defaultLimitMs / 10,
    "and the command gave up at that limit, not later")
}

/// A command that finds Logic already done carries on at once.
@Test func aConditionThatAlreadyHoldsDoesNotSleep() throws {
  let time = Time()

  try Wait.until(clock: time.read, sleeper: time.sleep) { true }

  #expect(time.sleeps.isEmpty, "the command read once and went on")
}

/// A change Logic makes a moment later still counts as done.
@Test func aConditionThatHoldsLaterEndsTheWait() throws {
  let time = Time()
  var reads = 0

  try Wait.until(clock: time.read, sleeper: time.sleep) {
    reads += 1
    return reads == 3
  }

  #expect(reads == 3, "the wait ended on the read that held")
  #expect(time.sleeps == [50, 50], "it slept between the reads, and no longer than that")
}

/// The limit the caller names is the limit the wait keeps, which is how `--timeout` reaches it.
@Test func theCallerGivesTheLimit() throws {
  let time = Time()
  var thrown: Wait.RanOut?

  do {
    try Wait.until(limitMs: 200, clock: time.read, sleeper: time.sleep) { false }
  } catch let ranOut as Wait.RanOut {
    thrown = ranOut
  }

  let ranOut = try #require(thrown, "a named limit still ends the wait")
  #expect(ranOut.waitedMs == 200, "it waited the limit it was given, not the default")
  #expect(time.sleeps == [50, 50, 50, 50], "and it read five times in those 200ms")
}

/// A command whose read of Logic breaks says what broke, not that it ran out of time.
@Test func aConditionThatThrowsStopsTheWait() {
  let time = Time()

  #expect(throws: Probe.theTreeWentAway) {
    try Wait.until(clock: time.read, sleeper: time.sleep) { throw Probe.theTreeWentAway }
  }

  #expect(time.sleeps.isEmpty, "the command stopped instead of asking again")
}
