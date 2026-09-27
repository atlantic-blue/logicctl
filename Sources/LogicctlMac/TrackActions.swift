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

  /// Gives the field a locator names one text, in place of what is in it. How Logic takes the text
  /// is the business of whoever gives the closure: the name of a track goes in through an editor
  /// that a double click opens.
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

  /// Gives one track another name, through the name field of its header.
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
      write: TrackActions.renameInTheWindowOfThisMac)
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
  /// Gives one track another name in the Logic of this Mac, through the editor of its name field.
  ///
  /// Measured on Logic 12.3.1 on 2026-09-27, on a new project: a write of the value attribute on
  /// the name field of a track header answers success and the header keeps the old name, and an
  /// `AXPress` on the same field opens nothing. A double click at its centre gives the focus to
  /// another text field, which carries the old name as its value and `AXShowMenu` and `AXConfirm`
  /// as its actions. A write of the value attribute on that field, then a confirm of it, changes
  /// the name of the track, and `tracks list` reads the new one.
  ///
  /// The gate is built for each rename, because it reads the Logic that runs now and a command can
  /// start before Logic does.
  public static func renameInTheWindowOfThisMac(_ locator: Locator, _ text: String) throws {
    let logic = try AXDriver.processIDOfRunningLogic()
    let application = AXUIElementCreateApplication(logic)
    let rename = TrackActions.renameByDoubleClickingThroughTheGate(
      InputGate.live(logic: logic),
      readingTheTargetWith: TrackActions.targetInTheWindowOfThisMac,
      focus: { TrackActions.focusedFieldOf(application) },
      writingWith: TrackActions.writeTheValueInTheLogicOfThisMac,
      confirmingWith: TrackActions.confirmInTheLogicOfThisMac)
    try rename(locator, text)
  }

  /// The field Logic gives the focus to now, with the role Logic reads it as, or nothing when Logic
  /// answers no element there.
  private static func focusedFieldOf(
    _ application: AXUIElement
  ) -> (element: AXUIElement, role: String?)? {
    guard
      let focused = TrackActions.elementOf(kAXFocusedUIElementAttribute, of: application)
    else {
      return nil
    }
    return (element: focused, role: TrackActions.textOf(kAXRoleAttribute, of: focused))
  }

  /// One element that an attribute of another element carries, or nothing when it carries
  /// something else.
  private static func elementOf(_ name: String, of parent: AXUIElement) -> AXUIElement? {
    var found: CFTypeRef?
    guard AXUIElementCopyAttributeValue(parent, name as CFString, &found) == .success,
      let read = found, CFGetTypeID(read) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return (read as! AXUIElement)
  }

  /// One attribute of an element read as text, or nothing when it carries something else.
  private static func textOf(_ name: String, of element: AXUIElement) -> String? {
    var found: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &found) == .success else {
      return nil
    }
    return found as? String
  }

  /// Writes one text into one element, in place of the value it carries.
  private static func writeTheValueInTheLogicOfThisMac(
    _ element: AXUIElement, _ text: String
  ) throws {
    let answered = AXUIElementSetAttributeValue(
      element, kAXValueAttribute as CFString, text as CFTypeRef)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused the write of the name into the editor it opened, error "
          + "\(answered.rawValue).",
        code: .internalFailure)
    }
  }

  /// Confirms what one element holds, the way a return key confirms a field a person typed in.
  private static func confirmInTheLogicOfThisMac(_ element: AXUIElement) throws {
    let answered = AXUIElementPerformAction(
      element, TrackActions.confirmAction as CFString)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused the confirm of the editor of the name, error "
          + "\(answered.rawValue).",
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
  /// Reads the element of Logic that takes keys now, with the role Logic gives it, or nothing when
  /// Logic says no element holds the focus.
  public typealias FocusRead = () throws -> (element: AXUIElement, role: String?)?

  /// Writes one text into one element, in place of the value it carries.
  public typealias ValueWrite = (AXUIElement, String) throws -> Void

  /// Confirms what one element holds, the way a return key confirms a field a person typed in.
  public typealias Confirm = (AXUIElement) throws -> Void

  /// The role Logic gives the editor it opens over the name field of a track header.
  public static let editorRole = "AXTextField"

  /// The action that keeps what an editor of Logic holds. Measured on Logic 12.3.1 on 2026-09-27:
  /// the editor of a track name offers `AXShowMenu` and this one, and no press.
  public static let confirmAction = "AXConfirm"

  /// Logic opened no editor over the name field, so there was nowhere to write the name.
  ///
  /// The name is written into the editor and nowhere else, so nothing of the project changed here.
  /// The person reads how long Logic was given and runs the command again.
  public struct NoNameEditor: FailureCarrying, Equatable, Sendable {
    /// The field the double click was aimed at.
    public let field: String

    /// How long the command gave Logic, from the double click to the last read.
    public let waitedMs: Int

    public init(field: String, waitedMs: Int) {
      self.field = field
      self.waitedMs = waitedMs
    }

    public var failure: Failure {
      Failure(
        code: .timeout,
        message:
          "Logic gave the focus to no editor of \(field) within \(waitedMs)ms, so the name was "
          + "written nowhere.",
        details: .object([
          "field": .string(field),
          "waitedMs": .number(Double(waitedMs)),
        ]))
    }
  }

  /// Gives one track another name, by opening the editor of its name field and writing into that.
  ///
  /// The double click goes through the gate, which carries the name field as the target, so the
  /// four events reach Logic only while the element the window server finds under the point is that
  /// field. A double click that landed on the header of another track would open the editor of that
  /// track and the name would go into it, so a refusal of the gate travels out of here and stops
  /// the command.
  ///
  /// Logic opens the editor a moment after it reads the second release, the way every other change
  /// of Logic lands in the tree after the event that made it, so the editor is waited for and the
  /// wait carries a limit (RUN-6). The editor is the field Logic gives the focus to, and it is not
  /// the field the double click was aimed at: that one keeps the focus while Logic opens nothing,
  /// and a write into it changes no name.
  public static func renameByDoubleClickingThroughTheGate(
    _ gate: InputGate,
    readingTheTargetWith read: @escaping TargetRead,
    focus readFocus: @escaping FocusRead,
    writingWith write: @escaping ValueWrite,
    confirmingWith confirm: @escaping Confirm,
    limitMs: Int = Wait.defaultLimitMs,
    clock: @escaping Wait.Clock = Wait.monotonicMilliseconds,
    sleeper: @escaping Wait.Sleeper = Wait.sleepMilliseconds
  ) -> Write {
    { locator, text in
      let field = try read(locator)
      try gate.post(.doubleClick(field.centre, target: field.element))

      var editor: AXUIElement?
      do {
        try Wait.until(limitMs: limitMs, clock: clock, sleeper: sleeper) {
          editor = TrackActions.editor(otherThan: field.element, in: try readFocus())
          return editor != nil
        }
      } catch let ranOut as Wait.RanOut {
        throw NoNameEditor(field: locator.name, waitedMs: ranOut.waitedMs)
      }
      guard let editor else {
        throw Refusal(
          reason: "The editor of \(locator.name) was read and then lost, so nothing was written.",
          code: .internalFailure)
      }

      try write(editor, text)
      try confirm(editor)
    }
  }

  /// The field Logic gave the focus to, when that field is an editor of its own, or nothing when
  /// Logic still holds the focus on the field the double click was aimed at.
  private static func editor(
    otherThan field: AXUIElement, in focused: (element: AXUIElement, role: String?)?
  ) -> AXUIElement? {
    guard let focused, focused.role == TrackActions.editorRole,
      CFEqual(focused.element, field) == false
    else {
      return nil
    }
    return focused.element
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
