import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac

extension Plugins {
  /// Puts one plugin into the first empty slot of the channel strip of one track, and prints the
  /// plugins the strip holds afterwards.
  ///
  /// The name is the name Logic writes in the menu it opens on an empty slot, for example
  /// `Channel EQ`. A name that menu does not carry stops the command with `plugin_not_found`, and
  /// so does a name it carries twice, because neither one says which plugin a person meant.
  struct Insert: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "insert",
      abstract: "Put one plugin into the first empty slot of the strip of one track.",
      discussion: """
        Logic shows the channel strips in the Mixer, so the Mixer of the project is open while \
        this runs. The plugin goes into the first empty audio slot, under the plugins the strip \
        already holds. A project logicctl did not make needs --confirm.

        Example: logicctl plugins insert --track 1 --name "Channel EQ"
        """)

    @OptionGroup var target: TrackOption

    @Option(help: "The plugin, named as Logic writes it in the menu, for example Channel EQ.")
    var name: String

    @OptionGroup var guarded: ConfirmOption

    @OptionGroup var output: OutputOption

    func run() throws {
      let status = answer(
        driver: Plugins.liveDriver(),
        of: LogicTree.ofRunningLogic,
        menu: PluginMenu.live(),
        confirmed: guarded.confirm,
        format: output.format,
        argv: ["--track", String(target.track.value), "--name", name])
      guard status == 0 else {
        // The envelope is written already. The number goes out through the root command, which
        // prints nothing more for it.
        throw ExitCode(status)
      }
    }
  }
}

extension Plugins.Insert {
  /// Inserts the plugin, prints the envelope, and answers the number the process exits with.
  ///
  /// The driver, the tree and the menu are given rather than reached for, so the pipeline drives
  /// the same command against a Logic of its own: the driver says what the project holds, the
  /// tree is the Mixer Logic is showing, and the menu is what Logic is asked to do.
  func answer(
    driver: any LogicDriver,
    of source: @escaping () throws -> LogicTree,
    menu: PluginMenu,
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
    let command = PluginsInsertCommand(
      target: target, plugin: name, menu: menu, source: source, argv: argv,
      limitMs: limitMs, clock: clock, sleeper: sleeper)
    return printer.write(run.run(change: command, confirmed: confirmed))
  }
}

/// The insert of one plugin, as the run of a command sees it.
///
/// It changes the project, so it goes through the guard: a project logicctl did not make is left
/// alone until a person says `--confirm`. The run takes the lock, records the step and answers the
/// envelope around it.
struct PluginsInsertCommand: LogicCommand {
  let name = "plugins insert"

  /// The number that names the track.
  let target: TrackOption

  /// The name of the plugin a person asked for.
  let plugin: String

  /// What puts the plugin in, in Logic.
  let menu: PluginMenu

  /// The tree of Logic, as the command reads it. It is read again after each thing Logic is asked
  /// to do, because a tree read before a change describes the Logic of a moment ago.
  let source: () throws -> LogicTree

  let argv: [String]

  /// How long the Mixer has to draw the plugin in its slot, in milliseconds.
  let limitMs: Int

  /// The clock the wait reads.
  let clock: Wait.Clock

  /// How the wait sleeps between two reads.
  let sleeper: Wait.Sleeper

  /// Logic is not showing the Mixer, so there is no channel strip to insert into.
  ///
  /// logicctl does not open the Mixer itself, so the sentence says what to do rather than naming
  /// an element nobody asked about.
  struct NoMixer: FailureCarrying, Equatable {
    /// The track the plugin was asked for.
    let track: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "Logic shows no Mixer, so no plugin can go into the strip of track \(track). "
          + "Open the Mixer.",
        details: .object(["track": .number(Double(track))]))
    }
  }

  /// The strip never drew the plugin in the slot it went into, inside the limit of the wait.
  ///
  /// Logic puts the plugin in and draws it some time afterwards, so a strip that still shows the
  /// plugins it showed before the insert says nothing about whether the insert landed. The answer
  /// names the slot it watched and the name it watched for, because both of those are what a
  /// person types into `plugins list` to read the strip for themselves.
  ///
  /// The code is `timeout` and not an element that is missing. The plugin in the slot is what the
  /// command waited for, the limit is what it gave Logic, and `waitedMs` is the milliseconds it
  /// spent, which is what RUN-6 asks of every wait.
  struct NoPluginInTheSlot: FailureCarrying, Equatable {
    /// The track whose strip was read.
    let track: Int

    /// The slot the plugin went into, which is the first slot that was empty.
    let slot: Int

    /// The name the person asked for.
    let name: String

    /// How long the command gave the Mixer to draw it.
    let waitedMs: Int

    var failure: Failure {
      Failure(
        code: .timeout,
        message:
          "The channel strip of track \(track) did not show \(name) in slot \(slot) for "
          + "\(waitedMs)ms after it was chosen in the menu, so the plugins of the strip were not "
          + "answered. Read the strip with plugins list.",
        details: .object([
          "track": .number(Double(track)),
          "slot": .number(Double(slot)),
          "name": .string(name),
          "waitedMs": .number(Double(waitedMs)),
        ]))
    }
  }

  /// Reads the strip of the track, puts the plugin in its first empty slot, and answers the
  /// plugins the strip holds afterwards.
  ///
  /// The plugins are read before the insert as well, and through the same reader the answer uses.
  /// That read does two things. It says the strip belongs to this track: the Mixer shows the output
  /// and the master strip after the strips of the tracks, and a name that disagrees stops the
  /// command before anything is pressed, rather than putting the plugin on the output of the
  /// project. And it says which slot the plugin goes into, because Logic fills the slot under the
  /// plugins the strip already holds, so the count of that read plus one is the number of that
  /// slot.
  func act(through driver: any LogicDriver) throws -> JSONValue? {
    let number = target.track.value
    guard let track = try driver.readState().tracks.first(where: { $0.index == number }) else {
      throw RegionTarget.NoTrack(index: number)
    }
    let before = try ChannelStrip.plugins(
      ofTrackNumber: number, named: track.name, in: try mixer(ofTrack: number))
    let slot = before.count + 1
    try menu.insert(plugin, intoTheStripOfTrackNumber: number) {
      try mixer(ofTrack: number)
    }
    let plugins = try thePlugins(onceSlot: slot, ofTrackNumber: number, named: track.name)
    return .object(["plugins": .array(plugins.map(\.json))])
  }

  /// The plugins of the strip, once the slot the plugin went into shows that plugin.
  ///
  /// Logic answers the insert before it draws it. Measured on Logic 12.3.1 on 2026-09-27: a strip
  /// of four plugins answered four plugins to the read that followed the insert, and held five a
  /// moment later. So the read that answers is the read that shows the plugin in the slot, and a
  /// strip that draws it at once costs the command nothing.
  ///
  /// Every read walks Logic again and finds the Mixer window again, because an element held from
  /// an earlier walk carries the answer of that walk and never a later one.
  ///
  /// A slot that never shows the plugin is a `timeout`, and the milliseconds it took go out with
  /// it. An empty slot would otherwise read as a chain that is missing the plugin, which is the
  /// answer a failed insert gives.
  private func thePlugins(
    onceSlot slot: Int, ofTrackNumber number: Int, named name: String
  ) throws -> [Plugin] {
    var plugins: [Plugin] = []
    do {
      try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
        plugins = try ChannelStrip.plugins(
          ofTrackNumber: number, named: name, in: try mixer(ofTrack: number))
        return plugins.contains { $0.slot == slot && $0.name == plugin }
      }
    } catch let ranOut as Wait.RanOut {
      throw NoPluginInTheSlot(track: number, slot: slot, name: plugin, waitedMs: ranOut.waitedMs)
    }
    return plugins
  }

  /// The Mixer window of Logic as it is now.
  private func mixer(ofTrack number: Int) throws -> any AXNode {
    guard let window = ChannelStrip.window(of: try source()) else {
      throw NoMixer(track: number)
    }
    return window
  }
}
