import Foundation

/// One field that is not the same in two states.
///
/// `before` and `after` are absent, and not null, when the field was added or removed. A null is
/// a value that Logic gave, for example a project that was never saved.
public struct Difference: Sendable, Equatable {
  /// A JSON pointer into the state, for example `/tracks/0/mute`.
  public var path: String

  /// What the field held before, or absent when the field was added.
  public var before: JSONValue?

  /// What the field holds after, or absent when the field was removed.
  public var after: JSONValue?

  public init(path: String, before: JSONValue? = nil, after: JSONValue? = nil) {
    self.path = path
    self.before = before
    self.after = after
  }
}

/// What changed between two states.
public enum StateDiff {
  /// The differences between two states, in one fixed order, so two runs read the same list.
  public static func between(_ before: State, _ after: State) -> [Difference] {
    between(before.json, after.json)
  }

  /// The differences between two JSON values.
  public static func between(_ before: JSONValue, _ after: JSONValue) -> [Difference] {
    var found: [Difference] = []
    walk(before, after, at: "", into: &found)
    return found
  }

  /// One step of a JSON pointer, with the two characters a pointer cannot carry written as
  /// escapes. RFC 6901 gives the order: the tilde first, then the slash.
  static func pointer(_ path: String, _ step: String) -> String {
    let escaped = step.replacingOccurrences(of: "~", with: "~0")
      .replacingOccurrences(of: "/", with: "~1")
    return path + "/" + escaped
  }

  private static func walk(
    _ before: JSONValue, _ after: JSONValue, at path: String, into found: inout [Difference]
  ) {
    switch (before, after) {
    case (.object(let left), .object(let right)):
      walkObjects(left, right, at: path, into: &found)
    case (.array(let left), .array(let right)):
      walkArrays(left, right, at: path, into: &found)
    default:
      guard before != after else {
        return
      }
      found.append(Difference(path: path, before: before, after: after))
    }
  }

  private static func walkObjects(
    _ before: [String: JSONValue], _ after: [String: JSONValue], at path: String,
    into found: inout [Difference]
  ) {
    var keys = before
    for (key, value) in after {
      keys[key] = value
    }
    for key in CanonicalJSON.sortedKeys(of: keys) {
      let step = pointer(path, key)
      switch (before[key], after[key]) {
      case (.some(let left), .some(let right)):
        walk(left, right, at: step, into: &found)
      case (.some(let left), .none):
        found.append(Difference(path: step, before: left, after: nil))
      case (.none, .some(let right)):
        found.append(Difference(path: step, before: nil, after: right))
      case (.none, .none):
        continue
      }
    }
  }

  private static func walkArrays(
    _ before: [JSONValue], _ after: [JSONValue], at path: String, into found: inout [Difference]
  ) {
    for position in 0..<max(before.count, after.count) {
      let step = pointer(path, String(position))
      if position < before.count && position < after.count {
        walk(before[position], after[position], at: step, into: &found)
      } else if position < before.count {
        found.append(Difference(path: step, before: before[position], after: nil))
      } else {
        found.append(Difference(path: step, before: nil, after: after[position]))
      }
    }
  }
}
