import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// What logicctl does with the tracks of the project Logic has open.
///
/// The noun carries several verbs, so a person types `logicctl tracks list` and the verbs that
/// change a track come under the same word.
struct Tracks: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tracks",
    abstract: "Read and change the tracks of the project Logic has open.",
    discussion: """
      Example: logicctl tracks list
      """,
    subcommands: [List.self, Add.self, Rename.self])
}

extension Tracks {
  /// Prints one row per track of the project Logic has open.
  ///
  /// A project with no track prints an empty list and exits 0. That is a state and not a failure:
  /// an agent reads the one field, sees no track, and adds one. A failure there would stop a
  /// script on a condition that nothing is wrong with.
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "Print one row per track of the project Logic has open.",
      discussion: """
        A row carries the number of the track, its name, its type, and whether it is muted, \
        soloed and armed to record. A project with no track prints an empty list and exits 0.

        Example: logicctl tracks list
        """)

    @OptionGroup var output: OutputOption

    func run() throws {
      let status = Tracks.List.answer(driver: Tracks.liveDriver(), format: output.format)
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Tracks.List {
  /// Reads the tracks, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver is given rather than reached for, so the pipeline drives the same command against
  /// a Logic of its own.
  static func answer(
    driver: any LogicDriver,
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    format: OutputFormat = .compact,
    argv: [String] = [],
    now: @escaping () -> Date = { Date() },
    git: Git = Git(),
    lock: Lock = Lock(),
    capturer: any WindowCapturer = WindowCapture(),
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)
    let run = Run(
      driver: driver,
      root: root,
      version: version,
      now: now,
      git: git,
      lock: lock,
      capturer: capturer)
    return printer.write(run.run(command: TracksListCommand(argv: argv)))
  }
}

extension Tracks {
  /// What this command reads the state of Logic through on this Mac.
  ///
  /// Nothing in logicctl reads the whole state of Logic yet, so there is no driver over the real
  /// Logic to give here. The step that brings one hands it to every command at once, and this
  /// command is written against the protocol so that it needs no change when it arrives.
  static func liveDriver() -> any LogicDriver {
    NewProject.liveDriver()
  }
}

/// The reading of the tracks, as the run of a command sees it.
///
/// It changes nothing in Logic, so it asks the driver for the state and writes down what it holds.
/// The run takes the lock, records the step and answers the envelope around it.
struct TracksListCommand: LogicCommand {
  let name = "tracks list"

  let argv: [String]

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let tracks = try driver.readState().tracks
    return .object(["tracks": .array(tracks.map(TracksListCommand.row(of:)))])
  }

  /// One track, as a row of the answer.
  ///
  /// The regions and the plugins of the state are not here. This command answers the list of
  /// tracks, and a row carries the six fields a person reads to pick one.
  static func row(of track: Track) -> JSONValue {
    .object([
      "index": .number(Double(track.index)),
      "name": .string(track.name),
      "type": .string(track.type.rawValue),
      "mute": .bool(track.mute),
      "solo": .bool(track.solo),
      "arm": .bool(track.arm),
    ])
  }
}
