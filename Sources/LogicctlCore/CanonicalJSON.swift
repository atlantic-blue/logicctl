import CryptoKit
import Foundation

/// One JSON value. The state becomes this tree, the canonical form writes the tree, and the
/// comparison of two states walks two trees. One tree gives the key order, the text and the
/// pointer, so the three cannot disagree.
public enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

/// The one form of a state that a hash is taken over: JSON with the keys sorted, no white space,
/// and every number as the shortest exact decimal.
public enum CanonicalJSON {
  /// A text that is not JSON.
  public enum Refusal: Error, Equatable {
    case notJSON
  }

  /// The canonical text of a state. Two spaces of indent write `state.json`, where git shows one
  /// field per line. The hash is taken over the text with no indent.
  public static func text(of state: State, indent: Int = 0) -> String {
    text(of: state.json, indent: indent)
  }

  /// The canonical text of a JSON value.
  public static func text(of value: JSONValue, indent: Int = 0) -> String {
    var out = ""
    write(value, indent: indent, depth: 0, into: &out)
    return out
  }

  /// The hash of a state: the SHA-256 of its canonical text, in hexadecimal.
  public static func sha256(of state: State) -> String {
    sha256(of: state.json)
  }

  /// The hash of a JSON value: the SHA-256 of its canonical text, in hexadecimal.
  public static func sha256(of value: JSONValue) -> String {
    let digest = SHA256.hash(data: Data(text(of: value).utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// The JSON value a text carries, whatever order it wrote its keys in.
  public static func value(of text: String) throws -> JSONValue {
    let read = try JSONSerialization.jsonObject(
      with: Data(text.utf8), options: [.fragmentsAllowed])
    return try value(ofRead: read)
  }

  /// One number as the shortest text that reads back as the same number. Swift writes a whole
  /// value with a fraction, so a tempo of 120 would read as `120.0` and the form would not be
  /// the shortest. JSON carries no infinity, so a number that is not finite writes as null.
  static func text(ofNumber number: Double) -> String {
    guard number.isFinite else {
      return "null"
    }
    let written = "\(number)"
    guard written.hasSuffix(".0") else {
      return written
    }
    return String(written.dropLast(2))
  }

  /// One string as JSON, with the characters JSON does not carry written as escapes.
  static func text(ofString string: String) -> String {
    var out = "\""
    for character in string.unicodeScalars {
      switch character {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if character.value < 0x20 {
          out += String(format: "\\u%04x", character.value)
        } else {
          out.unicodeScalars.append(character)
        }
      }
    }
    return out + "\""
  }

  private static func write(_ value: JSONValue, indent: Int, depth: Int, into out: inout String) {
    switch value {
    case .null:
      out += "null"
    case .bool(let carried):
      out += carried ? "true" : "false"
    case .number(let carried):
      out += text(ofNumber: carried)
    case .string(let carried):
      out += text(ofString: carried)
    case .array(let carried):
      writeArray(carried, indent: indent, depth: depth, into: &out)
    case .object(let carried):
      writeObject(carried, indent: indent, depth: depth, into: &out)
    }
  }

  private static func writeArray(
    _ members: [JSONValue], indent: Int, depth: Int, into out: inout String
  ) {
    guard !members.isEmpty else {
      out += "[]"
      return
    }
    out += "["
    for (position, member) in members.enumerated() {
      out += position == 0 ? "" : ","
      out += gap(indent: indent, depth: depth + 1)
      write(member, indent: indent, depth: depth + 1, into: &out)
    }
    out += gap(indent: indent, depth: depth) + "]"
  }

  /// The keys sort by their bytes in UTF-8, so the order is the same on every machine.
  private static func writeObject(
    _ members: [String: JSONValue], indent: Int, depth: Int, into out: inout String
  ) {
    guard !members.isEmpty else {
      out += "{}"
      return
    }
    out += "{"
    for (position, key) in sortedKeys(of: members).enumerated() {
      out += position == 0 ? "" : ","
      out += gap(indent: indent, depth: depth + 1)
      out += text(ofString: key) + (indent > 0 ? ": " : ":")
      write(members[key] ?? .null, indent: indent, depth: depth + 1, into: &out)
    }
    out += gap(indent: indent, depth: depth) + "}"
  }

  /// The keys of an object, sorted by their bytes in UTF-8.
  static func sortedKeys(of members: [String: JSONValue]) -> [String] {
    members.keys.sorted { left, right in
      Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
    }
  }

  private static func gap(indent: Int, depth: Int) -> String {
    guard indent > 0 else {
      return ""
    }
    return "\n" + String(repeating: " ", count: indent * depth)
  }

  private static func value(ofRead read: Any) throws -> JSONValue {
    if read is NSNull {
      return .null
    }
    if let number = read as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }
      return .number(number.doubleValue)
    }
    if let string = read as? String {
      return .string(string)
    }
    if let list = read as? [Any] {
      return .array(try list.map { try value(ofRead: $0) })
    }
    if let members = read as? [String: Any] {
      var out: [String: JSONValue] = [:]
      for (key, member) in members {
        out[key] = try value(ofRead: member)
      }
      return .object(out)
    }
    throw Refusal.notJSON
  }
}
