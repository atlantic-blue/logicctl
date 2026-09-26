import ApplicationServices
import Foundation

/// One element of the tree of the running Logic, read through Accessibility.
///
/// The pipeline has no Logic, so no test there drives this node, in the same way that no test
/// drives `InputGate.live`. `RecordedAXNode` stands in its place, and the live suite on this Mac
/// proves this one against Logic 12.3.1.
///
/// A read that Accessibility refuses answers nothing rather than throwing: an element that
/// carries no title and an element whose title cannot be read both mean the same thing to a
/// locator, which is that the title is not there to match on.
public struct LiveAXNode: AXNode {
  /// The element Accessibility answers for.
  public let element: AXUIElement

  public init(_ element: AXUIElement) {
    self.element = element
  }

  /// The node an application starts at.
  public static func application(_ process: pid_t) -> LiveAXNode {
    LiveAXNode(AXUIElementCreateApplication(process))
  }

  public var role: String {
    text(kAXRoleAttribute) ?? ""
  }

  public var title: String? {
    text(kAXTitleAttribute)
  }

  public var identifier: String? {
    text(kAXIdentifierAttribute)
  }

  public var value: String? {
    text(kAXValueAttribute)
  }

  public var valueDescription: String? {
    text(kAXValueDescriptionAttribute)
  }

  public var description: String? {
    text(kAXDescriptionAttribute)
  }

  public var help: String? {
    text(kAXHelpAttribute)
  }

  public var orientation: String? {
    text(kAXOrientationAttribute)
  }

  public var actions: [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else {
      return []
    }
    return names as? [String] ?? []
  }

  public var children: [any AXNode] {
    guard let found = read(kAXChildrenAttribute) as? [AXUIElement] else {
      return []
    }
    return found.map(LiveAXNode.init)
  }

  /// One attribute written as text, or nil when the element carries none.
  ///
  /// A boolean is asked for by its type before anything else, because a number and a boolean
  /// both bridge to `Bool` and a value of `1` would then read as `true`. A size, a point and a
  /// range carry no text a file can hold, so they read as nothing.
  private func text(_ name: String) -> String? {
    guard let value = read(name) else {
      return nil
    }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
      return value as? Bool == true ? "true" : "false"
    }
    if let number = value as? NSNumber {
      return number.stringValue
    }
    return value as? String
  }

  /// The value of one Accessibility attribute, or nil when the read fails.
  private func read(_ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }
}
