import ArgumentParser
import Foundation
import LogicctlCore

/// What logicctl does with MIDI.
///
/// One of them writes a file and never opens Logic. `note` plays one note into the bus of Logic,
/// and the commands that send more than one note arrive under the same noun.
struct Midi: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "midi",
    abstract: "Write MIDI files and send MIDI to Logic.",
    discussion: """
      Example: logicctl midi write-file --in notes.json --out notes.mid
      """,
    subcommands: [
      Setup.self, Note.self, Chord.self, ControlChange.self, Notes.self, Quantize.self,
      Velocity.self, WriteFile.self,
    ])
}

extension Midi {
  /// Writes a standard MIDI file from a list of notes.
  ///
  /// It reads no Logic. So it takes no lock, it writes no step, and its answer carries no session
  /// and no step in `meta`, the way the data model asks. An agent writes a file, reads the hash of
  /// the bytes it got, and imports the same file later with `midi import`.
  struct WriteFile: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "write-file",
      abstract: "Write a MIDI file from a list of notes.",
      discussion: """
        The file of notes carries a tempo and a list of notes, each with a pitch, a velocity, a \
        start and a length in beats. The same notes give the same bytes, so the answer carries \
        the hash of what was written and two runs can be compared. A file at --out is \
        overwritten.

        Example: logicctl midi write-file --in notes.json --out notes.mid
        """)

    /// What this command refuses with on its own. What the file says is refused by the reader.
    enum Trouble: Error {
      /// `--in` names a file that cannot be read.
      case cannotRead(String)

      /// `--out` names a place the bytes cannot be written to.
      case cannotWrite(String)
    }

    @Option(name: .customLong("in"), help: "The JSON file of notes to read.")
    var input: String

    @Option(help: "Where to write the MIDI file. A file that is there is overwritten.")
    var out: String

    @OptionGroup var output: OutputOption

    func validate() throws {
      guard FileManager.default.fileExists(atPath: input) else {
        throw ValidationError("--in names a file that is not there: \(input).")
      }
      let folder = URL(fileURLWithPath: out).deletingLastPathComponent()
      guard FileManager.default.fileExists(atPath: folder.path) else {
        throw ValidationError("--out names a folder that is not there: \(folder.path).")
      }
    }

    func run() throws {
      let status = answer(format: output.format)
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Midi.WriteFile {
  /// Reads the notes, writes the bytes, prints the envelope, and answers the number the process
  /// exits with.
  func answer(
    format: OutputFormat = .compact,
    now: () -> Date = { Date() },
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)

    // This command reads no Logic, so it carries no session and no step in `meta`.
    func meta() -> Meta {
      AnswerMeta.refusal(version: Logicctl.version, from: started, to: now())
    }

    do {
      let notes = try NotesFile.read(notesText())
      let bytes = MidiFile.bytes(of: notes)
      try writeBytes(bytes)
      return printer.write(
        Envelope.success(
          data: .object([
            "path": .string(out),
            "notes": .number(Double(notes.notes.count)),
            "sha256": .string(MidiFile.sha256(of: bytes)),
          ]),
          meta: meta()))
    } catch {
      return printer.write(Envelope.failure(Midi.WriteFile.failure(for: error), meta: meta()))
    }
  }

  /// The text of the file `--in` names.
  private func notesText() throws -> String {
    do {
      return try String(contentsOf: URL(fileURLWithPath: input), encoding: .utf8)
    } catch {
      throw Trouble.cannotRead(error.localizedDescription)
    }
  }

  /// The bytes, written where `--out` names. Nothing is written when the notes were refused, so a
  /// run that failed leaves no file behind for the next run to read as its own.
  private func writeBytes(_ bytes: [UInt8]) throws {
    do {
      try Data(bytes).write(to: URL(fileURLWithPath: out), options: .atomic)
    } catch {
      throw Trouble.cannotWrite(error.localizedDescription)
    }
  }

  /// The failure an error stopped the command with.
  ///
  /// A file that says something logicctl cannot use is an argument that is wrong, so it carries
  /// `invalid_argument` and names its field, the way a wrong flag does. A file that cannot be
  /// written is nothing the caller asked for wrongly, so it carries `internal`.
  static func failure(for error: Error) -> Failure {
    if let refusal = error as? NotesFile.Refusal {
      return Failure(
        code: .invalidArgument, message: refusal.message,
        details: .object(["field": .string(refusal.field)]))
    }
    if let trouble = error as? Trouble {
      switch trouble {
      case .cannotRead(let reason):
        return Failure(
          code: .invalidArgument, message: "--in must name a file that can be read: \(reason)",
          details: .object(["field": .string("--in")]))
      case .cannotWrite(let reason):
        return Failure(
          code: .internalFailure, message: "the MIDI file was not written: \(reason)",
          details: .object(["field": .string("--out")]))
      }
    }
    return Failure(
      code: .internalFailure, message: "the MIDI file was not written: \(error)",
      details: nil)
  }
}
