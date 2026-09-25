import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension NewTrackType: ExpressibleByArgument {
  /// The check of the word is not built yet, so every word reads as an audio track.
  public init?(argument: String) {
    self = .audio
  }
}

extension Tracks {
  /// Adds one track to the project Logic has open, and prints the row of the track it added.
  ///
  /// The two words `--type` takes are the two kinds of track the stories ask for. Any other word
  /// is refused where the arguments are read, so Logic is never asked for a kind it has no item
  /// for, the project does not change, and the session gains no step.
  struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "add",
      abstract: "Add one track to the project Logic has open.",
      discussion: """
        The type is software-instrument or audio. Any other word is refused before Logic is \
        asked anything. A project logicctl did not make needs --confirm.

        Example: logicctl tracks add --type software-instrument
        """)

    @Option(help: "The kind of track to add: software-instrument or audio.")
    var type: NewTrackType

    @OptionGroup var guarded: ConfirmOption

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    func run() throws {
      let status = Tracks.Add.answer(
        driver: Tracks.liveDriver(),
        actions: TrackActions.live(),
        type: type,
        confirmed: guarded.confirm,
        limitMs: wait.timeout.milliseconds,
        format: output.format,
        argv: ["--type", type.rawValue])
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Tracks.Add {
  /// Adds the track, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver and the action are given rather than reached for, so the pipeline drives the same
  /// command against a Logic of its own.
  static func answer(
    driver: any LogicDriver,
    actions: TrackActions,
    type: NewTrackType,
    confirmed: Bool,
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    limitMs: Int = Wait.defaultLimitMs,
    format: OutputFormat = .compact,
    argv: [String] = [],
    now: @escaping () -> Date = { Date() },
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds,
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
    let command = TracksAddCommand(
      argv: argv, type: type, actions: actions, limitMs: limitMs, clock: clock, sleeper: sleeper)
    return printer.write(run.run(change: command, confirmed: confirmed))
  }
}

/// The adding of one track, as the run of a command sees it.
///
/// It changes the project, so it goes through the guard: a project logicctl did not make is left
/// alone until a person says `--confirm`. The run takes the lock, records the step and answers the
/// envelope around it.
struct TracksAddCommand: LogicCommand {
  let name = "tracks add"

  let argv: [String]

  /// The kind of track the person asked for.
  let type: NewTrackType

  /// What makes the track in Logic.
  let actions: TrackActions

  /// How long the read of the new track may take, in milliseconds.
  let limitMs: Int

  /// The clock the wait reads.
  let clock: Wait.Clock

  /// How the wait sleeps between two reads.
  let sleeper: Wait.Sleeper

  /// Presses the item of the Track menu, waits for the project to hold one track more, and
  /// answers the row of the track it gained.
  ///
  /// The tracks are counted before and after, because that count is the whole of the evidence
  /// that the press did what it was asked to do. A press that made no track, and a press that
  /// made two, both leave the wait to run out, and the command fails with `timeout` rather than
  /// printing a row Logic never showed.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let before = try driver.readState().tracks
    try actions.add(type)
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      try driver.readState().tracks.count == before.count + 1
    }
    let after = try driver.readState().tracks
    guard var added = TracksAddCommand.theTrack(gainedFrom: before, in: after) else {
      throw TrackActions.Refusal(
        reason: "Logic answered \(after.count) tracks and the project had \(before.count) "
          + "before the track was added, so the new track could not be read.")
    }
    // The header of a track says nothing about its kind, so a row read back from Logic reads as
    // the kind that is neither. The person asked for one of the two, and Logic has one item for
    // each, so the row carries the kind that was asked for.
    added.type = type.kind
    return .object(["track": TracksListCommand.row(of: added)])
  }

  /// The track the project gained, or nothing when it gained none.
  ///
  /// Logic puts a new track under the track that is selected, so the row is not always the last
  /// one, and the walk answers the first place where the two lists disagree. Two rows that carry
  /// the same name and the same three buttons cannot be told apart, so a new track beside its own
  /// twin reads as the later of the two, which carries the same values.
  static func theTrack(gainedFrom before: [Track], in after: [Track]) -> Track? {
    for (place, track) in after.enumerated() {
      guard place < before.count else {
        return track
      }
      if !TracksAddCommand.sameTrack(before[place], track) {
        return track
      }
    }
    return nil
  }

  /// Whether two rows are the same track, which is every field of a row but its number.
  ///
  /// A track that goes in above another moves the number of that one, so a comparison that read
  /// the number would call every row under the new track a new track.
  private static func sameTrack(_ one: Track, _ other: Track) -> Bool {
    one.name == other.name && one.type == other.type && one.mute == other.mute
      && one.solo == other.solo && one.arm == other.arm
  }
}
