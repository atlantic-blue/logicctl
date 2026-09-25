import ApplicationServices
import Foundation
import LogicctlCore

/// Puts one plugin into the channel strip of a track, through the menu Logic opens on an empty
/// slot.
///
/// Logic offers no other way in: the menu of names is there only while an empty slot is held
/// open, and it closes as soon as anything else happens. So the press, the walk and the choice
/// are one action, and all of it runs against the Mixer window of one Logic.
///
/// Each thing Logic is asked to do is a closure the caller gives, as it is for `TrackActions`,
/// `PianoRoll` and `SelectionGuard`. The pipeline has no Logic, so a test drives the same walk
/// against the menu `inspect` recorded and nothing on the Mac opens.
///
/// The locators are here rather than in `Locators.swift`, the way `TrackActions` holds the item
/// of the Track menu that deletes a track: the strip is the one element this walk names by a
/// path, and everything under the open menu is named by its title.
public struct PluginMenu {
  /// The description of the empty audio slot of a channel strip.
  ///
  /// The strip carries a second empty slot described `MIDI plug-in`, which takes the MIDI plugins
  /// of the track and none of the audio ones. This walk fills an audio slot and leaves that one
  /// alone.
  public static let emptySlotDescription = "audio plug-in"

  /// Presses the empty slot of the strip, which is what opens the menu.
  public typealias Press = (any AXNode) throws -> Void

  /// Presses the item the walk ends at.
  ///
  /// It takes every item the walk went through, from the item of the top level down to the one it
  /// presses, because the last item under a plugin is a channel configuration named `Stereo` and
  /// nothing in that item says which plugin it belongs to. The Logic of this Mac presses the last
  /// of them and reads none of the others.
  public typealias Choose = ([any AXNode]) throws -> Void

  /// Closes the open menu and chooses nothing.
  public typealias Cancel = (any AXNode) throws -> Void

  public let press: Press
  public let choose: Choose
  public let cancel: Cancel

  public init(press: @escaping Press, choose: @escaping Choose, cancel: @escaping Cancel) {
    self.press = press
    self.choose = choose
    self.cancel = cancel
  }

  /// The channel strip holds no empty audio slot, so there is nothing to press.
  ///
  /// Logic keeps one empty slot under the plugins of a strip. A strip that shows none is a strip
  /// this walk does not know, and a press of anything else in it would open a menu that belongs
  /// to another control.
  public struct NoEmptySlot: FailureCarrying, Equatable, Sendable {
    /// The track whose strip was read.
    public let track: Int

    public init(track: Int) {
      self.track = track
    }

    public var failure: Failure {
      Failure(
        code: .elementNotFound,
        message: "The channel strip of track \(track) shows no empty slot for an audio plugin",
        details: .object(["track": .number(Double(track))]))
    }
  }

  /// The empty slot was pressed and no menu came up, so there is nothing to walk.
  public struct NoMenu: FailureCarrying, Equatable, Sendable {
    /// The track whose slot was pressed.
    public let track: Int

    public init(track: Int) {
      self.track = track
    }

    public var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "The empty slot of track \(track) was pressed and Logic opened no menu, "
          + "so no plugin went in",
        details: .object(["track": .number(Double(track))]))
    }
  }

  /// The menu Logic opened carries no item of that name.
  ///
  /// Nothing is chosen, and the menu is closed again, so the strip holds the plugins it held
  /// before the command ran.
  public struct NotOffered: FailureCarrying, Equatable, Sendable {
    /// The name a person asked for.
    public let name: String

    public init(name: String) {
      self.name = name
    }

    public var failure: Failure {
      Failure(code: .pluginNotFound, message: "Logic offers no plugin named \(name)")
    }
  }

  /// The menu carries that name more than once.
  ///
  /// A walk that took the first of them would insert a plugin nobody chose, and the answer would
  /// read as though the command worked. So the command stops and the message says where each one
  /// sits, for a person to type the one they meant.
  public struct MoreThanOne: FailureCarrying, Equatable, Sendable {
    /// The name a person asked for.
    public let name: String

    /// Where each item of that name sits, as the titles of the walk down to it.
    public let places: [String]

    public init(name: String, places: [String]) {
      self.name = name
      self.places = places
    }

    public var failure: Failure {
      Failure(
        code: .pluginNotFound,
        message:
          "Logic offers \(places.count) plugins named \(name), at "
          + places.joined(separator: " and at "))
    }
  }
}

extension PluginMenu {
  /// Puts the plugin of this name into the first empty slot of the strip of one track.
  ///
  /// The Mixer window is read again after the press rather than held, because the menu is not in
  /// the window until the slot is pressed, and an element read before a change belongs to the
  /// tree it was read from.
  public func insert(
    _ name: String,
    intoTheStripOfTrackNumber number: Int,
    inMixerFrom mixer: () throws -> any AXNode
  ) throws {
    let strip = try LocatorResolver.element(
      of: Locators.mixerStrip(number: number - 1), in: try mixer())
    guard let slot = PluginMenu.firstEmptySlot(of: strip) else {
      throw NoEmptySlot(track: number)
    }
    try press(slot)
    guard let menu = PluginMenu.openMenu(in: try mixer()) else {
      throw NoMenu(track: number)
    }
    let found = PluginMenu.items(named: name, in: menu)
    guard found.count == 1, let walk = found.first else {
      try cancel(menu)
      if found.isEmpty {
        throw NotOffered(name: name)
      }
      throw MoreThanOne(name: name, places: found.map { PluginMenu.place(of: $0) })
    }
    try choose(PluginMenu.downToTheLastLevel(of: walk))
  }

  /// The first empty audio slot of a strip, in slot order, or nothing when it shows none.
  ///
  /// Logic answers the children of a strip from the bottom of the strip upwards, and slot order
  /// runs the other way, so the reader takes the children in reverse, as `ChannelStrip` does.
  public static func firstEmptySlot(of strip: any AXNode) -> (any AXNode)? {
    Array(strip.children.reversed()).first {
      $0.role == "AXButton" && $0.description == emptySlotDescription
    }
  }

  /// The menu Logic opened, or nothing when the window shows none.
  ///
  /// Every level of the menu is an `AXMenu`, so the one that is open is the one that hangs from
  /// something other than a menu item. Logic puts it beside the channel strips, under the layout
  /// area of the Mixer.
  public static func openMenu(in window: any AXNode) -> (any AXNode)? {
    var level: [(parent: String, node: any AXNode)] = [("", window)]
    while !level.isEmpty {
      if let open = level.first(where: { $0.node.role == "AXMenu" && $0.parent != "AXMenuItem" }) {
        return open.node
      }
      level = level.flatMap { holder -> [(parent: String, node: any AXNode)] in
        holder.node.children.map { (parent: holder.node.role, node: $0) }
      }
    }
    return nil
  }

  /// Every item of this title the menu carries, each one as the walk of items down to it.
  ///
  /// The whole menu is read and not the first match alone, because a name that reaches two items
  /// is a name that says nothing about which plugin a person meant.
  public static func items(named name: String, in menu: any AXNode) -> [[any AXNode]] {
    var found: [[any AXNode]] = []
    for item in menu.children where item.role == "AXMenuItem" {
      found += itemsUnder(item, named: name, reached: [])
    }
    return found
  }

  /// The walk carried on down to the last level under the item it ends at.
  ///
  /// A plugin of Logic carries a menu of channel configurations, `Stereo` beside `Dual Mono`, and
  /// it goes in as the first of them. An item that carries no menu under it is the end of the
  /// walk and takes the press itself.
  public static func downToTheLastLevel(of walk: [any AXNode]) -> [any AXNode] {
    guard let last = walk.last,
      let menu = last.children.first(where: { $0.role == "AXMenu" }),
      let first = menu.children.first(where: { $0.role == "AXMenuItem" })
    else {
      return walk
    }
    return downToTheLastLevel(of: walk + [first])
  }

  /// Where one item sits, as the titles of the walk down to it.
  static func place(of walk: [any AXNode]) -> String {
    walk.map { $0.title ?? "" }.joined(separator: " > ")
  }

  /// Every item of this title under one item, each one as the walk of items down to it.
  private static func itemsUnder(
    _ item: any AXNode, named name: String, reached: [any AXNode]
  ) -> [[any AXNode]] {
    let walk = reached + [item]
    var found: [[any AXNode]] = []
    if item.title == name {
      found.append(walk)
    }
    for menu in item.children where menu.role == "AXMenu" {
      for under in menu.children where under.role == "AXMenuItem" {
        found += itemsUnder(under, named: name, reached: walk)
      }
    }
    return found
  }
}

extension PluginMenu {
  /// The menu of the Logic that runs on this Mac.
  public static func live() -> PluginMenu {
    PluginMenu(
      press: PluginMenu.pressInTheLogicOfThisMac,
      choose: PluginMenu.chooseInTheLogicOfThisMac,
      cancel: PluginMenu.cancelInTheLogicOfThisMac)
  }

  /// Why the Mac gave no change. The reason reaches the answer of the command, so a person reads
  /// what Logic refused without going to look for a log.
  public struct Trouble: FailureCarrying, Equatable, Sendable {
    /// One short reason, in the words of the Mac that refused.
    public let reason: String

    public init(reason: String) {
      self.reason = reason
    }

    public var failure: Failure {
      Failure(code: .internalFailure, message: reason)
    }
  }

  /// Presses the empty slot, which is what opens the menu.
  public static func pressInTheLogicOfThisMac(_ slot: any AXNode) throws {
    try act(kAXPressAction, on: slot, called: "the empty slot of the channel strip")
  }

  /// Presses the item the walk ends at, which is the last of them.
  public static func chooseInTheLogicOfThisMac(_ walk: [any AXNode]) throws {
    guard let item = walk.last else {
      throw Trouble(reason: "The walk of the plugin menu ended at no item, so nothing was chosen.")
    }
    try act(kAXPressAction, on: item, called: "an item of the plugin menu")
  }

  /// Closes the open menu, which leaves the strip as it was.
  public static func cancelInTheLogicOfThisMac(_ menu: any AXNode) throws {
    try act(kAXCancelAction, on: menu, called: "the plugin menu")
  }

  /// Asks one element of the running Logic to act on itself, which is not a mouse event and so
  /// does not go through the input gate.
  private static func act(_ action: String, on node: any AXNode, called name: String) throws {
    guard let live = node as? LiveAXNode else {
      throw Trouble(reason: "\(name) was found in a recorded tree, which nothing can press.")
    }
    let answered = AXUIElementPerformAction(live.element, action as CFString)
    guard answered == .success else {
      throw Trouble(reason: "Logic refused \(action) on \(name), error \(answered.rawValue).")
    }
  }
}
