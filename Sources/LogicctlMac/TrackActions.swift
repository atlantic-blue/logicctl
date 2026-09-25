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

  /// Presses one item of the menu bar of Logic.
  public let press: Press

  public init(press: @escaping Press) {
    self.press = press
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
  /// The Logic of this Mac, pressed through its menu bar.
  public static func live() -> TrackActions {
    TrackActions(press: TrackActions.pressInTheMenuBarOfThisMac)
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
