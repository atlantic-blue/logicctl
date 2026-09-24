import Foundation

/// How the JSON of an envelope is laid out.
public enum OutputFormat: Sendable {
  /// One line with no white space, which is what an agent reads.
  case compact

  /// Two spaces for each level, which is what `--pretty` asks for.
  case pretty

  /// The indent the canonical writer lays the envelope out by.
  var indent: Int {
    switch self {
    case .compact: return 2
    case .pretty: return 2
    }
  }
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
    standardOutput(CanonicalJSON.text(of: envelope.json, indent: format.indent) + "\n")
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
