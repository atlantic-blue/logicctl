import Foundation

/// How the JSON of an envelope is laid out.
public enum OutputFormat {
  /// One line with no white space, which is what an agent reads.
  case compact

  /// Two spaces for each level, which is what `--pretty` asks for.
  case pretty
}

/// Prints the envelope of a command.
///
/// Standard output carries exactly one JSON object and a newline. Standard error carries one line
/// when the command failed, and nothing at all when it worked, so a person reading along sees the
/// failure while an agent keeps reading standard output alone.
public struct EnvelopePrinter {
  /// Where a piece of text goes. A test gives its own, and reads back what was written.
  public typealias Write = (String) -> Void

  private let format: OutputFormat
  private let standardOutput: Write
  private let standardError: Write

  public init(
    format: OutputFormat = .compact,
    standardOutput: @escaping Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping Write = EnvelopePrinter.writeToStandardError
  ) {
    self.format = format
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  /// Prints one envelope and answers with the number the process exits with.
  @discardableResult
  public func write(_ envelope: Envelope) -> Int32 {
    standardOutput(JSONText.of(envelope.json, format: format) + "\n")
    if let failure = envelope.error {
      standardError("logicctl: \(failure.code.rawValue): \(failure.message)\n")
    }
    return envelope.exitCode
  }

  /// Sends text to the standard output of the process.
  public static func writeToStandardOutput(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
  }

  /// Sends text to the standard error of the process.
  public static func writeToStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
  }
}

/// Turns a JSON value into the exact text that goes out.
///
/// Keys are sorted, so one envelope always prints the same bytes, whatever order a command built
/// its answer in.
enum JSONText {
  static func of(_ value: JSONValue, format: OutputFormat) -> String {
    switch format {
    case .compact: return compact(value)
    case .pretty: return pretty(value, depth: 0)
    }
  }

  private static func compact(_ value: JSONValue) -> String {
    switch value {
    case .null: return "null"
    case .bool(let flag): return flag ? "true" : "false"
    case .int(let number): return String(number)
    case .double(let number): return number.isFinite ? String(number) : "null"
    case .string(let text): return quoted(text)
    case .array(let items): return "[" + items.map(compact).joined(separator: ",") + "]"
    case .object(let fields):
      let pairs = fields.keys.sorted().map { key in
        quoted(key) + ":" + compact(fields[key] ?? .null)
      }
      return "{" + pairs.joined(separator: ",") + "}"
    }
  }

  private static func pretty(_ value: JSONValue, depth: Int) -> String {
    let inside = String(repeating: "  ", count: depth + 1)
    let outside = String(repeating: "  ", count: depth)
    switch value {
    case .array(let items):
      if items.isEmpty { return "[]" }
      let lines = items.map { inside + pretty($0, depth: depth + 1) }
      return "[\n" + lines.joined(separator: ",\n") + "\n" + outside + "]"
    case .object(let fields):
      if fields.isEmpty { return "{}" }
      let lines = fields.keys.sorted().map { key in
        inside + quoted(key) + ": " + pretty(fields[key] ?? .null, depth: depth + 1)
      }
      return "{\n" + lines.joined(separator: ",\n") + "\n" + outside + "}"
    default: return compact(value)
    }
  }

  private static func quoted(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}
