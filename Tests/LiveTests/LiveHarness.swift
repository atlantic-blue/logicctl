import AppKit
import Foundation
import LogicctlCore
import LogicctlMac
import Testing

/// The root of the repository, found from this file.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

/// Drives the real Logic on this Mac, on a copy of a project and never on a project of a person.
///
/// An acceptance run is the only part of logicctl that opens Logic, changes a project and saves
/// it. The music folder is where a person keeps their own work, so the harness copies a scratch
/// project into a folder of its own and works there. It resolves every link in a path first,
/// because a link is how a path under the music folder reaches the suite looking like a path that
/// is not.
///
/// Every scenario reads Logic through the signed binary and not through this process. macOS keys
/// the Accessibility grant and the Screen Recording grant on the signature of the binary, so the
/// test binary that `swift test` builds carries neither grant, whatever this Mac granted logicctl
/// (story S0.2). A scenario that called the same Swift code in this process would read `false` for
/// both grants and report it as a Mac that granted nothing.
enum LiveHarness {
  /// The variable that turns a live run on. Anything other than `1` leaves the scenarios out.
  static let liveVariable = "LOGICCTL_LIVE"

  /// The variable that names the scratch project this Mac lends the suite, a `.logicx` folder.
  static let scratchVariable = "LOGICCTL_SCRATCH_PROJECT"

  /// The variable that names the signed binary. `make accept` sets it.
  static let binaryVariable = "LOGICCTL_BINARY"

  /// Where the signed binary sits when nothing names it.
  static let binaryByDefault = ".build/release/logicctl"

  /// How long the harness waits for Logic to show the copy, in milliseconds.
  ///
  /// Logic starts, reads the project and draws its window. That is minutes on a cold start of a
  /// large project, and seconds on a warm one, so the limit is far past the slow case: it is there
  /// to end a run that will never finish, not to measure anything.
  static let openLimitMs = 180_000

  /// How long the harness leaves between two reads of Logic, in milliseconds.
  static let pollMs = 500

  /// The version of Logic this suite drives.
  static let logicVersion = "12.3.1"

  /// Whether this run drives the real Logic.
  ///
  /// The pipeline has no Logic and no grant, and it runs the whole suite on every pull request. So
  /// a live scenario runs on this Mac, where a person set the variable, and nowhere else.
  static func runsLive(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment[liveVariable] == "1"
  }

  /// Says on the output of the run that one live scenario is about to drive Logic.
  ///
  /// `make accept` counts these lines. The summary of the test runner counts a scenario that was
  /// left out as a test that ran, so a phase where every scenario was skipped reads there as 92
  /// tests becoming 97: the two live scenarios are in the total and neither one drove anything.
  /// A scenario prints this line itself, so a line can only come from a scenario that ran.
  static func liveScenario(_ name: String) {
    print("live scenario: \(name)")
  }

  /// What the harness refuses to do, and what the operator does about it.
  enum Refusal: Error, CustomStringConvertible {
    /// The project named is under the music folder, so it is the work of a person.
    case theProjectIsUnderTheMusicFolder(String)

    /// The copy would land under the music folder, which is the same damage the other way round.
    case theCopyWouldBeUnderTheMusicFolder(String)

    /// The variable that names the scratch project carries nothing.
    case theVariableIsEmpty(String)

    /// The project named is not on this Mac.
    case theProjectIsNotThere(String)

    /// The signed binary is not where the run looked for it.
    case theBinaryIsNotThere(String)

    /// macOS refused to open the copy.
    case theCopyDidNotOpen(String)

    /// Logic shows a modal window, so the suite stops and a person answers it.
    case aModalWindowIsOpen(String)

    /// Logic never showed the window of the copy.
    case logicDidNotShowTheCopy(name: String, seen: String, waitedMs: Int)

    /// logicctl answered with a failure.
    case logicctlRefused(command: String, code: String, message: String)

    /// logicctl printed something no envelope reads back.
    case logicctlPrintedNothingToReadBack(command: String, printed: String)

    var description: String {
      switch self {
      case .theProjectIsUnderTheMusicFolder(let path):
        return """
          the live suite works on a copy, and \(path) is under the music folder of this Mac, \
          where a person keeps their own projects
          """
      case .theCopyWouldBeUnderTheMusicFolder(let path):
        return """
          the copy would land at \(path), under the music folder of this Mac, so the run stops \
          before it writes anything
          """
      case .theVariableIsEmpty(let variable):
        return "set \(variable) to the .logicx folder the live suite may copy, and run it again"
      case .theProjectIsNotThere(let path):
        return "\(path) is not on this Mac"
      case .theBinaryIsNotThere(let path):
        return "\(path) is not there, so run make sign and then run this again"
      case .theCopyDidNotOpen(let path):
        return "macOS did not open \(path) in Logic"
      case .aModalWindowIsOpen(let name):
        return "Logic shows the window \(name), which a person answers. logicctl presses nothing"
      case .logicDidNotShowTheCopy(let name, let seen, let waitedMs):
        return "Logic did not show \(name) within \(waitedMs)ms. Its windows read \(seen)"
      case .logicctlRefused(let command, let code, let message):
        return "logicctl \(command) failed with \(code): \(message)"
      case .logicctlPrintedNothingToReadBack(let command, let printed):
        return "logicctl \(command) printed no envelope this suite reads back: \(printed)"
      }
    }
  }

  /// The music folder of this Mac, where a person keeps their own projects.
  static var musicFolder: URL {
    FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music")
  }

  /// The path with every link in it resolved, and the parts that are not there yet kept.
  ///
  /// `resolvingSymlinksInPath` answers for a path that is there. A run names a copy that nothing
  /// wrote yet, and a project through a link to a folder, so the harness resolves the deepest part
  /// of the path that exists and puts the rest back on the end. A link that is read as plain text
  /// would let a project under the music folder through under another name, which is the one thing
  /// this suite must never do.
  static func resolved(_ url: URL) -> URL {
    var missing: [String] = []
    var walk = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: walk.path) {
      let parent = walk.deletingLastPathComponent()
      guard parent.path != walk.path else {
        break
      }
      missing.insert(walk.lastPathComponent, at: 0)
      walk = parent
    }
    var found = walk.resolvingSymlinksInPath()
    for part in missing {
      found = found.appending(path: part)
    }
    return found
  }

  /// Whether one path sits in a folder, or is the folder itself. Both are links resolved first.
  static func isUnder(_ folder: URL, _ path: URL) -> Bool {
    let root = resolved(folder).pathComponents
    let under = resolved(path).pathComponents
    guard under.count >= root.count else {
      return false
    }
    return Array(under.prefix(root.count)) == root
  }

  /// A folder of its own for one run, under the temporary folder of this Mac.
  static func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "logicctl-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// The scratch project this Mac lends the suite.
  static func scratchProject(
    in environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    let named = environment[scratchVariable] ?? ""
    guard !named.isEmpty else {
      throw Refusal.theVariableIsEmpty(scratchVariable)
    }
    let project = resolved(URL(fileURLWithPath: named))
    guard FileManager.default.fileExists(atPath: project.path) else {
      throw Refusal.theProjectIsNotThere(project.path)
    }
    return project
  }

  /// A copy of the scratch project, in a folder the run owns.
  ///
  /// The refusal comes before the copy, in both directions: a project under the music folder is
  /// not read, and a copy that would land there is not written.
  static func copy(
    _ source: URL,
    into folder: URL,
    musicFolder: URL = LiveHarness.musicFolder,
    fileManager: FileManager = .default
  ) throws -> URL {
    let project = resolved(source)
    let destination = resolved(folder)
    let copy = destination.appending(path: project.lastPathComponent)

    guard !isUnder(musicFolder, project) else {
      throw Refusal.theProjectIsUnderTheMusicFolder(project.path)
    }
    guard !isUnder(musicFolder, copy) else {
      throw Refusal.theCopyWouldBeUnderTheMusicFolder(copy.path)
    }
    guard fileManager.fileExists(atPath: project.path) else {
      throw Refusal.theProjectIsNotThere(project.path)
    }

    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    try fileManager.copyItem(at: project, to: copy)
    return copy
  }

  /// A copy of the scratch project this Mac lends the suite, in a folder the run owns.
  static func copyOfTheScratchProject(into folder: URL) throws -> URL {
    try copy(scratchProject(), into: folder)
  }

  /// What one run of logicctl printed, and the number it exited with.
  struct Answer {
    /// The number the process exited with.
    let status: Int32

    /// The envelope, on standard output.
    let printed: String

    /// The one line of standard error, on a failure.
    let complained: String
  }

  /// The envelope logicctl printed, read as the shape the caller asked for.
  struct Envelope<Answered: Decodable>: Decodable {
    /// What the command answered, or nothing when it failed.
    let data: Answered?

    /// Why the command failed, or nothing when it did not.
    let error: Refused?
  }

  /// The failure an envelope carries.
  struct Refused: Decodable {
    /// The code of the design system, for example `logic_not_running`.
    let code: String

    /// The line a person reads.
    let message: String
  }

  /// What `permissions` answers.
  struct GrantsAnswer: Decodable {
    /// Whether this Mac lets logicctl read the interface of Logic and drive it.
    let accessibility: Bool

    /// Whether this Mac lets logicctl take a picture of the window of Logic.
    let screenRecording: Bool
  }

  /// The signed binary the scenarios drive.
  static func signedBinary(
    in environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    let named = environment[binaryVariable] ?? ""
    let binary =
      named.isEmpty
      ? repositoryRoot.appending(path: binaryByDefault) : URL(fileURLWithPath: named)
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      throw Refusal.theBinaryIsNotThere(binary.path)
    }
    return binary
  }

  /// Runs the signed logicctl with these arguments and answers what it printed.
  static func logicctl(_ arguments: [String]) throws -> Answer {
    let process = Process()
    process.executableURL = try signedBinary()
    process.arguments = arguments

    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let printed = output.fileHandleForReading.readDataToEndOfFile()
    let complained = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return Answer(
      status: process.terminationStatus,
      printed: String(decoding: printed, as: UTF8.self),
      complained: String(decoding: complained, as: UTF8.self))
  }

  /// Runs logicctl and reads the data of its envelope.
  ///
  /// A command that failed throws with the code and the message it printed, because a scenario
  /// that read the failure as an empty answer would pass on a Mac where nothing worked.
  static func read<Answered: Decodable>(
    _ shape: Answered.Type,
    from arguments: [String]
  ) throws -> Answered {
    let command = arguments.joined(separator: " ")
    let answer = try logicctl(arguments)
    let carried = try envelope(shape, of: answer, from: command)
    guard let data = carried.data else {
      throw Refusal.logicctlRefused(
        command: command,
        code: carried.error?.code ?? "no code",
        message: carried.error?.message ?? answer.complained)
    }
    return data
  }

  /// The envelope of one answer, whichever way the command went.
  static func envelope<Answered: Decodable>(
    _ shape: Answered.Type,
    of answer: Answer,
    from command: String
  ) throws -> Envelope<Answered> {
    guard let bytes = answer.printed.data(using: .utf8) else {
      throw Refusal.logicctlPrintedNothingToReadBack(command: command, printed: answer.printed)
    }
    do {
      return try JSONDecoder().decode(Envelope<Answered>.self, from: bytes)
    } catch {
      throw Refusal.logicctlPrintedNothingToReadBack(command: command, printed: answer.printed)
    }
  }

  /// The tree of the Logic that runs now, or nothing when no Logic runs.
  static func treeOfLogic(depth: Int = 3) throws -> RecordedTree? {
    let arguments = ["inspect", "--depth", String(depth)]
    let answer = try logicctl(arguments)
    let carried = try envelope(
      RecordedTree.self, of: answer, from: arguments.joined(separator: " "))
    if let tree = carried.data {
      return tree
    }
    guard let error = carried.error else {
      throw Refusal.logicctlPrintedNothingToReadBack(
        command: arguments.joined(separator: " "), printed: answer.printed)
    }
    guard error.code == "logic_not_running" else {
      throw Refusal.logicctlRefused(
        command: arguments.joined(separator: " "), code: error.code, message: error.message)
    }
    return nil
  }

  /// The modal windows of Logic, by the name each one shows.
  ///
  /// A sheet is the shape Logic gives a question it wants answered before anything else: a save,
  /// an export, an alert on the document. The tree carries the role of every element, so a sheet
  /// is the one the harness reads by name. A window of its own is not one of these: Logic opens
  /// the window of a plugin in front of the project, nothing waits on an answer to it, and every
  /// read of logicctl works while it is open.
  static func modalWindows(in tree: RecordedTree) -> [String] {
    sheets(under: tree.root)
  }

  /// The title of every window of Logic, in the order the tree lists them.
  ///
  /// A window Logic gave no title reads as an empty line rather than dropping out, so the count
  /// here is the number of windows Logic has.
  static func windowTitles(in tree: RecordedTree) -> [String] {
    windowTitles(under: tree.root)
  }

  /// Whether Logic is showing the project of this run, in any one of its windows.
  ///
  /// Logic titles the window of a project `<name>.logicx - <the view>`, so the name of the copy is
  /// the start of that title and never the whole of it.
  static func showsTheProject(named name: String, in tree: RecordedTree) -> Bool {
    windowTitles(in: tree).contains { $0.hasPrefix(name) }
  }

  /// The windows of Logic on one line, so a refusal says what it saw.
  static func whatTheWindowsRead(in tree: RecordedTree) -> String {
    let named = windowTitles(in: tree).filter { !$0.isEmpty }
    return named.isEmpty ? "no window" : named.joined(separator: ", ")
  }

  /// Opens a project in Logic and waits until Logic shows it.
  ///
  /// It presses nothing. A modal window that is open before the run, and one that Logic puts up
  /// while the project opens, both stop the scenario and name the window. A person answers it in
  /// Logic, and runs the suite again.
  ///
  /// The wait reads every window of Logic, and it ends as soon as one of them is the copy. Logic
  /// puts the window of a plugin in front of a project it opens, and that window is not modal, so
  /// a wait on the front window alone waits for a project Logic is already showing.
  static func openInLogic(_ project: URL) throws {
    let name = project.deletingPathExtension().lastPathComponent

    if let tree = try treeOfLogic(), let modal = modalWindows(in: tree).first {
      throw Refusal.aModalWindowIsOpen(modal)
    }

    guard NSWorkspace.shared.open(project) else {
      throw Refusal.theCopyDidNotOpen(project.path)
    }

    var seen = "no window"
    do {
      try Wait.until(limitMs: openLimitMs, pollMs: pollMs) {
        guard let tree = try treeOfLogic() else {
          seen = "no Logic"
          return false
        }
        if let modal = modalWindows(in: tree).first {
          throw Refusal.aModalWindowIsOpen(modal)
        }
        seen = whatTheWindowsRead(in: tree)
        return showsTheProject(named: name, in: tree)
      }
    } catch let ranOut as Wait.RanOut {
      throw Refusal.logicDidNotShowTheCopy(name: name, seen: seen, waitedMs: ranOut.waitedMs)
    }
  }

  /// Every window under one element, in the order the tree lists them.
  ///
  /// It stops at a window, because the elements under one are what that window holds and never
  /// another window of Logic.
  private static func windowTitles(under node: RecordedAXNode) -> [String] {
    if node.role == "AXWindow" {
      return [node.title ?? ""]
    }
    return node.recordedChildren.flatMap { windowTitles(under: $0) }
  }

  /// Every sheet under one element, by the name it shows.
  private static func sheets(under node: RecordedAXNode) -> [String] {
    var found: [String] = []
    if node.role == "AXSheet" {
      found.append(node.title ?? node.role)
    }
    for child in node.recordedChildren {
      found += sheets(under: child)
    }
    return found
  }
}

/// An acceptance run never touches the work of a person.
///
/// The live suite is the one part of logicctl that drives the real Logic. It opens a project,
/// changes it and saves it. The music folder is where a person keeps their own projects, and a run
/// pointed at one of those damages work that no undo brings back, so the suite works on a copy in a
/// temporary folder and the harness refuses the music folder before it copies anything.
///
/// It refuses the path as it is written, and the path that reaches the folder through a link,
/// because a link is the way a path under the music folder arrives looking like a path that is
/// not. It refuses in the other direction too: a copy that would land under the music folder
/// writes there, which is the same damage. Each refusal names the path, so the operator reads
/// which one it was and changes the variable rather than the suite.
@Test func theLiveSuiteRefusesAProjectUnderMusic() throws {
  let folder = try LiveHarness.temporaryFolder()
  defer { try? FileManager.default.removeItem(at: folder) }

  let destination = folder.appending(path: "copy")
  try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

  let music = LiveHarness.musicFolder
  let project = music.appending(path: "Logic/Sketch.logicx")
  let named = refusal(copying: project, into: destination)
  #expect(
    refusedTheMusicFolder(named, naming: LiveHarness.resolved(project).path),
    "the project of a person is refused for where it sits: \(describe(named))")

  let link = folder.appending(path: "music")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: music)
  let throughALink = link.appending(path: "Logic/Sketch.logicx")
  let linked = refusal(copying: throughALink, into: destination)
  #expect(
    refusedTheMusicFolder(linked, naming: LiveHarness.resolved(music).path),
    "the same project through a link is the same project: \(describe(linked))")

  let scratch = folder.appending(path: "Scratch.logicx")
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  let intoTheMusicFolder = music.appending(path: "logicctl-live")
  let written = refusal(copying: scratch, into: intoTheMusicFolder)
  #expect(
    refusedTheMusicFolder(written, naming: LiveHarness.resolved(intoTheMusicFolder).path),
    "a copy is never written there either: \(describe(written))")

  let left = try FileManager.default.contentsOfDirectory(atPath: destination.path)
  #expect(left.isEmpty, "a refusal copies nothing, and this folder holds \(left)")
  #expect(
    FileManager.default.fileExists(atPath: intoTheMusicFolder.path) == false,
    "and it writes nothing into the music folder of this Mac")
}

/// What stopped the harness from copying one project, or nothing when it copied it.
private func refusal(copying source: URL, into folder: URL) -> Error? {
  do {
    _ = try LiveHarness.copy(source, into: folder)
    return nil
  } catch {
    return error
  }
}

/// Whether the harness refused this path for being under the music folder, and named it.
///
/// The reason is read and not only the path, because every other refusal of the harness names a
/// path as well. A harness that copied whatever it was given would refuse a project that is not
/// there, name the same path in that refusal, and read here as a harness that guarded the music
/// folder.
private func refusedTheMusicFolder(_ error: Error?, naming path: String) -> Bool {
  let refused: String
  switch error as? LiveHarness.Refusal {
  case .theProjectIsUnderTheMusicFolder(let named):
    refused = named
  case .theCopyWouldBeUnderTheMusicFolder(let named):
    refused = named
  default:
    return false
  }
  return refused == path || refused.hasPrefix("\(path)/")
}

/// What the harness answered, in words a failure can print.
private func describe(_ error: Error?) -> String {
  guard let error else {
    return "it copied the project"
  }
  return String(describing: error)
}

/// A live scenario runs on this Mac, and nowhere else.
///
/// The pipeline builds this target and runs it on every pull request, with no Logic, no project
/// and no grant. A scenario that ran there would drive nothing and report a pass, so the whole
/// live suite is left out unless a person turns it on with the variable.
@Test func aLiveScenarioRunsOnlyWithTheVariableSet() {
  #expect(LiveHarness.runsLive([:]) == false, "a run that names nothing is not a live run")
  #expect(LiveHarness.runsLive(["LOGICCTL_LIVE": "0"]) == false)
  #expect(LiveHarness.runsLive(["LOGICCTL_LIVE": "true"]) == false, "the value is 1, and only 1")
  #expect(LiveHarness.runsLive(["LOGICCTL_LIVE": "1"]))
}

/// The suite waits for the copy wherever Logic puts its window, and not only in front.
///
/// Measured on this Mac at 13:50 on 2026-09-26 (Logic 12.3.1): opening the copy F-T3b also opened
/// the plugin window `Deluxe Classic`, and Logic put that window in front of the project. The
/// windows read `Deluxe Classic, F-T3b.logicx - Tracks`. Five of the seven scenarios of phase 3
/// then waited the whole 180082ms and failed, on a Logic that was showing the copy all along.
///
/// A plugin window is not modal, and every read of logicctl works while one is open, so it is no
/// reason to stop. A sheet is, and that check stays as it is. So the suite gets on with the
/// scenario as soon as one window of Logic is the copy. When it does give up, it names every
/// window it saw, because the one title it used to print is the title that says least.
@Test func theHarnessFindsTheCopyBehindAPluginWindow() throws {
  let behindAPlugin = try logicShowing(["Deluxe Classic", "F-T3b.logicx - Tracks"])
  let thePluginAlone = try logicShowing(["Deluxe Classic"])

  #expect(
    LiveHarness.showsTheProject(named: "F-T3b", in: behindAPlugin),
    "Logic has F-T3b open behind the plugin window, so the scenario runs now and waits no longer")
  #expect(
    LiveHarness.showsTheProject(named: "F-T3b", in: thePluginAlone) == false,
    "and a Logic with no window of the copy is not showing it")

  let gaveUpOnBoth = gaveUp(on: "F-T3b", whileLogicShowed: behindAPlugin)
  #expect(
    gaveUpOnBoth.contains("Deluxe Classic") && gaveUpOnBoth.contains("F-T3b.logicx - Tracks"),
    "a refusal names every window Logic had: \(gaveUpOnBoth)")

  let gaveUpOnThePlugin = gaveUp(on: "F-T3b", whileLogicShowed: thePluginAlone)
  #expect(
    gaveUpOnThePlugin.contains("Deluxe Classic"),
    "and a Logic that showed one window names that one: \(gaveUpOnThePlugin)")
}

/// A tree of a Logic that shows these windows, in the order Logic lists them.
private func logicShowing(_ titles: [String]) throws -> RecordedTree {
  let windows = titles
    .map { "{ \"role\": \"AXWindow\", \"title\": \"\($0)\", \"actions\": [\"AXRaise\"] }" }
    .joined(separator: ", ")
  let text = """
    {
      "logicVersion": "\(LiveHarness.logicVersion)",
      "root": {
        "role": "AXApplication",
        "title": "Logic Pro",
        "children": [\(windows)]
      }
    }
    """
  return try JSONDecoder().decode(RecordedTree.self, from: Data(text.utf8))
}

/// What the harness tells the operator when it gives up while Logic shows this tree.
private func gaveUp(on name: String, whileLogicShowed tree: RecordedTree) -> String {
  let refused = LiveHarness.Refusal.logicDidNotShowTheCopy(
    name: name,
    seen: LiveHarness.whatTheWindowsRead(in: tree),
    waitedMs: LiveHarness.openLimitMs)
  return String(describing: refused)
}

/// What one run of make printed, on both channels, and the status it ended with.
private struct MakeRun {
  /// The number make exited with.
  let status: Int32

  /// Everything it printed.
  let text: String
}

/// Runs one target of the Makefile at the root, with these variables on the command line.
private func make(_ arguments: [String]) throws -> MakeRun {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["make"] + arguments
  process.currentDirectoryURL = repositoryRoot

  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  let printed = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()

  return MakeRun(status: process.terminationStatus, text: String(decoding: printed, as: UTF8.self))
}

/// The text of the Makefile at the root, on one line, whatever it does with white space.
private func makefile() throws -> String {
  let raw = try String(contentsOf: repositoryRoot.appending(path: "Makefile"), encoding: .utf8)
  return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// An acceptance run that proves nothing says so, instead of reporting a pass.
///
/// `make accept` is how a person runs the live suite, one phase of the stories at a time. Three
/// runs prove nothing and all three look like a clean run from the outside: a phase nobody wrote
/// scenarios for, a name that matches no scenario, and a phase whose scenarios were all left out
/// because the live suite was off. The last one is the trap: the summary of the test runner counts
/// a scenario it left out as a test that ran, so the two live scenarios of phase 0 took a green
/// pipeline from 92 tests to 97 while neither one drove anything.
///
/// So the target counts the line each scenario prints as it starts, it refuses a count of zero,
/// and it refuses a run that left any scenario out. It refuses a phase that is not one of the five
/// before it starts anything. It turns the live suite on itself, so nobody has to remember the
/// variable. It builds nothing and signs nothing: the grants key on the signature, so a build here
/// would hand the suite a binary this Mac granted nothing to.
@Test func theAcceptTargetRefusesARunThatProvesNothing() throws {
  let unnamed = try make(["accept"])
  #expect(unnamed.status != 0, "a run that names no phase stops, so nothing reads it as a pass")
  #expect(unnamed.text.contains("PART"), "and it names the variable a person sets: \(unnamed.text)")

  let notAPhase = try make(["accept", "PART=9"])
  #expect(notAPhase.status != 0, "9 is not a phase of the stories, so there is nothing to run")
  #expect(
    notAPhase.text.contains("0 to 4"), "and it says which phases there are: \(notAPhase.text)")
  #expect(
    notAPhase.text.contains("Test run with") == false,
    "the refusal comes first, so no test runs: \(notAPhase.text)")

  let target = try makefile()
  #expect(
    target.contains("LOGICCTL_LIVE=1"),
    "the target turns the live suite on, so a person never runs it by hand")
  #expect(
    target.contains("live scenario: "),
    "it counts the line a scenario prints as it starts, which only a scenario that ran can print")
  #expect(
    target.contains("Test run with") == false,
    "and never the summary of the runner, which counts a scenario it left out")
  #expect(
    target.contains("scenarios: $$ran"), "it prints that count, because the count is the evidence")
  #expect(
    target.contains("no live scenario ran"),
    "a count of zero ends the run, whatever swift said about it")
  #expect(
    target.contains("is not accepted"),
    "and so does a run that left a scenario of the phase out")
}
