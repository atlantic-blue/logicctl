import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Automation {
  /// Sets the value of one volume automation point of a region.
  ///
  /// Logic holds the value of a point on a slider in the row of the Event List, and it applies an
  /// edit to every row it holds selected. So the row of the point is held on its own, the
  /// selection is read back, and only then does the slider move. The answer carries every point of
  /// the region as it reads after the change, the way `automation list` carries them.
  struct Set: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "set",
      abstract: "Set the value of one volume automation point of a region.",
      discussion: """
        Logic shows the points of a region in the Event List, so the Event List of the region is \
        open while this runs. A point number the region does not hold stops the command, and \
        nothing is selected and nothing moves. A project logicctl did not make needs --confirm.

        Example: logicctl automation set --track 3 --region 1 --point 1 --value 100
        """)

    @OptionGroup var region: RegionOption

    @OptionGroup var target: PointOption

    @Option(help: "The value the point carries after the change, 0 to 127. 90 is 0 dB.")
    var value: AutomationValue

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
}

extension Automation.Set {
  /// Changes the point, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver, the tree and the rows are given rather than reached for, so the pipeline drives
  /// the same command against a Logic of its own: the driver says what the project holds, the tree
  /// is the windows Logic is showing, and the rows are what Logic is asked to do.
  func answer(
    driver: any LogicDriver,
    of source: @escaping () throws -> LogicTree,
    confirmed: Bool,
    events: EventList.Actions = EventList.Actions.live(),
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
    let command = AutomationSetCommand(
      target: region,
      point: target,
      value: value,
      events: events,
      source: source,
      argv: argv)
    return printer.write(run.run(change: command, confirmed: confirmed))
  }
}

/// The change of the value of one automation point, as the run of a command sees it.
///
/// It asks the driver which region the two numbers name, finds the point in the Event List, holds
/// that row alone, and moves the value slider of the row. It changes the project, so it goes
/// through the guard: a project logicctl did not make is left alone until a person says
/// `--confirm`. The run takes the lock, records the step and answers the envelope around it.
struct AutomationSetCommand: LogicCommand {
  let name = "automation set"

  /// The two numbers that name the region.
  let target: RegionOption

  /// The number that names the point of the region.
  let point: PointOption

  /// The value the point carries after the change.
  let value: AutomationValue

  /// What Logic is asked to do to the rows of the Event List.
  let events: EventList.Actions

  /// The tree of Logic, as the command reads it. It is read again after the step, because a tree
  /// read before a change describes the Logic of a moment ago.
  let source: () throws -> LogicTree

  let argv: [String]

  /// Logic is showing no Event List, so there is no point to change.
  ///
  /// logicctl opens no window itself, so the sentence says what to do rather than naming an
  /// element nobody asked about.
  struct NoEventList: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    /// Whether the value of the point changed before the window went away.
    let changed: Bool

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message: changed
          ? "The point of region \(region) on track \(track) carries the value that was asked "
            + "for, and Logic shows no Event List, so the points cannot be read. Open the Event "
            + "List and read them with automation list."
          : "Logic shows no Event List, so the automation points of region \(region) on track "
            + "\(track) cannot be changed. Select the region and open the Event List.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
        ]))
    }
  }

  /// The region is there and it holds no point with that number.
  ///
  /// The count of the points goes out with the failure, the way the count of the regions goes out
  /// with `region_not_found`: it says which numbers name a point, so a person or an agent asks
  /// again without opening Logic to look.
  struct NoPoint: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    /// The number a person asked for.
    let point: Int

    /// How many points the region holds.
    let points: Int

    var failure: Failure {
      Failure(
        code: .pointNotFound,
        message: "Region \(region) on track \(track) has \(points) "
          + "point\(points == 1 ? "" : "s")",
        details: .object([
          "point": .number(Double(point)),
          "points": .number(Double(points)),
        ]))
    }
  }

  /// The table holds more fader rows than the reader made points of.
  ///
  /// A fader row the reader cannot read every field of carries no number, so the row at place `n`
  /// among the fader rows and the point numbered `n` are two different events. An edit sent on
  /// that count reaches a row nobody named, and the answer reads as the point that was asked for.
  struct RowsDisagree: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    /// How many fader rows the table holds.
    let rows: Int

    /// How many of them read as a point.
    let points: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "The Event List of region \(region) on track \(track) holds \(rows) automation rows "
          + "and \(points) of them read as a point, so no row carries the number that was asked "
          + "for and nothing changed.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
          "rows": .number(Double(rows)),
          "points": .number(Double(points)),
        ]))
    }
  }

  /// The row of the point carries no value slider.
  ///
  /// Nothing moved. The row was held selected by then, which is a state a person can see, so the
  /// sentence names the point rather than the element.
  struct NoValueSlider: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    /// The number of the point in the region.
    let point: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "The row of point \(point) of region \(region) on track \(track) carries no value "
          + "slider, so the value did not change.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
          "point": .number(Double(point)),
        ]))
    }
  }

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let region = try RegionTarget.region(target, in: try driver.readState())
    let track = target.track.value
    guard let window = EventList.window(of: try source()) else {
      throw NoEventList(track: track, region: region.index, changed: false)
    }

    // The rows are read once and held. A write of a selection adds no row and takes none away, and
    // an edit sent at a row read from a second tree could reach an event that moved between the
    // two reads.
    let rows = try EventList.rows(in: window)
    let faders = rows.filter { $0.status == AutomationMenus.faderStatus }
    let points = try AutomationMenus.points(in: window)
    guard faders.count == points.count else {
      throw RowsDisagree(
        track: track, region: region.index, rows: faders.count, points: points.count)
    }
    let asked = point.point.value
    let row = faders[0]

    let names = AutomationSetCommand.names(of: rows, whoseFaderRowsAre: faders)
    try guarded(over: rows, called: names).selectOnly(names[row.place] ?? "point \(asked)")
    // A note row carries its velocity in this column and a fader row carries the value of its
    // point, so the slider of the row is the one the reader of the points takes a value from.
    guard let slider = EventList.velocitySlider(of: row.row) else {
      throw NoValueSlider(track: track, region: region.index, point: asked)
    }
    _ = try events.stepper(slider).move(to: value.value)

    guard let after = EventList.window(of: try source()) else {
      throw NoEventList(track: track, region: region.index, changed: true)
    }
    return .object([
      "track": .number(Double(track)),
      "region": .number(Double(region.index)),
      "points": .array(try AutomationMenus.points(in: after).map(\.json)),
    ])
  }

  /// The guard that holds one row of the table and nothing else.
  ///
  /// The write goes to every row, so a row Logic held from an earlier edit is let go rather than
  /// left for the readback to find. The readback answers the rows Logic says it holds, in the
  /// order of the table.
  private func guarded(over rows: [EventList.Row], called names: [Int: String]) -> SelectionGuard {
    SelectionGuard(
      select: { holding in
        for row in rows {
          try self.events.select(row.row, holding.contains(names[row.place] ?? ""))
        }
      },
      selection: {
        try rows.filter { try self.events.selected($0.row) }
          .compactMap { names[$0.place] }
      })
  }

  /// The name each row of the table is known by, against the place it sits at.
  ///
  /// A point is named by the number `--point` takes and a note by the number `--note` takes, so
  /// `selection_mismatch` says which events Logic kept in the words a person types them in. Any
  /// other row is named by what its Status cell says and where it sits.
  static func names(of rows: [EventList.Row], whoseFaderRowsAre faders: [EventList.Row])
    -> [Int: String]
  {
    var names: [Int: String] = [:]
    for row in rows {
      if let note = row.note {
        names[row.place] = "note \(note)"
      } else {
        names[row.place] = "\(row.status ?? "the") row \(row.place)"
      }
    }
    for (place, row) in faders.enumerated() {
      names[row.place] = "point \(place + 1)"
    }
    return names
  }
}
