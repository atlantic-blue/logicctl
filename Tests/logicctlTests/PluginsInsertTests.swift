import ApplicationServices
import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// The version of Logic every recorded tree came from.
private let recordedVersion = "12.3.1"

/// Where the recorded trees sit. They are read from the source tree, because the folder sits beside
/// the test targets rather than inside one.
private let recordedTrees = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// What one run of the command wrote, on each channel, and the number it exited with.
private struct Answer {
  let out: String
  let err: String
  let status: Int32

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// What the answer carries under `data`.
  func data() throws -> [String: Any] {
    try printed()["data"] as? [String: Any] ?? [:]
  }

  /// The rows the answer carries under `data.plugins`.
  func rows() throws -> [[String: Any]] {
    try data()["plugins"] as? [[String: Any]] ?? []
  }

  /// The failure the answer carries, or an empty object when it carries none.
  func failure() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }
}

/// One element of the tree the fake Mixer answers.
///
/// Nothing of the menu is built here. This is the window, the strip and its slots, which is the
/// part of the Mixer that changes as a plugin goes in.
private struct Element: AXNode {
  var role: String
  var title: String?
  var identifier: String?
  var value: String?
  var valueDescription: String?
  var description: String?
  var help: String?
  var actions: [String] = []
  var children: [any AXNode] = []
}

/// The menu Logic opened when the empty slot of a strip was pressed, as `inspect` recorded it.
///
/// It is the real menu of Logic 12.3.1, with its 334 items, and not a menu this test wrote. A name
/// that is refused here is refused against what Logic offers.
private func recordedMenu() throws -> any AXNode {
  let read = try RecordedTree(contentsOf: recordedTrees.appending(path: "plugin-menu.json"))
  guard let area = firstElement(role: "AXLayoutArea", under: read.root),
    let menu = area.children.first(where: { $0.role == "AXMenu" })
  else {
    throw MenuMissing()
  }
  return menu
}

/// The recorded tree carries no open menu, so nothing in this file can be proved against it.
private struct MenuMissing: Error {}

/// The first element of a role under one element, a level at a time.
private func firstElement(role: String, under node: any AXNode) -> (any AXNode)? {
  var level: [any AXNode] = node.children
  while !level.isEmpty {
    if let found = level.first(where: { $0.role == role }) {
      return found
    }
    level = level.flatMap { $0.children }
  }
  return nil
}

/// Every title of a menu item under one element, at every level.
///
/// The walk is this file's own, so what a test says about the recorded menu does not come from the
/// walk the command uses.
private func titles(under node: any AXNode) -> [String] {
  var found: [String] = []
  for child in node.children {
    if child.role == "AXMenuItem", let title = child.title {
      found.append(title)
    }
    found += titles(under: child)
  }
  return found
}

/// A clock and a sleep the test moves itself, so a wait of any length costs the suite no time.
private final class Time {
  /// The milliseconds the clock stands at.
  private(set) var now = 0

  /// Every sleep the wait took, in the order it took them.
  private(set) var slept: [Int] = []

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    slept.append(span)
    now += span
  }
}

/// A Logic showing the Mixer of a project of one track, which answers what a press does to it.
///
/// It holds the plugins of the strip and whether the menu is open, and it answers a tree of both.
/// The command reads that tree again after every press, so what the fake does is what the answer
/// of the command is read from.
///
/// Logic draws a plugin in the strip some time after it puts it in, so the strip and the project
/// disagree for a while. A scenario says on which read after the choice the strip draws the new
/// plugin, and `plugins` is what the project holds whether the strip draws it or not.
private final class FakeMixer {
  /// The name Logic writes on the track and on its channel strip.
  let track: String

  /// The plugins the strip holds, in slot order.
  private(set) var plugins: [String]

  /// Whether the strip shows an empty audio slot.
  let showsAnEmptySlot: Bool

  /// How many reads of the Mixer answer with no menu after the slot is pressed.
  ///
  /// Logic holds the press while it puts the menu up, so the Mixer read straight after the press
  /// is a Mixer with no menu in it on a Logic that is opening one. Measured on this Mac on
  /// 2026-09-27: the press answered after 1.51 seconds and the menu was open half a second later.
  let menuAppearsAfterReads: Int

  /// True while the menu is open, which is what a press of the empty slot does.
  private(set) var open = false

  /// What was pressed, as Logic describes each element, in the order it was pressed.
  private(set) var pressed: [String] = []

  /// The titles of each walk that was chosen, in the order they were chosen.
  private(set) var chosen: [[String]] = []

  /// How many times the menu was closed with nothing chosen.
  private(set) var cancelled = 0

  /// How many times the tree was read since the plugin was chosen.
  private(set) var readsAfterTheChoice = 0

  /// Which of those reads is the first one that draws the new plugin. A strip that draws it at
  /// once answers 1, and a strip that never draws it answers a number no wait reaches.
  private let drawsThePluginOnRead: Int

  /// The plugins the strip drew before the choice, which is what it keeps drawing until the read
  /// above.
  private var drewBeforeTheChoice: [String] = []

  /// Whether a plugin was chosen, which is what starts the count of the reads.
  private var choseAPlugin = false

  /// The menu Logic opens, which is the recorded one.
  private let menu: any AXNode

  /// True once the empty slot was pressed, whether or not the menu is up yet.
  private var slotWasPressed = false

  /// Reads of the Mixer since the slot was pressed and before the menu came up.
  private var readsWithNoMenu = 0

  init(
    track: String,
    plugins: [String] = [],
    showsAnEmptySlot: Bool = true,
    menuAppearsAfterReads: Int = 0,
    drawsThePluginOnRead: Int = 1
  ) throws {
    self.track = track
    self.plugins = plugins
    self.showsAnEmptySlot = showsAnEmptySlot
    self.menuAppearsAfterReads = menuAppearsAfterReads
    self.drawsThePluginOnRead = drawsThePluginOnRead
    self.menu = try recordedMenu()
  }

  /// What Logic does when the empty slot is pressed: it opens the menu beside the strips.
  func press(_ node: any AXNode) {
    pressed.append(node.description ?? node.title ?? "")
    guard node.description == PluginMenu.emptySlotDescription else {
      return
    }
    slotWasPressed = true
    open = menuAppearsAfterReads == 0
  }

  /// What Logic does when the item at the end of a walk is pressed: it puts that plugin into the
  /// first empty slot and closes the menu.
  ///
  /// The plugin is the item above the one that was pressed, because the last item under a plugin
  /// is a channel configuration and every plugin carries the same two, `Stereo` and `Dual Mono`. A
  /// walk of one item is a plugin that carries no such menu, and that item is the plugin.
  func choose(_ walk: [any AXNode]) {
    chosen.append(walk.map { $0.title ?? "" })
    guard open else {
      return
    }
    let chosenPlugin = walk.count > 1 ? walk[walk.count - 2].title : walk.last?.title
    if let chosenPlugin {
      drewBeforeTheChoice = plugins
      plugins.append(chosenPlugin)
      choseAPlugin = true
    }
    open = false
  }

  /// What Logic does when the menu is closed with nothing chosen.
  func cancel() {
    cancelled += 1
    open = false
  }

  /// The tree of a Logic showing this Mixer.
  ///
  /// A Logic that is still opening its menu answers a Mixer with no menu in it, and it answers one
  /// with the menu once `menuAppearsAfterReads` reads have gone by. Every read is counted once the
  /// plugin is in, because what the strip draws is what the read that reaches it answers.
  func tree() -> LogicTree {
    if slotWasPressed, !open {
      if readsWithNoMenu >= menuAppearsAfterReads {
        open = true
      } else {
        readsWithNoMenu += 1
      }
    }
    if choseAPlugin {
      readsAfterTheChoice += 1
    }
    return LogicTree(logicVersion: recordedVersion, root: window())
  }

  /// How many times the Mixer answered with no menu after the slot was pressed.
  var readsBeforeTheMenu: Int {
    readsWithNoMenu
  }

  /// The plugins this read of the strip draws.
  private var drawn: [String] {
    guard choseAPlugin, readsAfterTheChoice < drawsThePluginOnRead else {
      return plugins
    }
    return drewBeforeTheChoice
  }

  /// The Mixer window, in the shape the recorded Mixer carries: the strips sit in a layout area,
  /// and the menu Logic opened sits beside them.
  private func window() -> any AXNode {
    let area = Element(
      role: "AXLayoutArea",
      description: "Mixer",
      children: open ? [strip(), menu] : [strip()])
    return Element(
      role: "AXWindow",
      title: "Fake.logicx - Mixer: Tracks",
      children: [Element(role: "AXGroup", description: "Mixer", children: [area])])
  }

  /// The channel strip of the track.
  ///
  /// Logic answers the children of a strip from the bottom of the strip upwards, so the plugins go
  /// in the other order to the one they are read back in, and the empty slot sits under them.
  private func strip() -> any AXNode {
    var children: [any AXNode] = [
      Element(role: "AXTextField", value: track, description: "name")
    ]
    if showsAnEmptySlot {
      children.append(Element(role: "AXButton", description: PluginMenu.emptySlotDescription))
    }
    children.append(Element(role: "AXButton", description: "insert bar"))
    for name in drawn.reversed() {
      children.append(FakeMixer.slot(name))
    }
    children.append(Element(role: "AXButton", description: "MIDI plug-in"))
    return Element(role: "AXLayoutItem", description: track, children: children)
  }

  /// One slot with a plugin in it, in the shape the recorded strip carries: the name is the
  /// description of the group, and the check box described `bypass` is what says it is a plugin.
  private static func slot(_ name: String) -> any AXNode {
    Element(
      role: "AXGroup",
      description: name,
      children: [
        Element(role: "AXCheckBox", description: "bypass"),
        Element(role: "AXButton", description: "open"),
        Element(role: "AXButton", description: "list"),
      ])
  }
}

/// The project the strip belongs to: one track, named as Logic names both the track and its strip.
private func aProjectOfOneTrack(named track: String) -> [Track] {
  [Track(index: 1, name: track, type: .other)]
}

/// Runs `logicctl plugins insert --track <n> --name <text>` against a Logic showing this Mixer.
///
/// The arguments go in as text and nothing is built by hand, so the flags of the command are part
/// of what each scenario proves. The project sits nowhere, which is a project that was never
/// saved, so there is no session to write a step into and nothing of this run touches the disk.
///
/// The clock and the sleep of every wait are the ones the test moves, so a wait of five seconds
/// costs the suite nothing and a scenario reads how long the command gave Logic.
private func pluginsInsert(
  _ plugin: String, into fake: FakeMixer, track: String = "1", on time: Time = Time()
) throws -> Answer {
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(["plugins", "insert", "--track", track, "--name", plugin])
  let insert = try #require(typed as? Plugins.Insert)
  let status = insert.answer(
    driver: FakeLogicDriver(tracks: aProjectOfOneTrack(named: fake.track)),
    of: { fake.tree() },
    menu: PluginMenu(
      press: { fake.press($0) },
      choose: { fake.choose($0) },
      cancel: { _ in fake.cancel() }),
    confirmed: false,
    root: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
    clock: time.read,
    sleeper: time.sleep,
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A name Logic does not offer leaves the track exactly as it was.
///
/// An agent asks for a plugin by the name a person would type. The menu Logic opens on an empty
/// slot carries 334 items across fourteen categories, and the name is matched against all of them.
/// The value of this is what happens when the match fails.
///
/// A walk that took the nearest item, or the first item of the open menu, would put a plugin into
/// the strip that nobody asked for. The slot then reads as filled, the printed list reads as
/// correct, and every later command of the session runs against a channel strip carrying a plugin
/// the operator never chose. Nothing downstream can tell that apart from an insert that worked:
/// the answer of a good insert and the answer of that one have the same shape.
///
/// So the name is looked up before anything is chosen, the menu is closed again, and the command
/// stops with `plugin_not_found` and exit 12. The strip keeps the plugin it had.
///
/// The first line is what holds the proof honest. An empty menu would refuse this name too, and
/// the scenario would then pass against a Logic offering nothing at all, so the recorded menu is
/// read first and it must carry `Channel EQ` to be the menu this scenario refuses a name against.
@Test func anUnknownPluginStopsWithPluginNotFound() throws {
  let offered = titles(under: try recordedMenu())
  try #require(offered.contains("Channel EQ"), "the recorded menu is the menu Logic opens")
  try #require(!offered.contains("No Such EQ"), "and it offers no plugin of the name asked for")

  let fake = try FakeMixer(track: "Deluxe Classic", plugins: ["E-Piano"])
  let answer = try pluginsInsert("No Such EQ", into: fake)

  #expect(answer.status == 12, "the exit number of plugin_not_found")
  let failure = try answer.failure()
  #expect(failure["code"] as? String == "plugin_not_found", "the code a caller reads")
  #expect(
    failure["message"] as? String == "Logic offers no plugin named No Such EQ",
    "the sentence names what was asked for")
  #expect(failure["details"] is NSNull, "a name that is not there has nothing to add")
  #expect(try answer.printed()["data"] is NSNull, "a failure carries no data")

  #expect(fake.plugins == ["E-Piano"], "the strip holds the plugin it held before the command ran")
  #expect(fake.chosen.isEmpty, "nothing in the menu was pressed")
  #expect(fake.cancelled == 1, "and the menu Logic opened was closed again")

  let lines = answer.err.split(whereSeparator: \.isNewline)
  #expect(lines.count == 1, "standard error carries one line for the person reading along")
  #expect(
    answer.err.hasPrefix("logicctl: plugin_not_found: "),
    "the one line reads logicctl: <code>: <message>")
}

/// The plugin a person named goes into the first empty slot, and the answer is the new chain.
///
/// The strip starts with nothing on it, so the plugin that goes in is slot 1. The walk down to the
/// last level is part of the proof: Logic puts a plugin in when a channel configuration under it
/// is pressed, and pressing the name alone opens that menu and inserts nothing.
@Test func channelEqLandsInTheFirstEmptySlot() throws {
  let fake = try FakeMixer(track: "Deluxe Classic")
  let answer = try pluginsInsert("Channel EQ", into: fake)

  #expect(answer.status == 0, "the command exits 0")
  #expect(answer.err == "", "standard error stays empty when a command worked")

  let rows = try answer.rows()
  try #require(rows.count == 1, "the strip held nothing, so it holds one plugin now")
  #expect(rows[0]["slot"] as? Int == 1, "the first empty slot is slot 1 of an empty strip")
  #expect(rows[0]["name"] as? String == "Channel EQ", "the plugin that was asked for")
  #expect(rows[0]["stateHash"] is NSNull, "no project was saved, so no settings were hashed")
  #expect(try answer.data()["track"] == nil, "the answer of an insert carries the plugins alone")

  #expect(fake.pressed == ["audio plug-in"], "the empty audio slot is what was pressed")
  #expect(
    fake.chosen == [["EQ", "Channel EQ", "Stereo"]],
    "the walk went to the category, to the plugin, and on to its last level")
  #expect(fake.cancelled == 0, "the menu was used rather than closed")
}

/// A name the menu carries twice stops the command, and the message says where each one sits.
///
/// Logic writes `Delay` on a category of the menu and on a stompbox under Amps and Pedals. A walk
/// that took the first of them would insert whichever one comes first in the tree, which is not a
/// choice anybody made. The person reads where the two sit and types the one they meant.
@Test func twoItemsOfOneNameStopTheCommand() throws {
  let fake = try FakeMixer(track: "Deluxe Classic")
  let answer = try pluginsInsert("Delay", into: fake)

  #expect(answer.status == 12, "the exit number of plugin_not_found")
  let failure = try answer.failure()
  #expect(failure["code"] as? String == "plugin_not_found", "the code a caller reads")
  let message = failure["message"] as? String ?? ""
  #expect(message.contains("2 plugins named Delay"), "the sentence says how many there are")
  #expect(
    message.contains("Amps and Pedals > Stompboxes > Delay"),
    "and where the first of them sits")
  #expect(message.hasSuffix("and at Delay"), "and where the other one sits")
  #expect(failure["details"] is NSNull, "the sentence carries the whole of it")

  #expect(fake.plugins.isEmpty, "no plugin went into the strip")
  #expect(fake.chosen.isEmpty, "nothing in the menu was pressed")
  #expect(fake.cancelled == 1, "and the menu Logic opened was closed again")
}

/// A strip with no empty slot is refused, rather than pressing something else in the strip.
///
/// Every control of a channel strip opens something when it is pressed. A walk that pressed the
/// nearest button because it found no empty slot would open a menu belonging to the sends, the
/// output or the group, and then walk that one looking for the plugin.
@Test func aStripWithNoEmptySlotIsRefused() throws {
  let fake = try FakeMixer(track: "Deluxe Classic", plugins: ["E-Piano"], showsAnEmptySlot: false)
  let answer = try pluginsInsert("Channel EQ", into: fake)

  #expect(answer.status == 5, "the exit number of element_not_found")
  #expect(try answer.failure()["code"] as? String == "element_not_found", "the code a caller reads")
  #expect(fake.pressed.isEmpty, "nothing in the strip was pressed")
  #expect(fake.plugins == ["E-Piano"], "and the strip holds what it held")
}

/// A menu that takes a moment to come up is waited for, and the plugin still goes in.
///
/// Logic holds the press of the empty slot while it opens the menu. Measured on this Mac on
/// 2026-09-27, on a copy under `/tmp`: the press answered `kAXErrorCannotComplete` after 1.51
/// seconds, and the menu was open half a second after that, carrying `Amps and Pedals`, `Delay`
/// and `Distortion` at its top level. So a command that read the Mixer once, straight after the
/// press, read a Mixer with no menu in it and told the operator that Logic opened none. It was
/// opening one. `plugins insert` was the one scenario of phase 4 that failed on this Mac for that
/// reason, on a strip that had a slot free and a menu that carried the name.
///
/// The fake answers two Mixers with no menu before it answers one with the menu, and the command
/// reads until it finds it. The count is read back, because a command that somehow saw the menu on
/// its first read would pass this scenario without ever waiting for anything.
@Test func aMenuThatOpensLateIsWaitedFor() throws {
  let fake = try FakeMixer(track: "Deluxe Classic", menuAppearsAfterReads: 2)
  let time = Time()

  let answer = try pluginsInsert("Channel EQ", into: fake, on: time)

  #expect(answer.status == 0, "the insert worked, on a Logic that took its time")
  #expect(fake.readsBeforeTheMenu == 2, "and it read the Mixer twice before the menu was there")
  #expect(
    time.slept == [50, 50],
    "it waited between those reads rather than asking Logic again at once")
  #expect(fake.plugins == ["Channel EQ"], "the plugin is in the strip")
  #expect(
    fake.chosen == [["EQ", "Channel EQ", "Stereo"]],
    "and the walk went the same way it goes when the menu is up at once")
  #expect(fake.cancelled == 0, "nothing was closed")
}

/// A press that opens no menu at all is still refused, and the refusal names the track.
///
/// The wait above cannot become a wait that never gives up: a slot press that lands on a Logic
/// that opens nothing has to answer, or the command hangs on a person's terminal. So the wait ends
/// at its limit and the command says what it pressed and what did not happen.
@Test func aPressThatOpensNoMenuIsRefused() throws {
  let fake = try FakeMixer(track: "Deluxe Classic", menuAppearsAfterReads: .max)
  let time = Time()

  let answer = try pluginsInsert("Channel EQ", into: fake, on: time)

  #expect(answer.status == 5, "the exit number of element_not_found")
  #expect(
    time.now == 5000,
    "the wait ran on the clock of this test, for the limit of a wait that names none")
  let failure = try answer.failure()
  #expect(failure["code"] as? String == "element_not_found", "the code a caller reads")
  let message = failure["message"] as? String ?? ""
  #expect(message.contains("track 1"), "the sentence names the track whose slot was pressed")
  #expect(message.contains("opened no menu"), "and says what did not happen")

  #expect(fake.pressed == [PluginMenu.emptySlotDescription], "the empty slot was pressed once")
  #expect(fake.plugins.isEmpty, "no plugin went into the strip")
  #expect(fake.chosen.isEmpty, "and nothing in a menu was pressed, because there was no menu")
}

/// A press that opens no menu costs the suite no time, because one clock drives both waits.
///
/// The command holds a clock and a sleeper, and it waits twice: once for the menu Logic opens on
/// the slot, and once for the plugin to be drawn in that slot. A menu wait that read the wall clock
/// instead would put five real seconds into every run of this suite, and it would say nothing about
/// what the command gave Logic.
@Test func bothWaitsOfTheInsertReadTheClockTheCommandWasGiven() throws {
  let slow = try FakeMixer(
    track: "Deluxe Classic", menuAppearsAfterReads: 1, drawsThePluginOnRead: 2)
  let time = Time()

  let answer = try pluginsInsert("Channel EQ", into: slow, on: time)

  #expect(answer.status == 0, "the insert worked")
  #expect(slow.readsBeforeTheMenu == 1, "one read of the Mixer answered with no menu")
  #expect(slow.readsAfterTheChoice == 2, "and one read of the strip answered without the plugin")
  #expect(time.slept == [50, 50], "so the command slept once for each, on the clock it was given")
}

/// The one answer to the slot press that says nothing about whether the press landed.
///
/// `AXPress` on the empty audio slot of the strip answers `kAXErrorCannotComplete` while Logic
/// holds the call to put its menu up, so reading that answer as a refusal stops a press that
/// worked. Every other answer is a refusal, and the menu is what decides this one.
@Test func onlyCannotCompleteFromTheSlotPressIsHeldOpen() throws {
  #expect(
    PluginMenu.holdsWhileTheMenuOpens(.cannotComplete),
    "Logic holds this one while the menu is opening, so the menu answers instead")
  #expect(
    PluginMenu.holdsWhileTheMenuOpens(.failure) == false, "a failure is a failure")
  #expect(
    PluginMenu.holdsWhileTheMenuOpens(.invalidUIElement) == false,
    "an element that is not there is not a menu that is coming")
  #expect(
    PluginMenu.holdsWhileTheMenuOpens(.actionUnsupported) == false,
    "and an element that cannot be pressed never opens anything")
}

/// A person inserts a plugin, and reads the chain the project holds rather than the chain Logic
/// happened to be drawing.
///
/// Measured on Logic 12.3.1 on 2026-09-27, in the live run of phase 4, on a copy of F-T13 after
/// `midi import`. Track 6 held Piano, Channel EQ, Compressor and ChromaVerb in slots 1 to 4.
/// `plugins insert --track 6 --name "Channel EQ"` answered exit 0 with those same four plugins and
/// no slot 5. A `plugins list --track 6` after it read Channel EQ in slot 5. So the insert landed,
/// and the command read the Mixer once, before Logic drew the new slot, and answered that read.
///
/// The value is what an agent does with the answer. A chain of four that reads back as a chain of
/// four says the insert did nothing, so the agent inserts again and the strip then carries the
/// plugin twice. An insert that truly failed answers the same four rows, so nothing downstream can
/// tell a command that worked from a command that did not. The answer of a good insert and the
/// answer of a broken one were the same object.
///
/// So the command reads the strip until the slot it filled draws the plugin it asked for. The two
/// parts are the two ways that ends. A Mixer that draws the plugin on the third read answers the
/// chain of five, and the first read does not become the answer. A Mixer that never draws it costs
/// the command its wait and no more, and the command says `timeout` and names the slot it watched,
/// rather than printing a chain that is missing the plugin.
@Test func pluginsInsertWaitsUntilTheSlotShowsThePlugin() throws {
  let late = try FakeMixer(
    track: "Deluxe Classic",
    plugins: ["Piano", "Channel EQ", "Compressor", "ChromaVerb"],
    drawsThePluginOnRead: 3)
  let time = Time()

  let answer = try pluginsInsert("Channel EQ", into: late, on: time)

  #expect(answer.status == 0, "the command exits 0")
  #expect(answer.err == "", "standard error stays empty when a command worked")
  let rows = try answer.rows()
  try #require(rows.count == 5, "the strip held four plugins, so it holds five now")
  #expect(
    rows.map { $0["name"] as? String }
      == ["Piano", "Channel EQ", "Compressor", "ChromaVerb", "Channel EQ"],
    "the answer carries the chain the project holds, with the new plugin under the four")
  #expect(rows[4]["slot"] as? Int == 5, "the plugin went into the slot that was empty")
  #expect(
    late.readsAfterTheChoice == 3,
    "the strip was read until it drew the plugin, so the answer is not the first read")
  #expect(
    time.slept == [50, 50],
    "and the command waited between those reads rather than asking Logic again at once")
  #expect(late.plugins.count == 5, "the project holds five plugins, which is what was answered")

  // A Logic that puts the plugin in and never draws it. The command gives it the limit of a wait
  // and then says how long it gave it, on a clock this test moves itself.
  let silent = try FakeMixer(
    track: "Deluxe Classic", plugins: ["Piano"], drawsThePluginOnRead: Int.max)
  let waited = Time()

  let refused = try pluginsInsert("Channel EQ", into: silent, on: waited)

  #expect(refused.status == 6, "the number the design system gives timeout")
  let failure = try refused.failure()
  #expect(failure["code"] as? String == "timeout", "the code a caller reads")
  let message = failure["message"] as? String ?? ""
  #expect(message.contains("slot 2"), "the sentence names the slot the command watched")
  #expect(message.contains("Channel EQ"), "and the plugin it was asked for")
  let gave = failure["details"] as? [String: Any] ?? [:]
  #expect(gave["track"] as? Int == 1, "the details carry the track the person named")
  #expect(gave["slot"] as? Int == 2, "and the slot the plugin was put into")
  #expect(gave["name"] as? String == "Channel EQ", "and the name it waited for")
  #expect(
    gave["waitedMs"] as? Int == 5000,
    "with the time it gave Logic, which is the limit of a wait that names none")
  #expect(try refused.printed()["data"] is NSNull, "a failure carries no data")
  #expect(waited.now == 5000, "the wait ran on the clock of this test and cost the suite no time")
  #expect(
    silent.plugins == ["Piano", "Channel EQ"],
    "the plugin did go in, and a strip that never draws it is not a chain of one")
  let lines = refused.err.split(whereSeparator: \.isNewline)
  #expect(lines.count == 1, "standard error carries one line for the person reading along")
  #expect(
    refused.err.hasPrefix("logicctl: timeout: "),
    "the one line reads logicctl: <code>: <message>")
}
