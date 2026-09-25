import CoreGraphics
import Foundation
import Testing

@testable import LogicctlMac

/// One window of the list macOS gives, as a test writes it.
private func aWindow(
  ownedBy processID: Int, number: Int, layer: Int = 0, width: Double, height: Double
) -> [String: Any] {
  [
    kCGWindowOwnerPID as String: NSNumber(value: processID),
    kCGWindowNumber as String: NSNumber(value: number),
    kCGWindowLayer as String: NSNumber(value: layer),
    kCGWindowBounds as String: [
      "X": NSNumber(value: 0),
      "Y": NSNumber(value: 0),
      "Width": NSNumber(value: width),
      "Height": NSNumber(value: height),
    ],
  ]
}

/// The picture in a step must show Logic, and nothing else that happened to be on this Mac.
///
/// A person reads a step to compare what logicctl did with what Logic showed. Every other window
/// on the screen belongs to another program, and a picture of one of those, or of the desktop,
/// would answer a question nobody asked and would carry whatever else the person had open into
/// the history of the session.
@Test func theCaptureTakesTheWindowOfLogicAndNoOther() throws {
  let onTheScreen = [
    aWindow(ownedBy: 200, number: 11, width: 2000, height: 1200),
    aWindow(ownedBy: 501, number: 22, width: 1400, height: 900),
    aWindow(ownedBy: 900, number: 33, width: 1800, height: 1000),
  ]

  let window = try WindowCapture.windowID(ownedBy: 501, in: onTheScreen)

  #expect(window == 22, "the window of the Logic process, and not the largest window on the Mac")
}

/// Logic carries panels, tooltips and menus above its main window, and each of those is a window
/// of the same process. The main window is the one a person means, so the capture takes the
/// largest window at the level a normal window sits at.
@Test func theCaptureTakesTheMainWindowAndNotAPanelOfLogic() throws {
  let onTheScreen = [
    aWindow(ownedBy: 501, number: 22, width: 1400, height: 900),
    aWindow(ownedBy: 501, number: 23, width: 300, height: 200),
    aWindow(ownedBy: 501, number: 24, layer: 25, width: 3000, height: 2000),
  ]

  let window = try WindowCapture.windowID(ownedBy: 501, in: onTheScreen)

  #expect(window == 22, "the main window, not the small panel and not the menu above it")
}

/// Logic runs with no window on the screen, so there is nothing to photograph. The capture says
/// that in a sentence the answer of the command carries, rather than photographing the screen and
/// calling the result a picture of Logic.
@Test func aLogicWithNoWindowOnTheScreenRefusesWithAReason() throws {
  let onTheScreen = [aWindow(ownedBy: 200, number: 11, width: 2000, height: 1200)]

  #expect(throws: WindowCapture.Refusal(reason: "Logic has no window on the screen")) {
    _ = try WindowCapture.windowID(ownedBy: 501, in: onTheScreen)
  }
}
