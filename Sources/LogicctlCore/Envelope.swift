import Foundation

extension JSONValue {
  /// A moment, written the one way the tool writes a time: RFC 3339 in UTC.
  public static func time(_ moment: Date) -> JSONValue {
    .string(moment.formatted(.iso8601))
  }
}

/// What went wrong, for the person and for the agent that read it.
public struct Failure: Sendable, Equatable {
  /// The code a caller reads, and the number the process exits with.
  public let code: ErrorCode

  /// One sentence a person can act on.
  public let message: String

  /// What else the caller needs, for example the index that was not there. Null when there is
  /// nothing to add.
  public let details: JSONValue?

  public init(code: ErrorCode, message: String, details: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }

  /// The failure as the JSON that goes out: `code`, `message` and `details`, and nothing else.
  public var json: JSONValue {
    .object([
      "code": .string(code.rawValue),
      "message": .string(message),
      "details": details ?? .null,
    ])
  }
}

/// An error that already knows the failure it becomes.
///
/// A wait that ran out, a walk that found nothing, a panel that Logic refused: each one carries
/// the code and the sentence a person reads, so the run of a command joins them to the envelope
/// rather than deciding a second time what each one meant. An error that carries none is a
/// failure logicctl has no code for, and it goes out as `internal`.
public protocol FailureCarrying: Error {
  /// The failure the caller prints and exits with.
  var failure: Failure { get }
}

/// What every command says about itself, beside its answer.
///
/// The fields are here from this step. The run of a command fills them.
public struct Meta: Sendable, Equatable {
  /// The version of logicctl that answered.
  public let version: String

  /// The session of the project that is open, or null.
  public let session: String?

  /// The commit of the step this command wrote, or null.
  public let step: String?

  /// The commit of the external change step written before this command, or null.
  public let externalChange: String?

  /// How long the command took, from its start to its end.
  public let durationMs: Int

  /// What else the answer has to say about itself, for example that no picture of the window was
  /// taken and why. Null when there is nothing to add.
  public let details: JSONValue?

  public init(
    version: String,
    session: String? = nil,
    step: String? = nil,
    externalChange: String? = nil,
    durationMs: Int = 0,
    details: JSONValue? = nil
  ) {
    self.version = version
    self.session = session
    self.step = step
    self.externalChange = externalChange
    self.durationMs = durationMs
    self.details = details
  }

  /// The meta as the JSON that goes out. A field nobody filled is null, never absent.
  public var json: JSONValue {
    .object([
      "version": .string(version),
      "session": session.map(JSONValue.string) ?? .null,
      "step": step.map(JSONValue.string) ?? .null,
      "externalChange": externalChange.map(JSONValue.string) ?? .null,
      "durationMs": .number(Double(durationMs)),
      "details": details ?? .null,
    ])
  }
}

/// The one JSON object a command prints.
///
/// There is no way to build one that carries both an answer and a failure: a failure has no data,
/// so a caller that reads `error` knows `data` says nothing.
public struct Envelope: Sendable, Equatable {
  /// What the command answered, or null when it failed.
  public let data: JSONValue?

  /// Why the command failed, or null when it worked.
  public let error: Failure?

  /// What the command says about itself.
  public let meta: Meta

  private init(data: JSONValue?, error: Failure?, meta: Meta) {
    self.data = data
    self.error = error
    self.meta = meta
  }

  /// The envelope of a command that worked.
  public static func success(data: JSONValue?, meta: Meta) -> Envelope {
    Envelope(data: data, error: nil, meta: meta)
  }

  /// The envelope of a command that failed. Its data is null.
  public static func failure(_ failure: Failure, meta: Meta) -> Envelope {
    Envelope(data: nil, error: failure, meta: meta)
  }

  /// The number the process exits with after printing this. 0 says the command worked.
  public var exitCode: Int32 {
    error?.code.exitCode ?? 0
  }

  /// The envelope as the JSON that goes out: `data`, `error` and `meta`, all three always there.
  public var json: JSONValue {
    .object([
      "data": data ?? .null,
      "error": error?.json ?? .null,
      "meta": meta.json,
    ])
  }
}
