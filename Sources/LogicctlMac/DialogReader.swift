import ApplicationServices
import Foundation
import LogicctlCore

/// Reads the window Logic waits on, and what it says.
///
/// Logic takes nothing else while a dialog is open, so a command asks for one after its action.
/// logicctl presses no button in it. The text and the buttons are the whole of what the person
/// gets back, so they have to be enough to see what Logic asked, and which answers it offers,
/// without opening Logic to look.
///
/// Which window is modal is a closure the caller gives. Accessibility carries that as an attribute
/// of the live window, and `inspect` writes no such flag, so a recorded tree alone cannot say which
/// window Logic waits on. The closure is where the two part. The live one reads `AXModal`, as the
/// input gate reads it before it sends an event, and a test gives its own and drives the same walk
/// with no Logic.
public struct DialogReader {
  /// Answers true for a window that holds Logic until a person answers it.
  public typealias ModalReader = (any AXNode) -> Bool

  /// The roles an element carries when it is a window of its own.
  ///
  /// The question about the tempo of a MIDI file reads as `AXWindow` and carries the dialog in its
  /// subrole. A sheet carries its own role, and hangs off the window it belongs to.
  public static let windowRoles = ["AXWindow", "AXSheet", "AXDialog"]

  /// The role of an element that carries words a person reads.
  public static let textRole = "AXStaticText"

  /// The role of an element a person presses to answer.
  public static let buttonRole = "AXButton"

  /// Reads whether Logic waits on one window.
  private let isModal: ModalReader

  public init(modal: @escaping ModalReader) {
    isModal = modal
  }

  /// The window Logic waits on in one tree, or nothing when it waits on none.
  ///
  /// It answers the first modal window, with or without a title: the question about the tempo of a
  /// MIDI file carries no title at all.
  public func dialog(in root: any AXNode) -> ModalDialog? {
    guard let window = DialogReader.windows(of: root).first(where: isModal) else {
      return nil
    }
    let parts = DialogReader.elements(under: window)
    let said = parts.filter { $0.role == DialogReader.textRole }.compactMap { _ -> String? in nil }
    let answers = parts.filter { $0.role == DialogReader.buttonRole }
      .compactMap { $0.title }
      .filter { !$0.isEmpty }
    return ModalDialog(text: said.joined(separator: "\n"), buttons: answers)
  }

  /// Every window of a tree, in the order they read.
  ///
  /// A level at a time, so the windows of the application come before anything one of them holds,
  /// and a sheet comes after the window it sits on. A recorded tree that starts at the window
  /// itself answers that one window, which is how a dialog is recorded on this Mac.
  static func windows(of root: any AXNode) -> [any AXNode] {
    var found: [any AXNode] = []
    var level: [any AXNode] = [root]
    while !level.isEmpty {
      found += level.filter { windowRoles.contains($0.role) }
      level = level.flatMap { $0.children }
    }
    return found
  }

  /// Everything one window holds, in the order the tree reads, and nothing a window of its own
  /// holds. A sheet on a window is a second question, and its words are not the words of this one.
  static func elements(under window: any AXNode) -> [any AXNode] {
    window.children.flatMap { child -> [any AXNode] in
      guard !windowRoles.contains(child.role) else {
        return []
      }
      return [child] + elements(under: child)
    }
  }

  /// What one element of text says, or nothing when it says nothing.
  ///
  /// Logic writes the words of a dialog into the value. An element that carries its words in the
  /// title instead still reads, because a line of the question that reached nobody is a line the
  /// person answers without.
  static func text(of element: any AXNode) -> String? {
    for carried in [element.value, element.title] {
      if let carried, !carried.isEmpty {
        return carried
      }
    }
    return nil
  }
}

extension DialogReader {
  /// The reader that asks the Logic of this Mac which of its windows it waits on.
  ///
  /// The pipeline has no Logic, so no test there drives this closure. It reads what `InputGate`
  /// reads before it sends an event, because the window that refuses the gate is the window this
  /// answers.
  public static func live() -> DialogReader {
    DialogReader(modal: DialogReader.theLogicOfThisMacWaitsOn)
  }

  /// True when Logic holds everything until a person answers this window.
  ///
  /// A sheet is read by its role as well, because a sheet takes the window it sits on whether or
  /// not Accessibility marks it modal. A recorded window is neither, and answers false: a file
  /// carries no flag, and a walk of a file must not make a dialog out of one.
  static func theLogicOfThisMacWaitsOn(_ window: any AXNode) -> Bool {
    guard let live = window as? LiveAXNode else {
      return false
    }
    if attribute(named: kAXModalAttribute, of: live.element) as? Bool == true {
      return true
    }
    return window.role == kAXSheetRole
  }
}

/// The value of one Accessibility attribute, or nil when the read fails.
private func attribute(named name: String, of element: AXUIElement) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}
