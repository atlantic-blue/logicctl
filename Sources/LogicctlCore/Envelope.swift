import Foundation

/// One value inside the JSON that logicctl prints.
///
/// A command builds its answer from these, and the printer decides how they are written. So a
/// command never writes JSON by hand, and every command prints the same way.
public enum JSONValue: Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  /// A moment, written the one way the tool writes a time: RFC 3339 in UTC.
  public static func time(_ moment: Date) -> JSONValue {
    .string(moment.formatted(.iso8601))
  }
}

/// What went wrong, for the person and for the agent that read it.
public struct Failure: Equatable {
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
      "hint": .null,
    ])
  }
}

/// What every command says about itself, beside its answer.
///
/// The fields are here from this step. The run of a command fills them.
public struct Meta: Equatable {
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

  public init(
    version: String,
    session: String? = nil,
    step: String? = nil,
    externalChange: String? = nil,
    durationMs: Int = 0
  ) {
    self.version = version
    self.session = session
    self.step = step
    self.externalChange = externalChange
    self.durationMs = durationMs
  }

  /// The meta as the JSON that goes out. A field nobody filled is null, never absent.
  public var json: JSONValue {
    .object([
      "version": .string(version),
      "session": session.map(JSONValue.string) ?? .null,
      "step": step.map(JSONValue.string) ?? .null,
      "externalChange": externalChange.map(JSONValue.string) ?? .null,
      "durationMs": .int(durationMs),
    ])
  }
}

/// The one JSON object a command prints.
///
/// There is no way to build one that carries both an answer and a failure: a failure has no data,
/// so a caller that reads `error` knows `data` says nothing.
public struct Envelope: Equatable {
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
