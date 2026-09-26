import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Midi {
  /// Sets the velocity of one note of a region.
  ///
  /// The type is not called `Velocity`, because `Velocity` is the scale of 1 to 127 that every
  /// command of this noun takes, and a type of that name under `Midi` hides the scale from all of
  /// them. The command a person types is `velocity`.
  ///
  /// Logic holds the velocity of a note on a slider in the row of the Event List, and it applies an
  /// edit to every row it holds selected. So the row of the note is held on its own, the selection
  /// is read back, and only then does the slider move. The answer names the one note it changed and
  /// the velocity the slider reads afterwards.
  struct SetVelocity: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "velocity",
      abstract: "Set the velocity of one note of a region.",
      discussion: """
        Logic shows the velocity of a note in the Event List, so the Event List of the region is \
        open while this runs. A note number the region does not hold stops the command, and \
        nothing is selected and nothing moves. The velocity in the answer is the one the slider \
        reads after the change, which is what the note carries.

        Example: logicctl midi velocity --track 4 --region 1 --note 2 --value 90
        """)

    @OptionGroup var region: RegionOption

    @OptionGroup var target: NoteOption

    @Option(help: "The velocity the note carries after the change, 1 to 127.")
    var value: Velocity

    @OptionGroup var guarded: ConfirmOption

    @OptionGroup var output: OutputOption

    func run() throws {
      let status = answer(
        driver: Midi.SetVelocity.liveDriver(),
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

extension Midi.SetVelocity {
  /// Changes the velocity, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver, the tree and the rows are given rather than reached for, so the pipeline drives
  /// the same command against a Logic of its own: the driver says what the project holds, the tree
  /// is the window Logic is showing the events in, and the rows are what Logic is asked to do.
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
    return printer.write(
      run.run(
        command: MidiVelocityCommand(
          target: region,
          note: target,
          value: value,
          events: events,
          source: source,
          argv: argv)))
  }

  /// What this command reads Logic through on this Mac.
  static func liveDriver() -> any LogicDriver {
    Tracks.liveDriver()
  }
}

/// The change of the velocity of one note, as the run of a command sees it.
///
/// It asks the driver which region the two numbers name, finds the note in the Event List, holds
/// that row alone, and moves the velocity slider of the row. The run takes the lock, records the
/// step and answers the envelope around it.
struct MidiVelocityCommand: LogicCommand {
  let name = "midi velocity"

  /// The two numbers that name the region.
  let target: RegionOption

  /// The number that names the note of the region.
  let note: NoteOption

  /// The velocity the note carries after the change.
  let value: Velocity

  /// What Logic is asked to do to the rows of the Event List.
  let events: EventList.Actions

  /// The tree of Logic, as the command reads it.
  let source: () throws -> LogicTree

  let argv: [String]

  /// Logic is showing no Event List, so there is no note to change.
  ///
  /// logicctl opens no window itself, so the sentence says what to do rather than naming an
  /// element nobody asked about.
  struct NoEventList: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "Logic shows no Event List, so the notes of region \(region) on track \(track) "
          + "cannot be changed. Select the region and open the Event List.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
        ]))
    }
  }

  /// The region is there and it holds no note with that number.
  ///
  /// The count of the notes goes out with the failure, the way the count of the regions goes out
  /// with `region_not_found`: it says which numbers name a note, so a person or an agent asks
  /// again without opening Logic to look.
  struct NoNote: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    /// The number a person asked for.
    let note: Int

    /// How many notes the region holds.
    let notes: Int

    var failure: Failure {
      Failure(
        code: .noteNotFound,
        message: "Region \(region) of track \(track) has no note \(note)",
        details: .object(["notes": .number(Double(notes))]))
    }
  }

  /// The row of the note carries no velocity slider.
  ///
  /// Nothing moved. The row was held selected by then, which is a state a person can see, so the
  /// sentence names the note rather than the element.
  struct NoVelocitySlider: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    /// The number of the note in the region.
    let note: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "The row of note \(note) of region \(region) on track \(track) carries no velocity "
          + "slider, so the velocity did not change.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
          "note": .number(Double(note)),
        ]))
    }
  }

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let region = try RegionTarget.region(target, in: try driver.readState())
    guard let window = EventList.window(of: try source()) else {
      throw NoEventList(track: target.track.value, region: region.index)
    }

    // The rows are read once and held. A write of a selection adds no row and takes none away, and
    // an edit sent at a row read from a second tree could reach an event that moved between the
    // two reads.
    let rows = try EventList.rows(in: window)
    let asked = note.note.value
    guard let row = rows.first(where: { $0.note == asked }) else {
      throw NoNote(
        track: target.track.value,
        region: region.index,
        note: asked,
        notes: rows.compactMap(\.note).count)
    }

    try guarded(over: rows).selectOnly(MidiVelocityCommand.named(row))
    guard let slider = EventList.velocitySlider(of: row.row) else {
      throw NoVelocitySlider(
        track: target.track.value, region: region.index, note: asked)
    }
    let reached = try events.stepper(slider).move(to: value.value)

    return .object([
      "track": .number(Double(target.track.value)),
      "region": .number(Double(region.index)),
      "note": .number(Double(asked)),
      "velocity": .number(Double(reached)),
    ])
  }

  /// The guard that holds one row of the table and nothing else.
  ///
  /// The write goes to every row, so a row Logic held from an earlier edit is let go rather than
  /// left for the readback to find. The readback answers the rows Logic says it holds, in the
  /// order of the table.
  private func guarded(over rows: [EventList.Row]) -> SelectionGuard {
    SelectionGuard(
      select: { holding in
        for row in rows {
          try self.events.select(row.row, holding.contains(MidiVelocityCommand.named(row)))
        }
      },
      selection: {
        try rows.filter { try self.events.selected($0.row) }.map(MidiVelocityCommand.named)
      })
  }

  /// The name a row is known by, in the words a person typed or the words Logic shows.
  ///
  /// A note is named by the number `--note` takes. Any other row is named by what its Status cell
  /// says and where it sits, so `selection_mismatch` says which event Logic kept.
  static func named(_ row: EventList.Row) -> String {
    guard let note = row.note else {
      return "\(row.status ?? "the") row \(row.place)"
    }
    return "note \(note)"
  }
}
