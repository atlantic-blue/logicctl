import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Automation {
  /// Prints one row per automation point of one region.
  ///
  /// The region is named by the track it sits on and its place from the left, as every automation
  /// command names one. A row carries the number `--point` takes, where the point sits, which
  /// parameter it moves and its value on the fader scale of Logic.
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "Print one row per automation point of one region.",
      discussion: """
        Logic shows the points of a region in the Event List, so the Event List of the region is \
        open while this runs. A region with no automation point prints an empty list and exits 0.

        Example: logicctl automation list --track 3 --region 1
        """)

    @OptionGroup var region: RegionOption

    @OptionGroup var output: OutputOption

    func run() throws {
      let status = answer(
        driver: Automation.liveDriver(), of: LogicTree.ofRunningLogic, format: output.format)
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Automation.List {
  /// Reads the points, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver and the tree are given rather than reached for, so the pipeline drives the same
  /// command against a Logic of its own: the driver says what the project holds, and the tree is
  /// the windows Logic is showing.
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
      run.run(command: AutomationListCommand(target: region, source: source, argv: argv)))
  }
}

/// The reading of the automation points of one region, as the run of a command sees it.
///
/// It changes nothing in Logic. It asks the driver which region the two numbers name, and reads
/// the points out of the window Logic is showing the events in. The run takes the lock, records
/// the step and answers the envelope around it.
struct AutomationListCommand: LogicCommand {
  let name = "automation list"

  /// The two numbers that name the region.
  let target: RegionOption

  /// The tree of Logic, as the command reads it.
  let source: () throws -> LogicTree

  let argv: [String]

  /// Logic is not showing the events of any region, so there is nothing to read.
  ///
  /// logicctl does not open the Event List itself, so the sentence says what to do rather than
  /// naming an element nobody asked about.
  struct NoEventList: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "Logic shows no Event List, so the automation points of region \(region) on track "
          + "\(track) cannot be read. Select the region and open the Event List.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
        ]))
    }
  }

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let region = try RegionTarget.region(target, in: try driver.readState())
    let track = target.track.value
    guard EventList.window(of: try source()) != nil else {
      throw NoEventList(track: track, region: region.index)
    }
    return .object([
      "track": .number(Double(track)),
      "region": .number(Double(region.index)),
      "points": .array([]),
    ])
  }
}
