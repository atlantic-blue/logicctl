import ApplicationServices
import Foundation
import LogicctlCore

/// What logicctl reads about the project the running Logic has open.
///
/// Nothing is built here yet. Every read answers nothing, so the scenario that describes the
/// reads fails against it.
public struct ProjectReader {
  /// Why the reader refused what Logic answered. The reason reaches the answer of the command, so a
  /// person reads what Logic said without going to look for a log.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// One short reason, in the words of the Mac that refused.
    public let reason: String

    /// The code a caller reads and exits with.
    public let code: ErrorCode

    public init(reason: String, code: ErrorCode = .internalFailure) {
      self.reason = reason
      self.code = code
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(code: code, message: reason)
    }
  }
  /// The Logic that runs now, or nothing when none runs.
  public typealias LogicRead = () throws -> RunningLogic?

  /// The document the main window carries, written as text, or nothing when it carries none.
  public typealias DocumentRead = () throws -> String?

  /// The title of the main window, or nothing when Logic shows no window.
  public typealias TitleRead = () throws -> String?

  private let readLogic: LogicRead
  private let readDocument: DocumentRead
  private let readTitle: TitleRead

  public init(
    logic: @escaping LogicRead,
    document: @escaping DocumentRead,
    title: @escaping TitleRead
  ) {
    readLogic = logic
    readDocument = document
    readTitle = title
  }

  /// Where the project that Logic has open sits.
  public func path() throws -> String? {
    nil
  }

  /// What the project that Logic has open is called.
  public func name() throws -> String? {
    nil
  }

  /// The process id of the Logic that runs.
  public func processID() throws -> Int32 {
    0
  }

  /// The text of the document attribute, whether Logic answers a string or a url object.
  public static func text(ofDocument carried: AnyObject?) -> String? {
    nil
  }
}
