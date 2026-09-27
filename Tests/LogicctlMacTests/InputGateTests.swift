import ApplicationServices
import CoreGraphics
import Foundation
import LogicctlMac
import Testing

/// What the gate sent, in the order it sent it.
private final class Recorder {
  var events: [InputGate.Event] = []

  func take(_ event: InputGate.Event) {
    events.append(event)
  }
}

/// A gate whose reads answer what the test asks for, and whose events go to the recorder.
///
/// Every read holds by default, so one test names the one read it makes fail.
private func gate(
  frontmost: Bool = true,
  modal: Bool = false,
  atPoint: AXUIElement? = nil,
  focus: AXUIElement? = nil,
  sendingTo recorder: Recorder
) -> InputGate {
  InputGate(
    frontmost: { frontmost },
    modal: { modal },
    elementAtPoint: { _ in atPoint },
    focus: { focus },
    sender: recorder.take)
}

private let somewhere = CGPoint(x: 120, y: 340)

/// A command never clicks a thing it did not aim at.
///
/// The gate reads the element the window server finds under the point. When that element is not
/// the target, Logic reads no click, so no other track is muted and no other region is deleted.
@Test func theGateRefusesWhenTheTargetIsNotAtThePoint() {
  let recorder = Recorder()
  let target = AXUIElementCreateApplication(501)
  let anotherElement = AXUIElementCreateApplication(502)
  let proven = gate(atPoint: anotherElement, sendingTo: recorder)

  #expect(throws: InputGate.Refusal.theElementAtThePointIsNotTheTarget) {
    try proven.post(.click(somewhere, target: target))
  }
  #expect(recorder.events.isEmpty, "Logic reads nothing when the aim is wrong")
}

/// A point that carries no element is a wrong aim too, so the gate refuses it the same way.
@Test func theGateRefusesWhenNothingIsUnderThePoint() {
  let recorder = Recorder()
  let target = AXUIElementCreateApplication(501)
  let proven = gate(atPoint: nil, sendingTo: recorder)

  #expect(throws: InputGate.Refusal.theElementAtThePointIsNotTheTarget) {
    try proven.post(.click(somewhere, target: target))
  }
  #expect(recorder.events.isEmpty, "Logic reads nothing when the point carries no element")
}

/// An event goes to the application the window server points at, so a click sent while Logic is
/// behind another application reaches that application instead.
@Test func theGateRefusesWhenLogicIsNotFrontmost() {
  let recorder = Recorder()
  let target = AXUIElementCreateApplication(501)
  let proven = gate(frontmost: false, atPoint: target, sendingTo: recorder)

  #expect(throws: InputGate.Refusal.logicIsNotFrontmost) {
    try proven.post(.click(somewhere, target: target))
  }
  #expect(recorder.events.isEmpty, "no other application reads an event of logicctl")
}

/// A modal window takes every event of its application, so the aim behind it means nothing.
@Test func theGateRefusesWhenAWindowOfLogicIsModal() {
  let recorder = Recorder()
  let target = AXUIElementCreateApplication(501)
  let proven = gate(modal: true, atPoint: target, sendingTo: recorder)

  #expect(throws: InputGate.Refusal.aWindowOfLogicIsModal) {
    try proven.post(.click(somewhere, target: target))
  }
  #expect(recorder.events.isEmpty, "a dialog reads no click of logicctl")
}

/// A key reaches the element that holds the focus, so a key aimed at another element is refused.
@Test func theGateRefusesWhenTheTargetDoesNotHoldTheFocus() {
  let recorder = Recorder()
  let target = AXUIElementCreateApplication(501)
  let holder = AXUIElementCreateApplication(502)
  let proven = gate(focus: holder, sendingTo: recorder)

  #expect(throws: InputGate.Refusal.theTargetDoesNotHoldTheFocus) {
    try proven.post(.key(36, flags: [], focus: target))
  }
  #expect(recorder.events.isEmpty, "the wrong field reads no key")
}

/// The gate is the way in, so a proven click does reach Logic, as a press and a release.
@Test func theGateSendsTheClickWhenEveryCheckHolds() throws {
  let recorder = Recorder()
  let target = AXUIElementCreateApplication(501)
  let proven = gate(atPoint: target, sendingTo: recorder)

  try proven.post(.click(somewhere, target: target))

  #expect(recorder.events == [.mouseDown(somewhere), .mouseUp(somewhere)])
}

/// Logic opens the name editor of a track header on a double click, so a double click is something
/// the gate can send, and it says which of the two clicks each event belongs to.
///
/// The window server tells one click from two by the click state an event carries. Two presses that
/// both said 1 are two single clicks, and Logic answers those by selecting the track and no more.
/// So the second press and release say 2, and the editor opens.
@Test func theGateSendsTheDoubleClickWhenEveryCheckHolds() throws {
  let recorder = Recorder()
  let target = AXUIElementCreateApplication(501)
  let proven = gate(atPoint: target, sendingTo: recorder)

  try proven.post(.doubleClick(somewhere, target: target))

  #expect(
    recorder.events == [
      .mouseDown(somewhere), .mouseUp(somewhere),
      .secondMouseDown(somewhere), .secondMouseUp(somewhere),
    ],
    "two clicks at the one point, each a press and a release")
  #expect(
    recorder.events.map(\.clickState) == [1, 1, 2, 2],
    "and the second click says it is the second, which is what makes it a double click")
}

/// A double click is aimed the way a click is, so the gate refuses one whose point carries another
/// element.
///
/// A double click that landed on the header of another track would open the editor of that track,
/// and the name would go into it. The rename then reads the old name back and reports a timeout,
/// while another track of the project carries a name nobody asked for.
@Test func theGateRefusesADoubleClickWhenTheTargetIsNotAtThePoint() {
  let recorder = Recorder()
  let target = AXUIElementCreateApplication(501)
  let anotherElement = AXUIElementCreateApplication(502)
  let proven = gate(atPoint: anotherElement, sendingTo: recorder)

  #expect(throws: InputGate.Refusal.theElementAtThePointIsNotTheTarget) {
    try proven.post(.doubleClick(somewhere, target: target))
  }
  #expect(recorder.events.isEmpty, "no editor opens anywhere when the aim is wrong")
}

/// A key on the element that holds the focus reaches Logic, as a press and a release.
@Test func theGateSendsTheKeyWhenEveryCheckHolds() throws {
  let recorder = Recorder()
  let target = AXUIElementCreateApplication(501)
  let proven = gate(focus: target, sendingTo: recorder)

  try proven.post(.key(36, flags: .maskCommand, focus: target))

  #expect(recorder.events == [.keyDown(36, .maskCommand), .keyUp(36, .maskCommand)])
}

/// The three checks are worth nothing while another file can make an event of its own, so this
/// test reads the whole of Sources and holds the making of events to the gate.
///
/// A read that finds no file reports the same success as a read that found every file, so this
/// test refuses a run that found no Swift file, and a run that did not find the gate itself.
@Test func noFileOutsideTheGateMakesAnEvent() throws {
  let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Sources")

  var files: [URL] = []
  let walk = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
  while let found = walk?.nextObject() as? URL {
    if found.pathExtension == "swift" {
      files.append(found)
    }
  }

  #expect(!files.isEmpty, "this test read no Swift file, so it proves nothing")
  #expect(
    files.contains { $0.lastPathComponent == "InputGate.swift" },
    "this test did not read the gate, so it proves nothing")

  for file in files where file.lastPathComponent != "InputGate.swift" {
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains("CGEvent("), "\(file.lastPathComponent) makes an event of its own")
    #expect(!text.contains("CGEventPost"), "\(file.lastPathComponent) posts an event of its own")
  }
}

/// Logic says whether Logic is in front, and nothing else is asked.
///
/// The gate sends an event to the window server, and the window server hands it to whichever
/// application is in front. So the gate reads that before it sends, and the read has to be a read
/// Logic answers. Measured on Logic 12.3.1 on 2026-09-27, with Logic in front and `status`
/// answering frontmost true: `kAXFocusedApplicationAttribute` on the system wide element answered
/// error -25204 five times out of five, and `kAXFrontmostAttribute` on the application element of
/// Logic answered success and true five times out of five. `tracks mute --index 1 --on` refused
/// with `logicIsNotFrontmost` while Logic was in front.
///
/// Only a successful read of a true says Logic is in front. An error says nothing. A missing value
/// says nothing. A value of another kind says nothing. The gate reads all three as not frontmost,
/// because an event sent on a value nobody answered reaches whatever application is there, and no
/// later read of Logic can tell that it happened.
@Test func theGateReadsFrontmostFromTheLogicApplicationElement() {
  let answered = AXError.success.rawValue
  let refused = AXError.cannotComplete.rawValue

  #expect(
    InputGate.isFrontmost(read: answered, value: true as CFTypeRef),
    "Logic answers that it is in front, so the gate may send the event")
  #expect(
    InputGate.isFrontmost(read: answered, value: false as CFTypeRef) == false,
    "Logic answers that another application is in front")
  #expect(
    InputGate.isFrontmost(read: answered, value: "true" as CFTypeRef) == false,
    "a value that is not a boolean is not an answer about the front application")
  #expect(
    InputGate.isFrontmost(read: refused, value: nil) == false,
    "the read that answered -25204 on this Mac says nothing about the front application")
}
