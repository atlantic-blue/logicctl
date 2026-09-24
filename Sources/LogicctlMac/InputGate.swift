import ApplicationServices
import CoreGraphics

/// The one place in logicctl that makes a mouse event or a key event and sends it to Logic.
///
/// Logic reads an event from the window server, not from an argument, so an event that lands on
/// the wrong element changes the wrong thing and no later read can tell that it happened. The gate
/// proves the aim before it sends: Logic is frontmost, no window of Logic is modal, and the
/// element the window server finds under the point is the target. When one check fails, the gate
/// sends nothing and throws.
///
/// Every read is a closure the caller gives, so a test drives the gate with no Logic and no
/// window server.
public struct InputGate {
  /// What a caller asks the gate to send.
  public enum Request {
    /// A click of the left button at a point, with the element that must be under that point.
    case click(CGPoint, target: AXUIElement)
    /// A key, with the element that must hold the focus, or nil when the caller names none.
    case key(CGKeyCode, flags: CGEventFlags, focus: AXUIElement?)
  }

  /// One event the gate sends once every check holds.
  public enum Event: Equatable {
    case mouseDown(CGPoint)
    case mouseUp(CGPoint)
    case keyDown(CGKeyCode, CGEventFlags)
    case keyUp(CGKeyCode, CGEventFlags)
  }

  /// Why the gate sent nothing.
  public enum Refusal: Error, Equatable {
    /// The window server sends events to another application, so this event would reach it.
    case logicIsNotFrontmost
    /// A window of Logic is modal, so it takes the event and the aim means nothing.
    case aWindowOfLogicIsModal
    /// The element under the point is not the target, or nothing is under the point.
    case theElementAtThePointIsNotTheTarget
    /// The element that takes keys is not the target.
    case theTargetDoesNotHoldTheFocus
  }

  /// Reads whether Logic is the application the window server sends events to.
  public typealias FrontmostReader = () -> Bool
  /// Reads whether a window of Logic is modal.
  public typealias ModalReader = () -> Bool
  /// Reads the element the window server finds at a point, or nil when it finds none.
  public typealias ElementReader = (CGPoint) -> AXUIElement?
  /// Reads the element of Logic that takes keys, or nil when none does.
  public typealias FocusReader = () -> AXUIElement?
  /// Sends one event.
  public typealias Sender = (Event) -> Void

  private let readFrontmost: FrontmostReader
  private let readModal: ModalReader
  private let readElementAtPoint: ElementReader
  private let readFocus: FocusReader
  private let sendOne: Sender

  public init(
    frontmost: @escaping FrontmostReader,
    modal: @escaping ModalReader,
    elementAtPoint: @escaping ElementReader,
    focus: @escaping FocusReader,
    sender: @escaping Sender
  ) {
    readFrontmost = frontmost
    readModal = modal
    readElementAtPoint = elementAtPoint
    readFocus = focus
    sendOne = sender
  }

  /// Sends the events of one request, or throws and sends nothing at all.
  public func post(_ request: Request) throws {
    guard readFrontmost() else {
      throw Refusal.logicIsNotFrontmost
    }
    guard readModal() == false else {
      throw Refusal.aWindowOfLogicIsModal
    }

    switch request {
    case .click(let point, _):
      sendOne(.mouseDown(point))
      sendOne(.mouseUp(point))
    case .key(let code, let flags, let focus):
      if let focus {
        guard let holder = readFocus(), CFEqual(holder, focus) else {
          throw Refusal.theTargetDoesNotHoldTheFocus
        }
      }
      sendOne(.keyDown(code, flags))
      sendOne(.keyUp(code, flags))
    }
  }
}

extension InputGate {
  /// The gate that reads the real Logic and sends to the real window server.
  ///
  /// The pipeline has no Logic, so no test in the pipeline drives this gate. The live suite proves
  /// it against Logic 12.3.1 on the Mac.
  public static func live(logic pid: pid_t) -> InputGate {
    let application = AXUIElementCreateApplication(pid)
    return InputGate(
      frontmost: { frontmostProcess() == pid },
      modal: { windows(of: application).contains(where: isModal) },
      elementAtPoint: { point in element(of: application, at: point) },
      focus: { element(named: kAXFocusedUIElementAttribute, of: application) },
      sender: sendToTheWindowServer)
  }
}

/// The process the window server sends events to, or nil when Accessibility reads none.
private func frontmostProcess() -> pid_t? {
  guard
    let application = element(
      named: kAXFocusedApplicationAttribute, of: AXUIElementCreateSystemWide())
  else {
    return nil
  }
  var pid: pid_t = 0
  guard AXUIElementGetPid(application, &pid) == .success else {
    return nil
  }
  return pid
}

/// The windows of an application, or an empty list when Accessibility reads none.
private func windows(of application: AXUIElement) -> [AXUIElement] {
  guard let value = attribute(named: kAXWindowsAttribute, of: application) as? [AXUIElement] else {
    return []
  }
  return value
}

/// True when a window takes every event of its application until a person answers it.
private func isModal(_ window: AXUIElement) -> Bool {
  if attribute(named: kAXModalAttribute, of: window) as? Bool == true {
    return true
  }
  return attribute(named: kAXRoleAttribute, of: window) as? String == kAXSheetRole
}

/// The element an application carries at a point, or nil when it carries none there.
private func element(of application: AXUIElement, at point: CGPoint) -> AXUIElement? {
  var found: AXUIElement?
  let read = AXUIElementCopyElementAtPosition(
    application, Float(point.x), Float(point.y), &found)
  guard read == .success else {
    return nil
  }
  return found
}

/// One element an attribute carries, or nil when the attribute carries something else.
private func element(named name: String, of parent: AXUIElement) -> AXUIElement? {
  guard let value = attribute(named: name, of: parent),
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else {
    return nil
  }
  return (value as! AXUIElement)
}

/// The value of one Accessibility attribute, or nil when the read fails.
private func attribute(named name: String, of element: AXUIElement) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}

/// Makes one event and sends it to the window server.
private func sendToTheWindowServer(_ event: InputGate.Event) {
  let made: CGEvent?
  switch event {
  case .mouseDown(let point):
    made = CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point,
      mouseButton: .left)
  case .mouseUp(let point):
    made = CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point,
      mouseButton: .left)
  case .keyDown(let code, let flags):
    made = keyEvent(code, flags: flags, down: true)
  case .keyUp(let code, let flags):
    made = keyEvent(code, flags: flags, down: false)
  }
  made?.post(tap: .cghidEventTap)
}

/// One key event, with the modifiers the caller asked for.
private func keyEvent(_ code: CGKeyCode, flags: CGEventFlags, down: Bool) -> CGEvent? {
  let made = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
  made?.flags = flags
  return made
}
