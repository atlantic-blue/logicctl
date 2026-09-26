import Foundation
import LogicctlCore
import LogicctlJournal
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// What one run of a command line wrote, on each channel, and the number it exited with.
private struct Answer {
  let out: String
  let err: String
  let status: Int32

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// The failure the answer carries, or an empty object when it carries none.
  func failure() throws -> [String: Any] {
    try printed()["error"] as? [String: Any] ?? [:]
  }
}

/// Runs one whole command line, the way a person types it.
///
/// The arguments go in as text and nothing is built by hand, because the refusal this proves comes
/// from the parser and a test that built a command would walk around it.
private func logicctl(_ arguments: [String]) -> Answer {
  var out = ""
  var err = ""
  let status = Logicctl.run(
    arguments: arguments,
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A quantize carries a grid, and a grid Logic does not offer must stop before Logic hears of it.
///
/// Logic applies a quantize to every note that is selected. A command that carried `1/3` to the
/// Time Quantize popup would either set a grid nobody asked for, or leave the popup on whatever
/// the last person left it on, and then press the button. The notes move either way, the answer
/// reads as though the command worked, and no later read of the region shows what happened,
/// because the notes sit on a grid in both cases. The only place this can be caught is before the
/// command talks to Logic, so `1/3` stops at the flag with `invalid_argument` and exit 2.
///
/// The first line is what holds the proof honest. An unknown subcommand is also `invalid_argument`
/// and also exit 2, so a check of the code alone reads green on a logicctl that has no `quantize`
/// at all. The same command line with `1/16` parses, which says the refusal underneath came from
/// the value and from nothing else.
@Test func quantizeRefusesAValueLogicDoesNotOffer() throws {
  #expect(
    throws: Never.self,
    "1/16 is one of the eleven values, so this line names a command logicctl has"
  ) {
    try Logicctl.parseAsRoot([
      "midi", "quantize", "--track", "4", "--region", "1", "--value", "1/16", "--strength", "100",
    ])
  }

  let answer = logicctl([
    "midi", "quantize", "--track", "4", "--region", "1", "--value", "1/3", "--strength", "100",
  ])

  let failure = try answer.failure()
  #expect(failure["code"] as? String == "invalid_argument", "a wrong flag is refused as one")
  #expect(answer.status == 2, "the number the design system gives invalid_argument")
  #expect(try answer.printed()["data"] is NSNull, "a failure carries no data")

  let message = failure["message"] as? String ?? ""
  #expect(message.contains("--value"), "the refusal names the flag that was wrong")
  #expect(message.contains("1/3"), "the refusal names the value that was refused")

  let lines = answer.err.split(whereSeparator: \.isNewline)
  #expect(lines.count == 1, "standard error carries one line for the person reading along")
  #expect(
    answer.err.hasPrefix("logicctl: invalid_argument: "),
    "the one line reads logicctl: <code>: <message>")
}

/// The version of Logic every recorded tree came from.
private let recordedVersion = "12.3.1"

/// Where the recorded trees sit. They are read from the source tree, because the folder sits beside
/// the test targets rather than inside one.
private let recordedTrees = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "Fixtures/logic-\(recordedVersion)")

/// One element of a tree this test builds around the recorded ones.
///
/// Nothing of the Piano Roll is built here. This is what holds the two recorded windows under one
/// application, the way Logic answers both at once, and what carries a note row whose position has
/// been moved.
private struct Element: AXNode {
  var role: String
  var title: String?
  var identifier: String?
  var value: String?
  var valueDescription: String?
  var description: String?
  var help: String?
  var actions: [String] = []
  var children: [any AXNode] = []
}

/// One recorded window, read from the tree `inspect` wrote.
private func recorded(_ tree: String) throws -> any AXNode {
  try RecordedTree(contentsOf: recordedTrees.appending(path: tree)).root
}

/// The same element with other children under it.
private func copied(_ node: any AXNode, children: [any AXNode]) -> Element {
  Element(
    role: node.role,
    title: node.title,
    identifier: node.identifier,
    value: node.value,
    valueDescription: node.valueDescription,
    description: node.description,
    help: node.help,
    actions: node.actions,
    children: children)
}

/// What one cell of an Event List row says, read the way the reader of the notes reads it.
private func text(of row: any AXNode, cell: Int) -> String {
  let cells = row.children.filter { $0.role == "AXCell" }
  guard cell < cells.count, let element = cells[cell].children.first else {
    return ""
  }
  return (element.description ?? "").trimmingCharacters(in: .whitespaces)
}

/// The same row with the note at another position.
private func moved(_ row: any AXNode, to position: String) -> any AXNode {
  var ordinal = -1
  let children = row.children.map { child -> any AXNode in
    guard child.role == "AXCell" else { return child }
    ordinal += 1
    guard ordinal == 2, let first = child.children.first else { return child }
    var written = copied(first, children: first.children)
    written.description = position
    let rest: [any AXNode] = Array(child.children.dropFirst())
    let cells: [any AXNode] = [written] + rest
    return copied(child, children: cells)
  }
  return copied(row, children: children)
}

/// The Event List of the same region before the quantize.
///
/// Every note sits off the grid, and nothing else about the row changes: the pitch, the velocity,
/// the length, the channel and the three fader rows are the ones Logic recorded. The four
/// positions are written here, because no tree of these notes before a quantize was recorded. They
/// are the only part of either window this test wrote.
private func offTheGrid(_ window: any AXNode, positions: [String]) -> any AXNode {
  var taken = 0
  func rebuilt(_ node: any AXNode) -> any AXNode {
    if node.role == "AXRow", text(of: node, cell: 3) == EventList.noteStatus,
      taken < positions.count
    {
      let position = positions[taken]
      taken += 1
      return moved(node, to: position)
    }
    return copied(node, children: node.children.map(rebuilt))
  }
  return rebuilt(window)
}

/// A Logic that shows the Piano Roll and the Event List of one region, and quantizes when the
/// Time Quantize button is pressed.
///
/// It takes every change the command asks for and moves nothing of its own: the press is the one
/// thing that changes what it answers, and what it answers after the press is the tree Logic
/// recorded once the four notes were on the grid. A change asked for in the wrong place therefore
/// reaches nothing, which is what makes the two sliders that read as `Strength` tell each other
/// apart here.
private final class AFakeLogic {
  private let pianoRoll: any AXNode
  private let before: any AXNode
  private let after: any AXNode

  /// What the command asked Logic to do, in order.
  private(set) var did: [String] = []

  /// What was selected in the Piano Roll, as Logic describes each note.
  private(set) var selected: [String] = []

  /// Every text written into the Time Quantize popup.
  private(set) var written: [String] = []

  /// Every number written at a slider.
  private(set) var slider: [Int] = []

  /// What was pressed, as Logic describes it.
  private(set) var pressed: [String] = []

  /// True once the Time Quantize button was pressed.
  private var quantized = false

  init(pianoRoll: any AXNode, before: any AXNode, after: any AXNode) {
    self.pianoRoll = pianoRoll
    self.before = before
    self.after = after
  }

  /// The windows Logic is showing.
  var tree: LogicTree {
    LogicTree(
      logicVersion: recordedVersion,
      root: Element(
        role: "AXApplication",
        children: [pianoRoll, quantized ? after : before]))
  }

  /// What the command drives Logic through.
  var actions: PianoRoll {
    PianoRoll(
      select: { notes in
        self.did.append("select")
        self.selected = notes.map { $0.description ?? "" }
      },
      choose: { _, text in
        self.did.append("choose")
        self.written.append(text)
      },
      press: { element in
        self.did.append("press")
        self.pressed.append(element.description ?? "")
        self.quantized = true
      },
      stepper: { slider in
        SliderStepper(
          read: { Int(slider.value ?? "") ?? -1 },
          write: { self.slider.append($0) },
          act: { _ in self.slider.append(SliderStepper.stepOfAnAction) })
      })
  }
}

/// A project of one track that carries one region, which is what `--track 4 --region 1` names.
private func aProjectWithARegionOnTrack4() -> [Track] {
  [
    Track(
      index: 4,
      name: "Studio Grand",
      type: .softwareInstrument,
      regions: [Region(index: 1, name: "MIDI Region", start: "1 bar", end: "3 bars")])
  ]
}

/// A git that signs, pointed at a configuration of its own.
///
/// The `--confirm` half of the guard writes a real session repository, and a session repository
/// turns signing off for itself. So no test reads or writes the configuration of the operator.
private func gitThatSigns(inside folder: URL) throws -> Git {
  let configuration = folder.appendingPathComponent("gitconfig")
  let written = """
    [commit]
    \tgpgsign = true
    [gpg]
    \tprogram = /usr/bin/false
    """
  try Data(written.utf8).write(to: configuration, options: .atomic)
  return Git(environment: [
    "GIT_CONFIG_GLOBAL": configuration.path,
    "GIT_CONFIG_SYSTEM": "/dev/null",
  ])
}

/// A Mac that takes no picture of the window, which is every Mac the pipeline runs on.
private struct NoPictureOfTheWindow: WindowCapturer {
  struct TookNone: Error {}

  func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    throw TookNone()
  }
}

/// Runs `logicctl midi quantize` against a Logic of this test.
///
/// The arguments go in as text, so `--confirm` reaches the command the way a person types it and
/// not as a value a test handed over.
private func midiQuantize(
  _ arguments: [String],
  logic: AFakeLogic,
  path: String,
  root: URL,
  git: Git
) throws -> Answer {
  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot(["midi", "quantize"] + arguments)
  let quantize = try #require(typed as? Midi.Quantize)
  let status = quantize.answer(
    driver: FakeLogicDriver(tracks: aProjectWithARegionOnTrack4(), path: path),
    of: { logic.tree },
    confirmed: quantize.guarded.confirm,
    pianoRoll: logic.actions,
    root: root,
    git: git,
    capturer: NoPictureOfTheWindow(),
    standardOutput: { out += $0 },
    standardError: { err += $0 })
  return Answer(out: out, err: err, status: status)
}

/// A quantize is a change of timing, so it is the one thing about a note that may come back
/// different.
///
/// Logic applies an edit to every event that is selected, and it applies it as an offset. The
/// probe watched one edit of a single automation point move a second point and all four note
/// velocities by the same amount, because they were all still selected. So a quantize that
/// selected the wrong thing, or set the wrong slider of the four that sit beside the Time Quantize
/// button, moves what nobody asked to move. Two of those sliders are called `Strength` in the tree
/// and only their help text tells them apart, and a third reads as `Transpose` while it carries
/// the velocity.
///
/// The Piano Roll is the tree `inspect` recorded from Logic 12.3.1, and the Event List after the
/// change is the tree it recorded of the same four notes on the grid. The positions before the
/// change are the only numbers this test wrote.
@Test func quantizeLeavesEveryPitchAndVelocity() throws {
  let offGrid = ["1 1 1 38", "1 1 3 190", "1 3 1 45", "1 3 4 87"]
  let events = try recorded("event-list-automation.json")
  let logic = AFakeLogic(
    pianoRoll: try recorded("piano-roll.json"),
    before: offTheGrid(events, positions: offGrid),
    after: events)

  let before = try EventList.notes(in: try #require(EventList.window(of: logic.tree)))
  try #require(before.map(\.position) == offGrid, "the notes start off the grid")

  var out = ""
  var err = ""
  let typed = try Logicctl.parseAsRoot([
    "midi", "quantize", "--track", "4", "--region", "1", "--value", "1/16", "--strength", "100",
  ])
  let quantize = try #require(typed as? Midi.Quantize)
  let status = quantize.answer(
    driver: FakeLogicDriver(tracks: aProjectWithARegionOnTrack4()),
    of: { logic.tree },
    confirmed: quantize.guarded.confirm,
    pianoRoll: logic.actions,
    root: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-session"),
    standardOutput: { out += $0 },
    standardError: { err += $0 })

  let printed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] ?? [:]
  let data = printed["data"] as? [String: Any] ?? [:]
  let rows = data["notes"] as? [[String: Any]] ?? []
  try #require(rows.count == 4, "the region holds four notes, and the table holds three more rows")

  #expect(
    rows.map { $0["pitch"] as? Int } == before.map(\.pitch),
    "every pitch is the one the note had before the quantize")
  #expect(
    rows.map { $0["velocity"] as? Int } == before.map(\.velocity),
    "every velocity is the one the note had before the quantize")
  #expect(
    rows.map { $0["position"] as? String } == ["1 1 1 1", "1 1 4 1", "1 3 1 1", "1 3 4 1"],
    "every note moved onto the grid Logic shows")

  #expect(
    logic.selected == [
      "Note at 1 bar , C3",
      "Note at 1 bar 4 divisions , D3",
      "Note at 1 bar 3 beats , E3",
      "Note at 1 bar 3 beats 4 divisions , F3",
    ],
    "every note of the Piano Roll is selected, and nothing else is")
  #expect(logic.written == ["1/16 Note"], "the grid Logic shows for 1/16 is written into the popup")
  #expect(logic.slider == [], "the Strength slider already reads 100, so nothing is written at it")
  #expect(logic.pressed == ["Time Quantize"], "the button that quantizes is the one pressed")
  #expect(
    logic.did == ["select", "choose", "press"],
    "the press comes last, because Logic quantizes what the popup holds when it is pressed")
  #expect(status == 0, "the command exits 0")
  #expect(err == "", "standard error stays empty when a command worked")
}

/// A person opens a project they wrote themselves, and an agent asks logicctl to quantize a region
/// of it.
///
/// The timing of that music is their work, and a quantize is the widest edit of the three this
/// tool makes to a region: `midi note` and `midi velocity` each change one event, and this one
/// moves every note that is selected at once. It cannot be read back afterwards either. Once the
/// notes sit on the grid, no later read of the region says where they were, so a person who did
/// not ask for it has lost the feel of the part and has nothing to compare against.
///
/// So logicctl does not quantize a project of a person on its own word. The agent reads
/// `confirm_required` and exit 7, nothing is selected, nothing is written into the Time Quantize
/// popup, the button is not pressed, and all four notes sit where the person left them. The person
/// then says `--confirm`, and the same command moves the same four notes onto the grid.
///
/// Both halves are here against one project, because a refusal on its own also reads green on a
/// logicctl that refuses every quantize. The second half says the guard is what stopped the first.
@Test func quantizeNeedsConfirmOnAProjectLogicctlDidNotMake() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-quantize-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let git = try gitThatSigns(inside: root)
  let theirProject = root.appending(path: "The Work Of A Person.logicx").path

  let offGrid = ["1 1 1 38", "1 1 3 190", "1 3 1 45", "1 3 4 87"]
  let events = try recorded("event-list-automation.json")
  let arguments = ["--track", "4", "--region", "1", "--value", "1/16", "--strength", "100"]

  let theirs = AFakeLogic(
    pianoRoll: try recorded("piano-roll.json"),
    before: offTheGrid(events, positions: offGrid),
    after: events)

  let refused = try midiQuantize(arguments, logic: theirs, path: theirProject, root: root, git: git)

  #expect(refused.status == 7, "the number the design system gives confirm_required")
  #expect(
    try refused.failure()["code"] as? String == "confirm_required",
    "logicctl did not make this project")
  #expect(try refused.printed()["data"] is NSNull, "a command that stopped answers nothing")
  #expect(
    theirs.did.isEmpty,
    "nothing was selected, nothing was written into the popup, and nothing was pressed")

  let kept = try EventList.notes(in: try #require(EventList.window(of: theirs.tree)))
  #expect(
    kept.map(\.position) == offGrid, "every note of the person sits where they left it")

  let allowed = AFakeLogic(
    pianoRoll: try recorded("piano-roll.json"),
    before: offTheGrid(events, positions: offGrid),
    after: events)

  let said = try midiQuantize(
    arguments + ["--confirm"], logic: allowed, path: theirProject, root: root, git: git)

  #expect(said.status == 0, "the person said --confirm, so the same command goes through")
  let notes = try said.printed()["data"] as? [String: Any] ?? [:]
  let rows = notes["notes"] as? [[String: Any]] ?? []
  #expect(
    rows.map { $0["position"] as? String } == ["1 1 1 1", "1 1 4 1", "1 3 1 1", "1 3 4 1"],
    "the four notes moved onto the grid")
  #expect(allowed.pressed == ["Time Quantize"], "the button that quantizes was pressed")
}
