import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension TransportCommand {
  /// Sets the tempo of the project Logic has open, and answers the tempo Logic shows after it.
  ///
  /// The number in the answer is read from Logic and never from the write. The tempo display takes
  /// no number in one go: a write moves it one step, so a command that printed 96 because it wrote
  /// 96 would report a speed the project does not carry, and the project would sit at 119. Every
  /// note played against it lands in the wrong place, and the person hears the fault only after
  /// the take is recorded.
  struct Tempo: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "tempo",
      abstract: "Set the tempo of the project Logic has open.",
      discussion: """
        The tempo is a whole number of beats each minute, from 20 to 999, which is the range \
        `midi write-file` takes. A number outside it stops the command before Logic is asked \
        anything. The answer carries the tempo as Logic shows it after the change, so a display \
        that did not reach the number is a failure and never a report of a tempo Logic refused. \
        The tempo belongs to the project, so a project logicctl did not make needs --confirm.

        Example: logicctl transport tempo 96
        """)

    @Argument(help: "The tempo, in beats each minute, from 20 to 999.")
    var tempo: Int

    @OptionGroup var guarded: ConfirmOption

    @OptionGroup var output: OutputOption

    @OptionGroup var wait: TimeoutOption

    /// Refuses a tempo Logic does not carry, before Logic is asked anything.
    ///
    /// The range is the one the approved data model gives the tempo of `notes.json`, so a tempo of
    /// 5 is refused the same way whether a person writes a MIDI file or sets the project.
    func validate() throws {
      guard NotesFile.tempoRange.contains(Double(tempo)) else {
        let lowest = Int(NotesFile.tempoRange.lowerBound)
        let highest = Int(NotesFile.tempoRange.upperBound)
        throw ValidationError(
          "Give a tempo from \(lowest) to \(highest). \(tempo) is outside what Logic carries.")
      }
    }

    func run() throws {
      let status = TransportCommand.Tempo.answer(
        driver: NewProject.liveDriver(),
        field: TempoField.live(),
        tempo: tempo,
        confirmed: guarded.confirm,
        limitMs: wait.timeout.milliseconds,
        format: output.format,
        argv: [String(tempo)])
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension TransportCommand.Tempo {
  /// Sets the tempo, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver, the display and the clock are given rather than reached for, so the pipeline runs
  /// the same command with nothing of this Mac in the way and no real wait spent on it.
  static func answer(
    driver: any LogicDriver,
    field: TempoField,
    tempo: Int,
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
    let command = SetTheTempo(
      argv: argv,
      tempo: tempo,
      field: field,
      limitMs: limitMs,
      clock: clock,
      sleeper: sleeper)
    return printer.write(run.run(change: command, confirmed: confirmed))
  }
}

/// The tempo the run records: the move of the display, then the tempo of Logic.
///
/// Logic keeps the tempo in the project, in `MetaData.plist`, so this is a change to the work of
/// whoever owns the project. It goes through the guard, and a project logicctl did not make is
/// left alone until a person says `--confirm`. Play, stop and record write nothing into a project
/// and are not guarded.
struct SetTheTempo: LogicCommand {
  let name = "transport tempo"

  let argv: [String]

  /// The tempo the person asked for, in beats each minute.
  let tempo: Int

  /// What moves the tempo display of Logic.
  let field: TempoField

  /// How long the move and the read back may take, in milliseconds.
  let limitMs: Int

  /// The clock the wait reads.
  let clock: Wait.Clock

  /// How the wait sleeps between two reads.
  let sleeper: Wait.Sleeper

  /// Moves the display to the tempo, waits until Logic reads that tempo, and answers what it
  /// reads.
  ///
  /// The move and the read back are two different questions. The display answering 96 says the
  /// slider took the steps. The state answering 96 says the project carries the tempo, which is
  /// what an agent then plays against, and it is the only number that goes in the answer. A move
  /// that stopped short throws before the wait, with the number asked for and the number read.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    _ = try field.set(to: tempo, limitMs: limitMs, clock: clock, sleeper: sleeper)
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      try driver.readState().transport.tempo == Double(tempo)
    }
    let carried = try driver.readState().transport.tempo
    return .object(["tempo": .number(carried)])
  }
}
