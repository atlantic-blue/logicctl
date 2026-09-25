import ApplicationServices
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

  /// Writes one text into the field a locator names, in place of what is in it.
  public typealias Write = (Locator, String) throws -> Void

  /// Presses one item of the menu bar of Logic.
  public let press: Press

  /// Writes into one field of a track header.
  public let write: Write

  public init(press: @escaping Press) {
    self.press = press
    self.write = TrackActions.noWriteWasGiven
  }

  public init(press: @escaping Press, write: @escaping Write) {
    self.press = press
    self.write = write
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
  /// Writes one text into the field a locator names, in the window Logic shows in front.
  ///
  /// In the tree recorded from Logic 12.3.1, the name field of a track header carries one action,
  /// `AXPress`, its value reads `0` rather than the name, and its help text reads "Name field.
  /// Double-click to rename the track." So Logic may refuse a write of the value attribute here,
  /// where it takes the same write into the name field of the save panel. A refusal comes back as
  /// the error the Mac gave, and the command that asked for it reads the tracks again and answers
  /// `timeout` rather than a rename that nothing did. The live acceptance of phase 2 is what says
  /// which of the two happens.
  public static func writeIntoTheLogicOfThisMac(_ locator: Locator, _ text: String) throws {
    guard let front = try AXDriver.treeOfRunningLogic()?.atTheFrontWindow() else {
      throw Refusal(reason: "Logic shows no window, so nothing in it could be written into.")
    }
    let element = try LocatorResolver.element(of: locator, in: front.root)
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
