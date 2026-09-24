/// The values a flag carries, each one held to the scale Logic shows.
///
/// A value refuses what the design system does not allow, so a command line that asks for a
/// velocity of 128 stops here, before anything reaches Logic. The types are plain Swift: this
/// module knows nothing about the command line library, and the conformance that lets the parser
/// read one sits in the executable beside the option groups.

/// How loud a note is, 1 to 127.
public struct Velocity: Sendable, Equatable {
  /// What the design system allows.
  public static let range = 1...127

  public let value: Int

  public init?(_ value: Int) {
    guard Velocity.range.contains(value) else { return nil }
    self.value = value
  }

  public init?(text: String) {
    guard let number = Int(text) else { return nil }
    self.init(number)
  }
}

/// A point on the fader scale of Logic, 0 to 127, where 90 is 0 dB.
public struct AutomationValue: Sendable, Equatable {
  /// What the design system allows.
  public static let range = 0...127

  public let value: Int

  public init?(_ value: Int) {
    guard AutomationValue.range.contains(value) else { return nil }
    self.value = value
  }

  public init?(text: String) {
    guard let number = Int(text) else { return nil }
    self.init(number)
  }
}

/// How far a quantize moves a note, 0 to 100.
public struct QuantizeStrength: Sendable, Equatable {
  /// What the design system allows.
  public static let range = 0...100

  public let value: Int

  public init?(_ value: Int) {
    guard QuantizeStrength.range.contains(value) else { return nil }
    self.value = value
  }

  public init?(text: String) {
    guard let number = Int(text) else { return nil }
    self.init(number)
  }
}

/// The grid a quantize snaps to. The design system lists these eleven and no other.
public enum QuantizeValue: String, Sendable, Equatable, CaseIterable {
  case whole = "1/1"
  case half = "1/2"
  case quarter = "1/4"
  case eighth = "1/8"
  case sixteenth = "1/16"
  case thirtySecond = "1/32"
  case sixtyFourth = "1/64"
  case quarterTriplet = "1/4t"
  case eighthTriplet = "1/8t"
  case sixteenthTriplet = "1/16t"
  case thirtySecondTriplet = "1/32t"
}

/// A length of time a flag carries, written with its unit: `500ms` or `5s`.
///
/// It is kept in milliseconds, because that is the unit the journal writes and the waits count in.
public struct DurationValue: Sendable, Equatable {
  /// The units the design system allows, longest first, so `ms` is read before `s`.
  public static let units = ["ms", "s"]

  public let milliseconds: Int

  public init(milliseconds: Int) {
    self.milliseconds = milliseconds
  }

  /// Reads `500ms` or `5s`. Text with another unit, with no unit, or with a number that is not a
  /// whole count of the unit, is refused.
  public init?(text: String) {
    if text.hasSuffix("ms") {
      guard let number = Int(text.dropLast(2)), number >= 0 else { return nil }
      self.init(milliseconds: number)
    } else if text.hasSuffix("s") {
      guard let number = Int(text.dropLast(1)), number >= 0 else { return nil }
      self.init(milliseconds: number * 1000)
    } else {
      return nil
    }
  }

  /// A length in seconds, for the limit a wait starts with.
  public static func seconds(_ count: Int) -> DurationValue {
    DurationValue(milliseconds: count * 1000)
  }
}

/// A position a person counts from 1, the way Logic shows it: a track, a region, a note, a point.
public struct OneBasedIndex: Sendable, Equatable {
  public let value: Int

  public init?(_ value: Int) {
    guard value >= 1 else { return nil }
    self.value = value
  }

  public init?(text: String) {
    guard let number = Int(text) else { return nil }
    self.init(number)
  }
}
