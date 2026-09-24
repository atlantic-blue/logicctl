import LogicctlCore

/// One behaviour every `LogicDriver` must show, whichever Logic sits behind it.
public struct ConformanceCase: Sendable {
  /// What the case proves, in words, for the report of a live run.
  public let name: String

  private let check: @Sendable (any LogicDriver, State) throws -> Void

  public init(name: String, check: @escaping @Sendable (any LogicDriver, State) throws -> Void) {
    self.name = name
    self.check = check
  }

  /// Run the case against one driver, told the state that driver was set up with. The fake is set
  /// up with a state in memory. The real driver is set up by opening that project in Logic.
  public func run(against driver: any LogicDriver, holding state: State) throws {
    do {
      try check(driver, state)
    } catch let failure as ConformanceFailure {
      throw ConformanceFailure("\(name): \(failure.reason)")
    }
  }
}

/// What a case throws when a driver does not show the behaviour.
public struct ConformanceFailure: Error, CustomStringConvertible, Sendable {
  /// What the driver did instead.
  public let reason: String

  public init(_ reason: String) {
    self.reason = reason
  }

  public var description: String {
    reason
  }
}

/// The suite every driver passes: the fake in the pipeline, the real driver on this Mac.
///
/// A case asks the driver for nothing the protocol does not carry, so one case reads both. Later
/// steps add one case each.
public enum Conformance {
  /// Every case, in the order a live run reads them.
  public static var cases: [ConformanceCase] { [readsBackItsState] }

  /// A driver answers the project that is open. Every command reads Logic through this one call,
  /// so a driver that answers something else lets a command act on a project nobody has.
  public static var readsBackItsState: ConformanceCase {
    ConformanceCase(name: "reads back the state it was given") { driver, state in
      let read = try driver.readState()
      guard read == state else {
        throw ConformanceFailure("the driver answered a state other than the one it holds")
      }
    }
  }

  /// A project with one track, the smallest project a case can read.
  public static var aProjectWithOneTrack: State {
    State(
      logic: LogicVersion(version: "12.3.1"),
      project: Project(name: "Untitled"),
      transport: Transport(tempo: 120),
      tracks: [Track(index: 1, name: "Inst 1", type: .softwareInstrument)])
  }
}
