import Foundation
import Testing

/// The route that runs one scenario on request, read from the repository.
private struct ProofRoute {
  let text: String

  init() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let raw = try String(
      contentsOf: root.appending(path: ".github/workflows/scenario.yml"),
      encoding: .utf8)
    text = ProofRoute.oneLine(raw)
  }

  /// True when the route carries this fragment, whatever it does with white space.
  func says(_ fragment: String) -> Bool {
    text.contains(ProofRoute.oneLine(fragment))
  }

  private static func oneLine(_ raw: String) -> String {
    raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

/// A person or an agent asks the pipeline for one scenario by name, and reads back a count of
/// what really ran.
///
/// This test is the scenario that route is asked for first, so the route is only green when a
/// real test ran. The count can only be trusted while three things hold: the name reaches the
/// run, the run tests that name alone, and a run that found nothing reports zero and fails.
@Test func aScenarioRunsOnRequest() throws {
  let route = try ProofRoute()

  #expect(route.says("workflow_dispatch:"), "a person asks for the run, it is not on a push")
  #expect(route.says("inputs: scenario:"), "the thing they ask for is one scenario")
  #expect(route.says("SCENARIO: ${{ inputs.scenario }}"), "the name they gave reaches the shell")
  #expect(route.says(#"swift test --filter "$SCENARIO""#), "that name alone is what runs")
  #expect(route.says(#"echo "scenarios: $count""#), "the count is the answer they read")
  #expect(route.says(#"if [ "$count" -eq 0 ]; then"#), "a run that counted nothing is refused")
  #expect(route.says("exit 1"), "and refused means the run goes red")
}
