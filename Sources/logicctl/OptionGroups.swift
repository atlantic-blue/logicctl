import ArgumentParser
import LogicctlCore

/// The flags that repeat, each one written once.
///
/// A command holds the groups it needs, so `--track` means the same thing in every command that
/// takes a track, and a journal reads the same as the documentation. Flags are long and in kebab
/// case, and every index counts from 1, the way Logic counts.

extension Velocity: @retroactive ExpressibleByArgument {
  public init?(argument: String) {
    self.init(text: argument)
  }
}

extension AutomationValue: @retroactive ExpressibleByArgument {
  public init?(argument: String) {
    self.init(text: argument)
  }
}

extension QuantizeStrength: @retroactive ExpressibleByArgument {
  public init?(argument: String) {
    self.init(text: argument)
  }
}

extension QuantizeValue: @retroactive ExpressibleByArgument {
  public init?(argument: String) {
    self.init(rawValue: argument)
  }
}

extension DurationValue: @retroactive ExpressibleByArgument {
  public init?(argument: String) {
    self.init(text: argument)
  }

  /// How a default reads in the help text, in the unit the value is kept in.
  public var defaultValueDescription: String {
    "\(milliseconds)ms"
  }
}

extension OneBasedIndex: @retroactive ExpressibleByArgument {
  public init?(argument: String) {
    self.init(text: argument)
  }
}

/// `--index <n>`, for the `tracks` commands, where the noun already says it is a track.
struct TrackIndexOption: ParsableArguments {
  @Option(help: "The track, counted from 1.")
  var index: OneBasedIndex
}

/// `--track <n>`, for every other noun, for example `plugins list --track 1`.
struct TrackOption: ParsableArguments {
  @Option(help: "The track, counted from 1.")
  var track: OneBasedIndex
}

/// `--track <n> --region <n>`, for every MIDI edit and every automation command.
struct RegionOption: ParsableArguments {
  @Option(help: "The track, counted from 1.")
  var track: OneBasedIndex

  @Option(help: "The region on the track, counted from the left, from 1.")
  var region: OneBasedIndex
}

/// `--note <n>`, a note of the region in time order.
struct NoteOption: ParsableArguments {
  @Option(help: "The note of the region, in time order, from 1.")
  var note: OneBasedIndex
}

/// `--point <n>`, an automation point of the region in time order.
struct PointOption: ParsableArguments {
  @Option(help: "The automation point of the region, in time order, from 1.")
  var point: OneBasedIndex
}

/// `--on` or `--off`, exactly one.
///
/// A state is set and never toggled, so a session gives the same result whatever the track was
/// doing when it started. A command given neither flag, or both, is refused before it runs.
struct ToggleOption: ParsableArguments {
  @Flag(help: "Turn it on.")
  var on = false

  @Flag(help: "Turn it off.")
  var off = false

  /// The state the flags ask for.
  func state() throws -> Bool {
    guard on != off else {
      throw ValidationError("Give exactly one of --on and --off.")
    }
    return on
  }

  func validate() throws {
    _ = try state()
  }
}

/// `--confirm`, the only way past a guard. No environment variable does the same.
struct ConfirmOption: ParsableArguments {
  @Flag(help: "Go ahead with a change that is guarded.")
  var confirm = false
}

/// `--pretty`, which lays the one JSON object out over several lines for a person to read.
struct OutputOption: ParsableArguments {
  @Flag(help: "Indent the answer by two spaces.")
  var pretty = false

  /// How the envelope of this command is laid out.
  var format: OutputFormat {
    pretty ? .pretty : .compact
  }
}

/// `--timeout <duration>`, which sets the limit of every wait in the command.
struct TimeoutOption: ParsableArguments {
  @Option(help: "How long any wait in this command may take, for example 500ms or 5s.")
  var timeout: DurationValue = .seconds(5)
}
