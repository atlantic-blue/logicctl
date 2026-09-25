import ApplicationServices
import Foundation
import LogicctlCore

/// Makes the volume automation points of one region, and reads the points Logic made.
///
/// Logic draws an automation lane as a single button with no element per point, so nothing can
/// draw a point without a mouse. The route that needs no mouse is the menu bar: the two items of
/// the Mix menu make the points at the borders of the selected region and then move them into the
/// region. Once they sit in the region, Logic shows one `Fader` row per point in the Event List,
/// and that row is where the position and the value are read.
///
/// The selection and each press are closures the caller gives, as they are for `PianoRoll` and
/// `TrackActions`. The pipeline has no Logic and no menu bar, so a test drives the same walk
/// against the trees `inspect` recorded and nothing on the Mac opens.
public struct AutomationMenus {
  /// What the Status cell of an automation row reads. A region carries note rows in the same
  /// table, so this is what tells one kind of row from the other.
  public static let faderStatus = "Fader"

  /// The parameter these points carry. Logic writes it in the last cell of the row, and volume is
  /// the only parameter logicctl makes points for.
  public static let volumeParameter = "Volume"

  /// One automation point of a region, as `automation add` prints it.
  public struct Point: Equatable, Sendable {
    /// The number of the point, from 1, in time order. This is the number `--point` takes.
    public var point: Int

    /// Where the point sits, as the Event List shows it: bar, beat, division and tick.
    public var position: String

    /// Which parameter the point moves, for example `Volume`.
    public var parameter: String

    /// The value at the point, 0 to 127 on the fader scale of Logic, where 90 is 0 dB.
    public var value: Int

    public init(point: Int, position: String, parameter: String, value: Int) {
      self.point = point
      self.position = position
      self.parameter = parameter
      self.value = value
    }

    /// The point as a JSON value, as part 5a of the data model says.
    public var json: JSONValue {
      .object([
        "point": .number(Double(point)),
        "position": .string(position),
        "parameter": .string(parameter),
        "value": .number(Double(value)),
      ])
    }
  }

  /// Why the Mac gave no selection and no press. The reason reaches the answer of the command, so
  /// a person reads what Logic refused without going to look for a log.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// One short reason, in the words of the Mac that refused.
    public let reason: String

    /// The code a caller reads and exits with.
    public let code: ErrorCode

    public init(reason: String, code: ErrorCode = .elementNotFound) {
      self.reason = reason
      self.code = code
    }

    public var failure: Failure {
      Failure(code: code, message: reason)
    }
  }

  /// Presses the one item of the menu bar a locator names.
  public typealias Press = (Locator) throws -> Void

  /// Selects one region of the Tracks window, and nothing else.
  public typealias Select = (any AXNode) throws -> Void

  public let press: Press
  public let select: Select

  /// A caller names the closures its command needs, and what it leaves out refuses.
  public init(press: Press? = nil, select: Select? = nil) {
    self.press = press ?? AutomationMenus.noPressWasGiven
    self.select = select ?? AutomationMenus.noSelectWasGiven
  }

  /// Makes the points at the borders of one region, and moves them into the region.
  ///
  /// The order is the whole of it. Logic makes track automation at the borders of whatever region
  /// is selected, so the selection comes first, and the points are track automation until the
  /// second item moves them into the region. A caller that stopped after the first press would
  /// leave the points on the track, where no Event List row shows them and no later command can
  /// name one.
  public func addPoints(atTheBordersOf region: any AXNode) throws {
    try select(region)
    try press(Locators.createAutomationPointsAtRegionBorders)
    try press(Locators.convertTrackAutomationToRegionAutomation)
  }

  /// The item of one region, in the tree Logic answers with, or nothing when the tree holds none.
  ///
  /// The walk looks for the group that holds one area per track wherever it sits, so it starts at
  /// the application and needs no window named. Logic puts one area under that group for every
  /// track and one more that names no track, which is the room under the last one, and that room
  /// is not counted. The regions of a track read in the order Accessibility answers them, which is
  /// the order they sit in from the left, which is the number `--region` takes.
  public static func regionItem(
    number region: Int, ofTrack track: Int, in root: any AXNode
  ) -> (any AXNode)? {
    guard track >= 1, region >= 1, let group = contents(of: root) else {
      return nil
    }
    let areas = group.children.filter {
      $0.role == RegionReader.trackRole && !($0.description ?? "").isEmpty
    }
    guard track <= areas.count else {
      return nil
    }
    let items = areas[track - 1].children.filter { $0.role == RegionReader.regionRole }
    guard region <= items.count else {
      return nil
    }
    return items[region - 1]
  }

  /// The points the Event List shows, read from the window it is showing them in.
  ///
  /// Every `Fader` row is one point, and the number of a point is its place among those rows in
  /// the order the table answers them, which is time order. The note rows of the same region are
  /// left out here, as the fader rows are left out of the notes. A row the reader cannot read
  /// every field of is left out too: a half read point would take a number that `automation set`
  /// then sends an edit to.
  public static func points(in window: any AXNode) throws -> [Point] {
    let table = try LocatorResolver.element(of: Locators.eventListTable, in: window)
    let rows = table.children.filter { $0.role == "AXRow" }
    return rows.compactMap(point(of:)).enumerated().map { place, point in
      var numbered = point
      numbered.point = place + 1
      return numbered
    }
  }

  /// The cells of a row, in the order the table answers them: the two markers Logic keeps at the
  /// left, the position, the status, the channel, the number of the control, the value and the
  /// parameter. A note row carries its pitch, its velocity and its length in the last three.
  private enum Cell: Int {
    case position = 2
    case status = 3
    case value = 6
    case parameter = 7
  }

  /// One row read as a point, or nothing when the row is not a fader or does not read.
  private static func point(of row: any AXNode) -> Point? {
    let cells = row.children.filter { $0.role == "AXCell" }
    guard text(of: cells, at: .status) == faderStatus,
      let position = text(of: cells, at: .position),
      let parameter = text(of: cells, at: .parameter),
      let value = number(of: cells, at: .value)
    else {
      return nil
    }
    return Point(
      point: 0,
      position: trimmed(position),
      parameter: trimmed(parameter),
      value: value)
  }

  /// What one cell says, from the element under it, or nothing when the cell is not there.
  ///
  /// Logic writes the text of a cell on the element inside it rather than on the cell, and a
  /// position sits on the group that holds one slider per segment.
  private static func text(of cells: [any AXNode], at cell: Cell) -> String? {
    under(cells, at: cell)?.description
  }

  /// What the value cell holds as a number.
  ///
  /// It is read from the value description, which is what Logic shows on the slider. The value
  /// under it is a scaled 32 bit number on the sliders of the Event List, and no reader turns
  /// that back into a point on the fader scale.
  private static func number(of cells: [any AXNode], at cell: Cell) -> Int? {
    guard let element = under(cells, at: cell), let carried = element.valueDescription else {
      return nil
    }
    return Int(trimmed(carried))
  }

  /// The element inside one cell of a row, or nothing when the row has no such cell.
  private static func under(_ cells: [any AXNode], at cell: Cell) -> (any AXNode)? {
    guard cell.rawValue < cells.count else {
      return nil
    }
    return cells[cell.rawValue].children.first
  }

  /// The group that holds the areas of the tracks, wherever it sits under the element.
  private static func contents(of node: any AXNode) -> (any AXNode)? {
    if node.description == RegionReader.contentsGroup {
      return node
    }
    for child in node.children {
      if let found = contents(of: child) {
        return found
      }
    }
    return nil
  }

  /// One text with the spaces around it taken off.
  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// What a caller that gave no press gets when something asks it to press.
  ///
  /// It refuses rather than doing nothing. A press that quietly went nowhere would leave the
  /// command reading an Event List with no fader row in it, and it would report an element that is
  /// missing for a wire that was never joined here.
  private static func noPressWasGiven(_ locator: Locator) throws {
    throw Refusal(
      reason: "No press was given for \(locator.name), so nothing could press it.",
      code: .internalFailure)
  }

  private static func noSelectWasGiven(_ region: any AXNode) throws {
    throw Refusal(
      reason: "No selection was given, so no region could be selected.",
      code: .internalFailure)
  }
}

extension AutomationMenus {
  /// The Logic of this Mac, selected in its window and pressed through its menu bar.
  public static func live() -> AutomationMenus {
    AutomationMenus(
      press: AutomationMenus.pressInTheMenuBarOfThisMac,
      select: AutomationMenus.selectInTheLogicOfThisMac)
  }

  /// Presses the element one locator names, in the menu bar of the Logic that runs.
  ///
  /// The walk starts at the application and not at the window in front, because the menu bar of an
  /// application sits beside its windows and not under one. A press through Accessibility is not a
  /// mouse event, so it does not go through the input gate: it asks the one element the walk found
  /// to act on itself.
  ///
  /// Nothing here reads whether Logic offers the item. Accessibility gives a menu item no field
  /// that says so, and Logic offers the first of these two only while a region is selected. A
  /// press Logic does nothing with comes back as success, and the command then reads an Event List
  /// with no fader row in it and stops there.
  public static func pressInTheMenuBarOfThisMac(_ locator: Locator) throws {
    let tree = try LogicTree.ofRunningLogic()
    let element = try LocatorResolver.element(of: locator, in: tree.root)
    guard let live = element as? LiveAXNode else {
      throw Refusal(
        reason: "\(locator.name) was found in a recorded tree, which nothing can press.",
        code: .internalFailure)
    }
    let answered = AXUIElementPerformAction(live.element, kAXPressAction as CFString)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused the press of \(locator.name), error \(answered.rawValue).",
        code: .internalFailure)
    }
  }

  /// Selects one region of the Tracks window, by writing `AXSelected` on its item.
  ///
  /// This is how the Piano Roll selects a note, and the probe of Logic 12.3.1 did not try it on a
  /// region. So a Logic that refuses the write comes back as the error the Mac gave, and the live
  /// acceptance of phase 4 is what says which of the two happens.
  public static func selectInTheLogicOfThisMac(_ region: any AXNode) throws {
    guard let live = region as? LiveAXNode else {
      throw Refusal(
        reason: "the region was found in a recorded tree, which nothing can select.",
        code: .internalFailure)
    }
    let answered = AXUIElementSetAttributeValue(
      live.element, kAXSelectedAttribute as CFString, kCFBooleanTrue as CFTypeRef)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused the selection of the region, error \(answered.rawValue).",
        code: .internalFailure)
    }
  }
}
