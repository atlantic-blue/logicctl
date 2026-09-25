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

/// A Logic showing the Mixer of a project of one track, which answers what a press does to it.
///
/// It holds the plugins of the strip and whether the menu is open, and it answers a tree of both.
/// The command reads that tree again after every press, so what the fake does is what the answer
/// of the command is read from.
private final class FakeMixer {
  /// The name Logic writes on the track and on its channel strip.
  let track: String

  /// The plugins the strip holds, in slot order.
  private(set) var plugins: [String]

  /// Whether the strip shows an empty audio slot.
  let showsAnEmptySlot: Bool

  /// True while the menu is open, which is what a press of the empty slot does.
  private(set) var open = false

  /// What was pressed, as Logic describes each element, in the order it was pressed.
  private(set) var pressed: [String] = []

  /// The titles of each walk that was chosen, in the order they were chosen.
  private(set) var chosen: [[String]] = []

  /// How many times the menu was closed with nothing chosen.
  private(set) var cancelled = 0

  /// The menu Logic opens, which is the recorded one.
  private let menu: any AXNode

  init(track: String, plugins: [String] = [], showsAnEmptySlot: Bool = true) throws {
    self.track = track
    self.plugins = plugins
    self.showsAnEmptySlot = showsAnEmptySlot
    self.menu = try recordedMenu()
  }

  /// What Logic does when the empty slot is pressed: it opens the menu beside the strips.
  func press(_ node: any AXNode) {
    pressed.append(node.description ?? node.title ?? "")
    guard node.description == PluginMenu.emptySlotDescription else {
      return
    }
    open = true
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
      plugins.append(chosenPlugin)
    }
    open = false
  }

  /// What Logic does when the menu is closed with nothing chosen.
  func cancel() {
    cancelled += 1
    open = false
  }

  /// The tree of a Logic showing this Mixer.
  func tree() -> LogicTree {
    LogicTree(logicVersion: recordedVersion, root: window())
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
    for name in plugins.reversed() {
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
private func pluginsInsert(_ plugin: String, into fake: FakeMixer, track: String = "1") throws
  -> Answer
{
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
