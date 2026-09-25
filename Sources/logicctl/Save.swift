import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

/// Writes the open project to a path.
///
/// A `.logicx` holds hours of work that nothing brings back, so this command refuses to write over
/// one. A person who types a path that is taken reads `path_exists` and the path in the way, and
/// nothing on disk moves. They decide, and `--confirm` is how they say it.
struct Save: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "save",
    abstract: "Write the project Logic has open to a path.",
    discussion: """
      A path that is already taken stops the command with path_exists, and nothing is written. \
      --confirm writes over what is there.

      Example: logicctl save --path ~/Music/Logic/Test.logicx
      """)

  @Option(help: "Where the project goes. It expands ~, and a relative path is from this folder.")
  var path: String

  @OptionGroup var confirm: ConfirmOption

  @OptionGroup var output: OutputOption

  @OptionGroup var wait: TimeoutOption

  func validate() throws {
    guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError("--path names where the project goes, so give a path.")
    }
  }

  func run() throws {
    let status = Save.answer(
      toPath: path,
      confirmed: confirm.confirm,
      dialog: SaveDialog.live(),
      driver: Save.liveDriver(),
      limitMs: wait.timeout.milliseconds,
      format: output.format,
      argv: ["--path", path] + (confirm.confirm ? ["--confirm"] : []))
    guard status == 0 else {
      // The envelope is written already. The number goes out through the root command, which
      // prints nothing more for it.
      throw ExitCode(status)
    }
  }
}

extension Save {
  /// Writes the project to a path, prints the envelope, and answers the number the process exits
  /// with.
  ///
  /// The panel and the driver are given rather than reached for, so the pipeline drives the same
  /// command against a Logic of its own.
  static func answer(
    toPath typed: String,
    confirmed: Bool,
    dialog: SaveDialog,
    driver: any LogicDriver,
    root: URL = SessionRepository.defaultRoot,
    version: String = Logicctl.version,
    limitMs: Int = Wait.defaultLimitMs,
    format: OutputFormat = .compact,
    argv: [String] = [],
    currentFolder: String = FileManager.default.currentDirectoryPath,
    now: @escaping () -> Date = { Date() },
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds,
    git: Git = Git(),
    lock: Lock = Lock(),
    capturer: any WindowCapturer = WindowCapture(),
    standardOutput: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardOutput,
    standardError: @escaping EnvelopePrinter.Write = EnvelopePrinter.writeToStandardError
  ) -> Int32 {
    let started = now()
    let printer = EnvelopePrinter(
      format: format, standardOutput: standardOutput, standardError: standardError)
    let path = Save.absolutePath(of: typed, from: currentFolder)

    let run = Run(
      driver: driver,
      root: root,
      version: version,
      now: now,
      git: git,
      lock: lock,
      capturer: capturer)
    let command = SaveCommand(
      argv: argv, path: path, dialog: dialog, limitMs: limitMs, clock: clock, sleeper: sleeper)
    return printer.write(run.run(change: command, confirmed: confirmed))
  }

  /// The path a person typed, as one absolute path.
  ///
  /// It expands `~`, and a relative path is relative to the folder the person is in, which is what
  /// every other tool on this Mac does with one.
  static func absolutePath(of typed: String, from currentFolder: String) -> String {
    let expanded = (typed as NSString).expandingTildeInPath
    let full =
      expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded)
      : URL(fileURLWithPath: currentFolder).appendingPathComponent(expanded)
    return full.standardizedFileURL.path
  }

  /// What this command reads the state of Logic through on this Mac.
  ///
  /// Nothing in logicctl reads the whole state of Logic yet, so there is no driver over the real
  /// Logic to give here. The part that reads the tracks brings one, and this command is written
  /// against the protocol so that it needs no change when it arrives.
  static func liveDriver() -> any LogicDriver {
    NewProject.liveDriver()
  }
}

/// The save, as the run of a command sees it.
///
/// It drives the panel and then reads Logic back, because a press that returned success proves
/// nothing about where the project is. A Logic that did not put the project at the path fails with
/// `timeout`, and the session keeps the path it had.
struct SaveCommand: LogicCommand {
  let name = "save"

  let argv: [String]

  /// Where the project goes, as one absolute path.
  let path: String

  /// The panel of Logic that asks where the project goes.
  let dialog: SaveDialog

  /// The limit of every wait this command makes, in milliseconds.
  let limitMs: Int

  /// The clock the waits read.
  let clock: Wait.Clock

  /// The sleep between two reads.
  let sleeper: Wait.Sleeper

  /// The project sits at the path once this command has worked, and the session says so in the
  /// commit of the step.
  var projectPathAfterActing: String? {
    path
  }

  func act(through driver: any LogicDriver) throws -> JSONValue? {
    try dialog.save(toPath: path, limitMs: limitMs, clock: clock, sleeper: sleeper)
    try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
      try driver.projectPath() == path
    }
    let named = try driver.readState().project.name
    return .object([
      "project": .object(["name": .string(named), "path": .string(path)])
    ])
  }
}
