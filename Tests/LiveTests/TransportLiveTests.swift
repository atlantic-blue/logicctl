import Foundation
import Testing

/// This file, read as text.
///
/// The acceptance of a phase is a run on a Mac with Logic on it, and the pipeline has neither. So
/// the pipeline reads the file the acceptance is written in, the way the phase 0 step reads the
/// Makefile, and it answers the one question it can answer from here: would this acceptance report
/// a pass while a command of the phase never drove anything.
private let liveFile = URL(fileURLWithPath: #filePath)

/// One live scenario of phase 3: the name it carries, and the command it drives.
private struct PhaseThreeScenario {
  /// The name of the scenario. It prints this name itself, and `make accept` counts the line.
  let name: String

  /// The words of the command the scenario gives logicctl.
  let command: [String]
}

/// The live scenarios of phase 3, in the order a person walks the phase.
///
/// The order is the order of the stories: find the bus, move the transport, record into it, set
/// the tempo, write a file and import it. A scenario later in this list reads what an earlier one
/// left, so the list is the flow and not a set.
private let phaseThreeScenarios: [PhaseThreeScenario] = [
  PhaseThreeScenario(name: "setupFindsTheBusOnThisMac", command: ["midi", "setup"]),
  PhaseThreeScenario(name: "playStartsTheTransport", command: ["transport", "play"]),
  PhaseThreeScenario(name: "stopStopsTheTransport", command: ["transport", "stop"]),
  PhaseThreeScenario(name: "recordTakesTheNotesIntoARegion", command: ["transport", "record"]),
  PhaseThreeScenario(name: "tempoSetsTheTempoOfTheProject", command: ["transport", "tempo"]),
  PhaseThreeScenario(name: "writeFileGivesTheStoredBytes", command: ["midi", "write-file"]),
  PhaseThreeScenario(name: "importPutsTheFileOnANewTrack", command: ["midi", "import"]),
]

/// Phase 3 is accepted when every command of it moved the real Logic on this Mac.
///
/// The pipeline proves each of these commands against a tree that `inspect` recorded from Logic
/// 12.3.1. A recorded tree says nothing about whether Logic still answers a Machine Control
/// message, still shows the tempo field where it was, or still makes a track for an imported file.
/// `make accept PART=3` is where the running application answers, and the output of that run, with
/// the picture of the tempo field, is the proof of this step.
///
/// That run needs a Mac, and this check has none. What it can do is refuse an acceptance that
/// would report a pass while a command of the phase drove nothing: a phase 3 with a command
/// missing, a scenario that prints the name of another scenario so the count reads high, a suite
/// that runs in the pipeline where there is no Logic, or a run that works on the project of a
/// person rather than a copy.
@Test func phaseThreeAgainstLogic() throws {
  let source = try String(contentsOf: liveFile, encoding: .utf8)

  #expect(
    source.contains("struct Phase3LiveScenarios"),
    "make accept PART=3 filters on Phase3LiveScenarios, and this file declares no such suite")
  #expect(
    source.contains("@Suite(.serialized, .enabled(if: LiveHarness.runsLive()))"),
    "the suite is off unless a person set LOGICCTL_LIVE to 1, and it drives the one Logic alone")
  #expect(
    source.contains("LiveHarness.copyOfTheScratchProject"),
    "the phase works on a copy in a temporary folder, never on the project of a person")

  var readSoFar = source.startIndex
  for scenario in phaseThreeScenarios {
    let declaration = "@Test func \(scenario.name)("
    guard let starts = source.range(of: declaration, range: readSoFar..<source.endIndex) else {
      Issue.record(
        """
        phase 3 drives \(scenario.command.joined(separator: " ")), and no scenario named \
        \(scenario.name) comes after the one before it. An acceptance with this command missing \
        reports a pass for a command that never ran.
        """)
      continue
    }
    readSoFar = starts.upperBound

    let body = source[starts.upperBound..<(nextScenario(in: source, after: starts.upperBound))]
    #expect(
      body.contains("LiveHarness.liveScenario(\"\(scenario.name)\")"),
      """
      \(scenario.name) prints no line of its own, or prints the name of another scenario. \
      make accept counts those lines, so the count would read high for a scenario that never ran.
      """)
    for word in scenario.command {
      #expect(
        body.contains("\"\(word)\""),
        "\(scenario.name) never gives logicctl \(scenario.command.joined(separator: " "))")
    }
  }
}

/// Where the scenario that starts at this point ends, which is where the next one starts.
private func nextScenario(in source: String, after point: String.Index) -> String.Index {
  source.range(of: "@Test func ", range: point..<source.endIndex)?.lowerBound ?? source.endIndex
}
