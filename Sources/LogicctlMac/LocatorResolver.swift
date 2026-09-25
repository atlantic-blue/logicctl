import LogicctlCore

/// Finds the one element a locator names, in a tree that Logic or a recorded file answers with.
///
/// The walk takes one step at a time: it reads the identifier of the step first, then the title,
/// then the index, and what it finds is where the next step looks. A step that matches nothing
/// stops the walk, and so does a step that matches more than one element. A walk that took the
/// first of several would press a button nobody named, and no later read could tell that it
/// happened.
public enum LocatorResolver {
  /// Why the walk stopped, and where.
  ///
  /// The name of the locator goes out with the failure, because that is the whole address a
  /// caller has: a person reading `element_not_found` needs to know which walk Logic refused,
  /// and a path that moves in a later Logic is found by that name in `Locators.swift`.
  public struct Refusal: Error, Equatable, Sendable {
    /// The name of the locator the walk was following.
    public let locator: String

    /// Which step of the path stopped the walk, counted from 0.
    public let step: Int

    /// How many elements that step matched. Anything other than one stops the walk.
    public let matched: Int

    public init(locator: String, step: Int, matched: Int) {
      self.locator = locator
      self.step = step
      self.matched = matched
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(
        code: .elementNotFound,
        message: sentence,
        details: .object([
          "locatorName": .string(locator),
          "step": .number(Double(step)),
          "matched": .number(Double(matched)),
        ]))
    }

    /// One sentence a person can act on.
    private var sentence: String {
      if matched == 0 {
        return "the locator \(locator) found no element at step \(step) of its path"
      }
      return "the locator \(locator) found \(matched) elements at step \(step) of its path"
    }
  }

  /// The one element the locator names, in the tree that starts at this element.
  ///
  /// The first step of the path names the element the tree starts at, and every step after it
  /// names one element under the step before it.
  public static func element(of locator: Locator, in root: any AXNode) throws -> any AXNode {
    var candidates: [any AXNode] = [root]
    var found: (any AXNode)?
    for (number, step) in locator.path.enumerated() {
      let matched = LocatorResolver.elements(of: step, among: candidates)
      guard matched.count == 1, let one = matched.first else {
        throw Refusal(locator: locator.name, step: number, matched: matched.count)
      }
      found = one
      candidates = one.children
    }
    guard let element = found else {
      throw Refusal(locator: locator.name, step: 0, matched: 0)
    }
    return element
  }

  /// The elements of a list that one step names.
  ///
  /// The role goes first and every element of another role is left out, which is also what the
  /// index counts in: Logic puts elements of other roles beside the one a step names, and a count
  /// of every child moves as soon as it does.
  private static func elements(of step: LocatorStep, among nodes: [any AXNode]) -> [any AXNode] {
    let ofTheRole = nodes.filter { $0.role == step.role }
    if let identifier = step.identifier {
      return ofTheRole.filter { $0.identifier == identifier }
    }
    if let title = step.title {
      return ofTheRole.filter { $0.title == title }
    }
    guard let index = step.index else {
      return ofTheRole
    }
    guard index >= 0, index < ofTheRole.count else {
      return []
    }
    return [ofTheRole[index]]
  }
}
