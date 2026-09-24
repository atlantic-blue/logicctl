import Foundation

/// A read that logicctl repeats until it holds, and gives up on.
///
/// Logic answers through the Accessibility tree, and a change lands there some time after the
/// event that made it, so a command reads again until what it asked for is there. A read that
/// never holds would keep the command alive with the session lock taken, and the caller would get
/// no answer at all. Every wait in logicctl goes through this helper, so every wait ends: with the
/// condition met, or with `timeout` and the milliseconds it gave Logic.
public enum Wait {
  /// The limit of a wait that names none, in milliseconds.
  public static let defaultLimitMs = 5000

  /// How long the helper sleeps between two reads, in milliseconds.
  public static let defaultPollMs = 50

  /// The limit passed before the condition held.
  public struct RanOut: Error, Equatable {
    /// How long the wait lasted, from its first read to its last.
    public let waitedMs: Int

    public init(waitedMs: Int) {
      self.waitedMs = waitedMs
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(
        code: .timeout,
        message: "Logic did not answer within \(waitedMs)ms",
        details: .object(["waitedMs": .number(Double(waitedMs))]))
    }
  }

  /// Reads a clock that only moves forward, in milliseconds.
  public typealias Clock = () -> Int

  /// Sleeps for some milliseconds.
  public typealias Sleeper = (Int) -> Void

  /// Reads the condition until it holds, and throws `RanOut` when the limit passes first.
  ///
  /// The condition is read before the first sleep, so a condition that already holds costs the
  /// command nothing. A condition that throws stops the wait and its own error reaches the
  /// caller, because a read that failed is not a read that said no.
  ///
  /// The clock and the sleep are given, so a test drives a five second wait in no time.
  public static func until(
    limitMs: Int = Wait.defaultLimitMs,
    pollMs: Int = Wait.defaultPollMs,
    clock: Clock = Wait.monotonicMilliseconds,
    sleeper: Sleeper = Wait.sleepMilliseconds,
    _ holds: () throws -> Bool
  ) throws {
    _ = try holds()
  }

  /// Milliseconds on a clock that only moves forward, whatever the wall clock does.
  public static func monotonicMilliseconds() -> Int {
    milliseconds(of: started.duration(to: ContinuousClock.now))
  }

  /// Holds the thread of the command for some milliseconds.
  public static func sleepMilliseconds(_ span: Int) {
    Thread.sleep(forTimeInterval: Double(span) / 1000)
  }

  /// A span in whole milliseconds, with anything under a millisecond dropped.
  static func milliseconds(of span: Duration) -> Int {
    let parts = span.components
    return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
  }

  /// The moment this process first read the clock. Every read is a span from here.
  private static let started = ContinuousClock.now
}
