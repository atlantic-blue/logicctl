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
