/// One element of the Accessibility tree of Logic, as logicctl reads it.
///
/// Logic answers only through Accessibility, and the pipeline has no Logic. So every read a
/// driver makes goes through this protocol and not through an `AXUIElement`: `LiveAXNode` answers
/// from the running Logic, and `RecordedAXNode` answers from a tree that `inspect` wrote against
/// Logic 12.3.1. A step that walks the tree is proved in the pipeline against a recorded tree,
/// and the live suite on this Mac proves the same walk against Logic itself.
///
/// A node is not `Sendable`. The live one holds an `AXUIElement`, which belongs to the process
/// that read it.
public protocol AXNode {
  /// What kind of element this is, for example `AXButton` or `AXLayoutItem`. Every element
  /// carries a role.
  var role: String { get }

  /// The title Logic shows on the element, or nil when it shows none.
  var title: String? { get }

  /// The identifier of the element, or nil when it carries none. A locator reads this before the
  /// title, because a title moves with the language and with the project.
  var identifier: String? { get }

  /// What the element holds, written as text, or nil when it holds nothing a reader can write
  /// down.
  var value: String? { get }

  /// What the element holds, written the way Logic shows it on the screen, or nil when Logic
  /// shows no such text.
  ///
  /// A slider of the Event List carries its number here. Its `value` is a scaled 32 bit number,
  /// so the velocity of a note is read from this and from nothing else.
  var valueDescription: String? { get }

  /// What the element is for, in the words Accessibility carries. The plugin slot of a channel
  /// strip is found by this and by nothing else: its description reads `audio plug-in`.
  var description: String? { get }

  /// The help text of the element, or nil when it carries none. A region carries its borders
  /// here, for example "Region starts at 1 bar and ends at 2 bars".
  var help: String? { get }

  /// What the element can be asked to do, for example `AXPress`.
  var actions: [String] { get }

  /// The elements under this one, in the order Accessibility answers them.
  var children: [any AXNode] { get }
}
