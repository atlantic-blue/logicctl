import Darwin
import Foundation

/// The lock that keeps two writers out of one session.
///
/// A command and the watcher write into the same repository, and a repository has one index. So a
/// writer holds `.lock` in the session folder for as long as it writes a step, and a second
/// writer waits for it.
public struct Lock: Sendable {
  /// What taking the lock can refuse.
  public enum Refusal: Error, Equatable {
    /// Another writer held the lock for longer than the wait limit.
    case anotherWriterHeldIt(waitedMs: Int)

    /// The lock file could not be opened.
    case couldNotOpen(path: String, code: Int32)
  }

  /// How long a writer waits, in seconds. Contract RUN-6 gives five seconds to every wait.
  public static let defaultWaitSeconds = 5.0

  /// The name of the lock file inside a session folder.
  public static let fileName = ".lock"

  /// How often the wait tries the lock again, in seconds.
  static let lookWaitSeconds = 0.01

  /// How long this writer waits for another one, in seconds.
  public var waitSeconds: Double

  public init(waitSeconds: Double = Lock.defaultWaitSeconds) {
    self.waitSeconds = waitSeconds
  }

  /// Runs `write` while this writer holds the lock of one session folder.
  ///
  /// The lock is one file and two descriptors of it do not share a lock, so a second writer in
  /// this process waits in the same way a second process does.
  public func holding<Answer>(_ folder: URL, _ write: () throws -> Answer) throws -> Answer {
    let path = folder.appendingPathComponent(Lock.fileName).path
    let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else {
      throw Refusal.couldNotOpen(path: path, code: errno)
    }
    defer { _ = close(descriptor) }

    let started = Date()
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let waited = Date().timeIntervalSince(started)
      guard waited < waitSeconds else {
        throw Refusal.anotherWriterHeldIt(waitedMs: Int((waited * 1000).rounded()))
      }
      Thread.sleep(forTimeInterval: Lock.lookWaitSeconds)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try write()
  }
}
