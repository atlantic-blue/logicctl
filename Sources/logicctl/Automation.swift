import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// What logicctl does with the volume automation of one region.
///
/// The noun carries several verbs, so a person types `logicctl automation add` and the verbs that
/// read and change the points come under the same word.
struct Automation: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "automation",
    abstract: "Make and read the volume automation of one region.",
    discussion: """
      Example: logicctl automation add --track 3 --region 1
      """,
    subcommands: [Add.self])
}

extension Automation {
  /// Makes the volume automation points at the borders of one region, and prints them.
  ///
  /// Logic makes the points as track automation and then moves them into the region, which is the
  /// two items of the Mix menu this presses. It asks Logic for 2 points and Logic can make a third
  /// at the end of the region. The answer carries every point Logic made, because the number in
  /// the menu is what was asked for and not what is in the region afterwards.
  struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "add",
      abstract: "Make the volume automation points at the borders of one region.",
      discussion: """
        Logic shows the points of a region in the Event List, so the Event List of the region is \
        open while this runs. A project logicctl did not make needs --confirm.

        Example: logicctl automation add --track 3 --region 1
        """)

    @OptionGroup var region: RegionOption

    @OptionGroup var guarded: ConfirmOption

    @OptionGroup var output: OutputOption

    func run() throws {
      let status = answer(
        driver: Automation.liveDriver(),
        of: LogicTree.ofRunningLogic,
        confirmed: guarded.confirm,
        format: output.format)
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }

  /// What these commands read Logic through on this Mac.
  static func liveDriver() -> any LogicDriver {
    Tracks.liveDriver()
  }
}

extension Automation.Add {
  /// Makes the points, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver, the tree and the menus are given rather than reached for, so the pipeline drives
  /// the same command against a Logic of its own: the driver says what the project holds, the tree
  /// is the windows Logic is showing, and the menus are what Logic is asked to do.
  func answer(
    driver: any LogicDriver,
    of source: @escaping () throws -> LogicTree,
    confirmed: Bool,
    menus: AutomationMenus = AutomationMenus.live(),
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
    let command = AutomationAddCommand(
      target: region, menus: menus, source: source, argv: argv)
    return printer.write(run.run(change: command, confirmed: confirmed))
  }
}

/// The making of the automation points of one region, as the run of a command sees it.
///
/// It asks the driver which region the two numbers name, selects that region in the Tracks window,
/// presses the two items of the Mix menu, and reads the points back out of the Event List. It
/// changes the project, so it goes through the guard: a project logicctl did not make is left
/// alone until a person says `--confirm`. The run takes the lock, records the step and answers the
/// envelope around it.
struct AutomationAddCommand: LogicCommand {
  let name = "automation add"

  /// The two numbers that name the region.
  let target: RegionOption

  /// What Logic is asked to do in the menu bar and in the Tracks window.
  let menus: AutomationMenus

  /// The tree of Logic, as the command reads it. It is read again after the presses, because a
  /// tree read before a change describes the Logic of a moment ago.
  let source: () throws -> LogicTree

  let argv: [String]

  /// Logic is not showing the region anywhere, so there is nothing to select and nothing to make
  /// points at the borders of.
  ///
  /// The state says the region is there, and the Tracks window does not show it, which is what a
  /// window scrolled elsewhere or a hidden track looks like from here. Nothing is pressed after
  /// this: Logic makes the points at the borders of whatever region is selected, so a press with
  /// the wrong region selected writes points into somebody else's region.
  struct NoRegionItem: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "The Tracks window does not show region \(region) on track \(track), so it cannot be "
          + "selected and no automation point was made.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
        ]))
    }
  }

  /// Logic is showing no Event List, so the points cannot be read.
  ///
  /// The points are made by the time this is thrown. The command says so, because a person reading
  /// it needs to know that the region gained the points and only the answer is missing.
  struct NoEventListAfter: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "Region \(region) on track \(track) gained its automation points, and Logic shows no "
          + "Event List, so the points cannot be read. Open the Event List and read them with "
          + "automation list.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
        ]))
    }
  }

  /// The Event List shows no point, so the two presses reached nothing.
  ///
  /// Logic makes at least two points at the borders of a region, so an empty answer here is never
  /// a region that holds no automation. It is a menu item Logic did not act on, which is what a
  /// region that was not selected looks like from here. An empty list would read as a command that
  /// worked on a region with nothing in it.
  struct NoPointsAfter: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "The Event List shows no automation point of region \(region) on track \(track) after "
          + "both items of the Mix menu were pressed, so Logic made none.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
        ]))
    }
  }

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let region = try RegionTarget.region(target, in: try driver.readState())
    let track = target.track.value
    guard
      let item = AutomationMenus.regionItem(
        number: region.index, ofTrack: track, in: try source().root)
    else {
      throw NoRegionItem(track: track, region: region.index)
    }
    try menus.addPoints(atTheBordersOf: item)
    guard let events = EventList.window(of: try source()) else {
      throw NoEventListAfter(track: track, region: region.index)
    }
    let points = try AutomationMenus.points(in: events)
    guard !points.isEmpty else {
      throw NoPointsAfter(track: track, region: region.index)
    }
    return .object([
      "track": .number(Double(track)),
      "region": .number(Double(region.index)),
      "points": .array(points.map(\.json)),
    ])
  }
}
