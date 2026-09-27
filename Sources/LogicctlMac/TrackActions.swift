import ApplicationServices
import CoreGraphics
import Foundation
import LogicctlCore

/// What kind of track `tracks add` makes.
///
/// Logic offers many kinds and logicctl offers these two, because they are the two the stories
/// ask for and each one is a single item of the Track menu. `Track.Kind` carries a third case,
/// `other`, which is what a reader answers for a track whose kind the header does not say. Nobody
/// can ask for that one, so it is not here.
public enum NewTrackType: String, CaseIterable, Sendable, Equatable {
  case softwareInstrument = "software-instrument"
  case audio = "audio"

  /// The kind a track of this type carries in the state.
  public var kind: Track.Kind {
    switch self {
    case .softwareInstrument:
      return .softwareInstrument
    case .audio:
      return .audio
    }
  }
}

/// Makes one track in the project Logic has open, through the Track menu.
///
/// The press is a closure the caller gives, as it is for `AppControl` and `ProjectChooser`. The
/// pipeline has no Logic and no menu bar to press, so a test drives the same command with a Logic
/// of its own and nothing on the Mac opens.
public struct TrackActions {
  /// Why the Mac gave no press. The reason reaches the answer of the command, so a person reads
  /// what Logic refused without going to look for a log.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// One short reason, in the words of the Mac that refused.
    public let reason: String

    /// The code a caller reads and exits with.
    public let code: ErrorCode

    public init(reason: String, code: ErrorCode = .elementNotFound) {
      self.reason = reason
      self.code = code
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(code: code, message: reason)
    }
  }

  /// Presses the one element a locator names.
  public typealias Press = (Locator) throws -> Void

  /// Clicks the one control a locator names, through the input gate.
  public typealias Click = (Locator) throws -> Void

  /// Reads where one control sits: the element the window server finds under the point, and the
  /// point itself.
  public typealias TargetRead = (Locator) throws -> (element: AXUIElement, centre: CGPoint)

  /// Writes one text into the field a locator names, in place of what is in it.
  public typealias Write = (Locator, String) throws -> Void

  /// Presses one item of the menu bar of Logic.
  public let press: Press

  /// Presses one control of the window Logic shows in front.
  ///
  /// It is a second closure and not the one above, because the two walk different trees. The menu
  /// bar of an application sits beside its windows, and a track header sits inside one, so a walk
  /// that starts at the application never reaches a header and a walk that starts at the window
  /// never reaches the menu bar.
  public let pressInWindow: Press

  /// Clicks one control of the window Logic shows in front.
  ///
  /// It is a third closure and not `pressInWindow`, because the two reach Logic by different
  /// roads. A press asks one element to act on itself. A click asks the window server to deliver a
  /// mouse event where that element sits. Logic 12.3.1 answers a press on the mute check box of a
  /// track header with success and leaves the check box as it was, so the two are not two ways of
  /// doing one thing.
  public let clickInWindow: Click

  /// Writes into one field of a track header.
  public let write: Write

  /// A caller names the closures its command needs, and what it leaves out refuses.
  ///
  /// A command that only presses a menu item gives one closure, and a test of it says nothing
  /// about a window it never touches.
  public init(
    press: Press? = nil, pressInWindow: Press? = nil, click: Click? = nil, write: Write? = nil
  ) {
    self.press = press ?? TrackActions.noMenuPressWasGiven
    self.pressInWindow = pressInWindow ?? TrackActions.noWindowPressWasGiven
    self.clickInWindow = click ?? TrackActions.noClickWasGiven
    self.write = write ?? TrackActions.noWriteWasGiven
  }

  /// What a caller that asked for a press alone gets when something asks it to write.
  ///
  /// It refuses rather than doing nothing. A write that quietly went nowhere would leave the
  /// rename reading the old name back, and the command would report a timeout that names Logic
  /// for a wire that was never joined here.
  private static func noWriteWasGiven(_ locator: Locator, _ text: String) throws {
    throw Refusal(
      reason: "No write was given for \(locator.name), so nothing could be written into it.",
      code: .internalFailure)
  }

  /// What a caller that asked for a menu press alone gets when something asks it to press in the
  /// window, and the other way round.
  ///
  /// Each one refuses rather than doing nothing. A press that quietly went nowhere would leave the
  /// command reading the old state back, and it would report a timeout that names Logic for a wire
  /// that was never joined here.
  private static func noWindowPressWasGiven(_ locator: Locator) throws {
    throw Refusal(
      reason: "No window press was given for \(locator.name), so nothing could press it.",
      code: .internalFailure)
  }

  private static func noMenuPressWasGiven(_ locator: Locator) throws {
    throw Refusal(
      reason: "No menu press was given for \(locator.name), so nothing could press it.",
      code: .internalFailure)
  }

  /// What a caller that asked for a press alone gets when something asks it to click.
  ///
  /// It refuses for the reason the other two refuse. A click that quietly went nowhere would leave
  /// the command reading the old state back, and it would report a timeout that names Logic for a
  /// wire that was never joined here.
  private static func noClickWasGiven(_ locator: Locator) throws {
    throw Refusal(
      reason: "No click was given for \(locator.name), so nothing could click it.",
      code: .internalFailure)
  }
}

extension TrackActions {
  /// Makes one track of this type.
  ///
  /// Logic makes the track as the item is pressed. It asks nothing and it opens no sheet, so the
  /// press is the whole of the action, and the caller reads the project again to see what it did.
  public func add(_ type: NewTrackType) throws {
    try press(TrackActions.menuItem(for: type))
  }

  /// Gives one track another name, by writing into the name field of its header.
  ///
  /// The number counts the headers from 0, the way a locator does, and not from 1 the way a person
  /// types `--index`. The caller reads the tracks again afterwards, because a write that Logic
  /// refused answers the same as one it took.
  public func rename(trackNumber number: Int, to name: String) throws {
    try write(Locators.trackNameField(number: number), name)
  }

  /// Clicks the mute button in the header of one track.
  ///
  /// Logic 12.3.1 offers one action on that check box, `AXPress`, and it answers the press with
  /// success and leaves the value at 0, so the track stays as it was. A click at the centre of the
  /// same check box changes it, so the click is the whole of the action here.
  ///
  /// The button is a check box, so the click turns the mute on when it is off and off when it is
  /// on. Nothing here says which of the two happened. The caller decides whether to click at all,
  /// and reads the track again afterwards.
  ///
  /// The number counts the headers from 0, the way a locator does, and not from 1 the way a person
  /// types `--index`.
  public func mute(trackNumber number: Int) throws {
    try clickInWindow(Locators.trackMuteButton(number: number))
  }

  /// Clicks the solo button in the header of one track.
  ///
  /// It is clicked and not pressed for the reason the mute button is. Logic takes the press,
  /// answers success, and leaves the check box as it was.
  ///
  /// The button is a check box, so the click turns the solo on when it is off and off when it is
  /// on. Nothing here says which of the two happened. The caller decides whether to click at all,
  /// and reads the track again afterwards.
  ///
  /// The number counts the headers from 0, the way a locator does, and not from 1 the way a person
  /// types `--index`.
  public func solo(trackNumber number: Int) throws {
    try clickInWindow(Locators.trackSoloButton(number: number))
  }

  /// The item of the Track menu that makes one track of this type.
  public static func menuItem(for type: NewTrackType) -> Locator {
    switch type {
    case .softwareInstrument:
      return Locators.newSoftwareInstrumentTrack
    case .audio:
      return Locators.newAudioTrack
    }
  }
}

extension TrackActions {
  /// The Logic of this Mac, pressed through its menu bar and written into through its window.
  public static func live() -> TrackActions {
    TrackActions(
      press: TrackActions.pressInTheMenuBarOfThisMac,
      pressInWindow: TrackActions.pressInTheWindowOfThisMac,
      click: TrackActions.clickInTheWindowOfThisMac,
      write: TrackActions.writeIntoTheLogicOfThisMac)
  }

  /// Presses the element one locator names, in the menu bar of the Logic that runs.
  ///
  /// The walk starts at the application and not at the window in front, because the menu bar of an
  /// application sits beside its windows and not under one. A press through Accessibility is not a
  /// mouse event, so it does not go through the input gate: it asks the one element the walk found
  /// to act on itself.
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
}

extension TrackActions {
  /// Writes one text into the field a locator names, in the window the project sits in.
  ///
  /// In the tree recorded from Logic 12.3.1, the name field of a track header carries one action,
  /// `AXPress`, its value reads `0` rather than the name, and its help text reads "Name field.
  /// Double-click to rename the track." So Logic may refuse a write of the value attribute here,
  /// where it takes the same write into the name field of the save panel. A refusal comes back as
  /// the error the Mac gave, and the command that asked for it reads the tracks again and answers
  /// `timeout` rather than a rename that nothing did. The live acceptance of phase 2 is what says
  /// which of the two happens.
  public static func writeIntoTheLogicOfThisMac(_ locator: Locator, _ text: String) throws {
    guard let project = try AXDriver.treeOfRunningLogic()?.atTheProjectWindow() else {
      throw Refusal(
        reason: "Logic shows no window with the tracks of a project in it, so "
          + "\(Locators.mainWindow.name) reached nothing to write into.")
    }
    let element = try LocatorResolver.element(of: locator, in: project.root)
    guard let live = element as? LiveAXNode else {
      throw Refusal(
        reason: "\(locator.name) was found in a recorded tree, which nothing can write into.",
        code: .internalFailure)
    }
    let answered = AXUIElementSetAttributeValue(
      live.element, kAXValueAttribute as CFString, text as CFTypeRef)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused the write into \(locator.name), error \(answered.rawValue).",
        code: .internalFailure)
    }
  }
}

extension TrackActions {
  /// Presses the one control a locator names, in the window the project sits in.
  ///
  /// The walk starts at the project window and not at the application, because a track header sits
  /// inside a window. A press through Accessibility is not a mouse event, so it does not go through
  /// the input gate: it asks the one element the walk found to act on itself.
  ///
  /// In the tree recorded from Logic 12.3.1 the mute button of a track header is an `AXCheckBox`
  /// whose one action is `AXPress`, so the press is the whole of what Logic offers here, and it
  /// turns the mute on when it is off and off when it is on. The caller reads the track again
  /// afterwards, because a press Logic refused answers the same as one it took.
  public static func pressInTheWindowOfThisMac(_ locator: Locator) throws {
    guard let project = try AXDriver.treeOfRunningLogic()?.atTheProjectWindow() else {
      throw Refusal(
        reason: "Logic shows no window with the tracks of a project in it, so "
          + "\(Locators.mainWindow.name) reached nothing to press.")
    }
    let element = try LocatorResolver.element(of: locator, in: project.root)
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
}

extension TrackActions {
  /// Clicks the centre of the control a locator names, through the gate that proves the aim.
  ///
  /// The gate carries the control as the target, so the two events reach Logic only while the
  /// element the window server finds under the point is that control. A click of a check box that
  /// landed anywhere else would change another track, and no later read could say that it had, so a
  /// refusal of the gate travels out of here and stops the command.
  public static func clickThroughTheGate(
    _ gate: InputGate, readingTheTargetWith read: @escaping TargetRead
  ) -> Click {
    { locator in
      let target = try read(locator)
      try gate.post(.click(target.centre, target: target.element))
    }
  }
}

extension TrackActions {
  /// Clicks the centre of one control of the window the project sits in, in the Logic of this Mac.
  ///
  /// The gate is built for each click, because it reads the Logic that runs now and a command can
  /// start before Logic does.
  public static func clickInTheWindowOfThisMac(_ locator: Locator) throws {
    let logic = try AXDriver.processIDOfRunningLogic()
    let click = TrackActions.clickThroughTheGate(
      InputGate.live(logic: logic),
      readingTheTargetWith: TrackActions.targetInTheWindowOfThisMac)
    try click(locator)
  }

  /// The element a locator names in the window of the project, and the middle of it.
  private static func targetInTheWindowOfThisMac(
    _ locator: Locator
  ) throws -> (element: AXUIElement, centre: CGPoint) {
    guard let project = try AXDriver.treeOfRunningLogic()?.atTheProjectWindow() else {
      throw Refusal(
        reason: "Logic shows no window with the tracks of a project in it, so "
          + "\(Locators.mainWindow.name) reached nothing to click.")
    }
    let element = try LocatorResolver.element(of: locator, in: project.root)
    guard let live = element as? LiveAXNode else {
      throw Refusal(
        reason: "\(locator.name) was found in a recorded tree, which nothing can click.",
        code: .internalFailure)
    }
    guard let centre = TrackActions.centre(of: live.element) else {
      throw Refusal(
        reason: "Logic does not say where \(locator.name) sits, so nothing could click its centre.")
    }
    return (element: live.element, centre: centre)
  }

  /// The middle of one element, or nothing when Logic answers no position or no size for it.
  ///
  /// The point is in the coordinates of the screen, which is what the window server reads and what
  /// Accessibility answers, so the gate finds the element it is aimed at under the same point.
  private static func centre(of element: AXUIElement) -> CGPoint? {
    guard let position = TrackActions.position(of: element),
      let size = TrackActions.size(of: element)
    else {
      return nil
    }
    return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
  }

  /// Where the top left corner of one element sits, or nothing when Logic does not say.
  private static func position(of element: AXUIElement) -> CGPoint? {
    var read = CGPoint.zero
    guard let value = TrackActions.axValue(kAXPositionAttribute, of: element),
      AXValueGetValue(value, .cgPoint, &read)
    else {
      return nil
    }
    return read
  }

  /// How big one element is, or nothing when Logic does not say.
  private static func size(of element: AXUIElement) -> CGSize? {
    var read = CGSize.zero
    guard let value = TrackActions.axValue(kAXSizeAttribute, of: element),
      AXValueGetValue(value, .cgSize, &read)
    else {
      return nil
    }
    return read
  }

  /// One attribute of an element that carries a point, a size or a range, or nothing when the read
  /// fails or the attribute carries something else.
  private static func axValue(_ name: String, of element: AXUIElement) -> AXValue? {
    var found: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &found) == .success,
      let read = found, CFGetTypeID(read) == AXValueGetTypeID()
    else {
      return nil
    }
    return (read as! AXValue)
  }
}

extension TrackActions {
  /// Removes one track.
  ///
  /// Logic removes the track that is selected, so the header of the track is pressed first and the
  /// item of the Track menu after it. Nothing in the state of a project says which track is
  /// selected, so the press on the header answers the same whether it selected the track or not.
  /// The tracks the project has left are the whole of the evidence that the right one went.
  ///
  /// The number counts the headers from 0, the way a locator does, and not from 1 the way a person
  /// types `--index`.
  public func delete(trackNumber number: Int) throws {
    try pressInWindow(Locators.trackHeader(number: number))
    try press(TrackActions.deleteTrack)
  }

  /// The item of the Track menu that removes the track that is selected.
  ///
  /// The title is matched whole. The same menu holds `Delete Unused Tracks`, which removes every
  /// track that carries no region, so a walk that took the first item starting with those two
  /// words would take tracks nobody named.
  ///
  /// The walk starts at the application, because the menu bar of an application sits beside its
  /// windows and not under one. No recorded tree holds a menu bar, so the live suite of phase 2 is
  /// what proves this walk against Logic itself.
  public static let deleteTrack = Locator(
    name: "menu.track.deleteTrack",
    path: toTheTrackMenu + [LocatorStep(role: "AXMenuItem", title: "Delete Track")])

  /// The walk from the application of Logic to the items of its Track menu.
  private static let toTheTrackMenu: [LocatorStep] =
    Locators.trackMenu.path + [LocatorStep(role: "AXMenu")]
}
