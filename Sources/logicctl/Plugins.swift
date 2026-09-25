import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// What logicctl does with the plugins of a channel strip.
///
/// The noun carries several verbs, so a person types `logicctl plugins list` and the verb that
/// inserts a plugin comes under the same word.
struct Plugins: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plugins",
    abstract: "Read and change the plugins of the channel strip of one track.",
    discussion: """
      Example: logicctl plugins list --track 1
      """,
    subcommands: [List.self, Insert.self])
}

extension Plugins {
  /// Prints the plugins of the channel strip of one track, in slot order.
  ///
  /// A track with no plugin prints an empty list and exits 0. That is a state and not a failure: an
  /// agent reads the one field, sees no plugin, and inserts one.
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "Print the plugins of the channel strip of one track.",
      discussion: """
        A row carries the slot the plugin sits in, from 1, its name, and the hash of its settings \
        at the last save. The instrument of the track is the first slot. Logic shows the channel \
        strips in the Mixer, so the Mixer of the project is open while this runs.

        Example: logicctl plugins list --track 1
        """)

    @OptionGroup var target: TrackOption

    @OptionGroup var output: OutputOption

    func run() throws {
      let status = answer(
        driver: Plugins.liveDriver(), of: LogicTree.ofRunningLogic, format: output.format)
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Plugins.List {
  /// Reads the plugins, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver and the tree are given rather than reached for, so the pipeline drives the same
  /// command against a Logic of its own: the driver says what the project holds, and the tree is
  /// the window Logic is showing the channel strips in.
  func answer(
    driver: any LogicDriver,
    of source: @escaping () throws -> LogicTree,
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
    return printer.write(
      run.run(command: PluginsListCommand(target: target, source: source, argv: argv)))
  }
}

extension Plugins {
  /// What this command reads Logic through on this Mac.
  static func liveDriver() -> any LogicDriver {
    Tracks.liveDriver()
  }
}

/// The reading of the plugins of one channel strip, as the run of a command sees it.
///
/// It changes nothing in Logic. It asks the driver which track the number names, and reads the
/// slots out of the strip that Logic is showing for that track. The run takes the lock, records the
/// step and answers the envelope around it.
struct PluginsListCommand: LogicCommand {
  let name = "plugins list"

  /// The number that names the track.
  let target: TrackOption

  /// The tree of Logic, as the command reads it.
  let source: () throws -> LogicTree

  let argv: [String]

  /// Logic is not showing the Mixer, so there is no channel strip to read.
  ///
  /// logicctl does not open the Mixer itself, so the sentence says what to do rather than naming an
  /// element nobody asked about.
  struct NoMixer: FailureCarrying, Equatable {
    /// The track the plugins were asked for.
    let track: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "Logic shows no Mixer, so the plugins of track \(track) cannot be read. "
          + "Open the Mixer.",
        details: .object(["track": .number(Double(track))]))
    }
  }

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let number = target.track.value
    guard let track = try driver.readState().tracks.first(where: { $0.index == number }) else {
      throw RegionTarget.NoTrack(index: number)
    }
    let tree = try source()
    guard let window = ChannelStrip.window(of: tree) else {
      throw NoMixer(track: number)
    }
    let plugins = try ChannelStrip.plugins(
      ofTrackNumber: number, named: track.name, in: window)
    return .object([
      "track": .number(Double(number)),
      "plugins": .array(plugins.map(\.json)),
    ])
  }
}
