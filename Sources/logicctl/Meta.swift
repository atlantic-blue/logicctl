import Foundation
import LogicctlCore

/// What every answer of logicctl says about itself.
///
/// One place builds it. A refusal that never reached Logic and an answer from a command that was
/// recorded then say the same kinds of thing, so a caller reads `meta` the same way whatever
/// happened.
enum AnswerMeta {
  /// What a command that never reached Logic says about itself.
  ///
  /// It read nothing and it wrote nothing, so there is no session, no step and no change found
  /// before it.
  static func refusal(version: String, from started: Date, to ended: Date) -> Meta {
    Meta(version: version, durationMs: milliseconds(from: started, to: ended))
  }

  /// What a command that talked to Logic says about itself: the session it was written into, the
  /// commit of its step, and the commit of the change a person made before it.
  static func run(
    version: String,
    session: String?,
    step: String?,
    externalChange: String?,
    from started: Date,
    to ended: Date
  ) -> Meta {
    Meta(
      version: version,
      session: session,
      step: step,
      externalChange: externalChange,
      durationMs: milliseconds(from: started, to: ended))
  }

  /// How long something took, in whole milliseconds. A clock that steps back gives zero.
  static func milliseconds(from started: Date, to ended: Date) -> Int {
    max(0, Int((ended.timeIntervalSince(started) * 1000).rounded()))
  }
}
