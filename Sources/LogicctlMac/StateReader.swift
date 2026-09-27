import ApplicationServices
import Foundation
import LogicctlCore

/// Builds the whole state of the project Logic has open, from one walk of its tree.
///
/// Every command reads the state before it acts and again after it, and the journal keeps both, so
/// this read is the only record of what Logic held at each step. It joins the readers that came
/// before it: the status for the version, the project reader for the name and the path, the
/// transport reader, the track reader, the region reader and the channel strip.
///
/// Every read is a closure the caller gives, as they are for `ProjectReader` and for
/// `DialogReader`. The pipeline has no Logic, so a test drives the same walk over a tree that
/// `inspect` recorded from Logic 12.3.1.
public struct StateReader {
  /// Why the reader could not build a state at all.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// One short reason a person can act on.
    public let reason: String

    /// The code a caller reads and exits with.
    public let code: ErrorCode

    /// The locator the read asked for, or nothing where the refusal names none.
    public let locator: String?

    public init(reason: String, code: ErrorCode = .elementNotFound, locator: String? = nil) {
      self.reason = reason
      self.code = code
      self.locator = locator
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(
        code: code, message: reason,
        details: locator.map { JSONValue.object(["locator": .string($0)]) })
    }
  }

  /// The tree of the Logic that runs. It refuses where no Logic runs.
  public typealias TreeRead = () throws -> LogicTree

  /// What Logic is doing, which is where the version of the state comes from.
  public typealias StatusRead = () throws -> LogicStatus

  /// What the project Logic has open is called, or nothing when the window names no project.
  public typealias NameRead = () throws -> String?

  /// Where the project sits, or nothing when Logic never saved it.
  public typealias PathRead = () throws -> String?

  /// The tempo of the project, in beats per minute.
  public typealias TempoRead = () throws -> Int

  /// When the project at one path was last saved, or nothing when nothing was saved there.
  public typealias SaveTimeRead = (String) -> Date?

  /// Opens the Mixer of the project Logic has open. It refuses where nothing can open one.
  public typealias MixerOpen = () throws -> Void

  /// Closes the Mixer this reader opened.
  public typealias MixerClose = () throws -> Void

  private let readTree: TreeRead
  private let readStatus: StatusRead
  private let readName: NameRead
  private let readPath: PathRead
  private let readTempo: TempoRead
  private let readSaveTime: SaveTimeRead
  private let openMixer: MixerOpen
  private let closeMixer: MixerClose

  public init(
    tree: @escaping TreeRead,
    status: @escaping StatusRead,
    name: @escaping NameRead,
    path: @escaping PathRead,
    tempo: @escaping TempoRead = TempoField.readTheLogicOfThisMac,
    saveTime: @escaping SaveTimeRead = StateReader.saveTime(ofProjectAt:),
    openMixer: MixerOpen? = nil,
    closeMixer: MixerClose? = nil
  ) {
    readTree = tree
    readStatus = status
    readName = name
    readPath = path
    readTempo = tempo
    readSaveTime = saveTime
    self.openMixer = openMixer ?? StateReader.noMixerOpenWasGiven
    self.closeMixer = closeMixer ?? StateReader.noMixerCloseWasGiven
  }

  /// What a caller that gave no way to open the Mixer gets when the reader asks for one.
  ///
  /// Each one refuses rather than doing nothing. An open that quietly went nowhere would leave
  /// the reader waiting for a window that nobody asked Logic for.
  private static func noMixerOpenWasGiven() throws {
    throw Refusal(
      reason: "No way to open the Mixer was given, so nothing could open it.",
      code: .internalFailure)
  }

  /// What a caller that gave no way to close the Mixer gets when the reader asks for one.
  private static func noMixerCloseWasGiven() throws {
    throw Refusal(
      reason: "No way to close the Mixer was given, so nothing could close it.",
      code: .internalFailure)
  }

  /// The state of the project Logic has open, built from one walk of the tree.
  ///
  /// The kind of a track is in the Mixer and nowhere else, so a read that found no Mixer opens
  /// one, walks the tree again, and closes it afterwards. A Mixer a person already had open stays
  /// open, because a command must not take a window away from them. A Mixer that will not open
  /// leaves every kind at `other` rather than failing the read.
  ///
  /// The state of the last step comes in, because the plugins of a track are read from the Mixer
  /// as well, and those are read from the first walk alone. So a track whose strip that walk
  /// cannot see keeps the plugins the last state gave it, and the difference between the two
  /// states reports no plugin change from that read.
  public func state(after previous: State?) throws -> State {
    let tree = try readTree()
    guard let version = try readStatus().version else {
      throw DriverRefusal.logicNotRunning
    }
    guard let project = tree.atTheProjectWindow() else {
      throw Refusal(
        reason: "Logic shows no window with the tracks of a project in it, so there is no "
          + "project to read. Open the Tracks window.",
        locator: Locators.mainWindow.name)
    }
    guard let name = try readName() else {
      throw Refusal(reason: "The window of Logic names no project, so there is no state to read.")
    }
    let savedAt = try readPath().flatMap(readSaveTime)
    let transport = try TransportReader.transport(in: project.root, tempo: readTempo)
    let mixer = ChannelStrip.window(of: tree)
    var shown = mixer
    var opened = false
    if shown == nil {
      opened = (try? openMixer()) != nil
      if opened, let again = try? readTree() {
        shown = ChannelStrip.window(of: again)
      }
    }
    defer {
      if opened {
        try? closeMixer()
      }
    }
    let tracks = try TrackReader.tracks(in: project.root).map { track -> Track in
      var read = track
      read.type = kind(of: track, in: shown)
      read.regions = RegionReader.regions(ofTrack: track.index, in: project.root)
      read.plugins = plugins(of: track, in: mixer, after: previous)
      return read
    }
    return State(
      logic: LogicVersion(version: version),
      project: Project(name: name, savedAt: savedAt),
      transport: transport,
      tracks: tracks)
  }

  /// What kind of track the Mixer shows for one track, or `other` where no Mixer could be read.
  ///
  /// The strip of a track is found by its place, and the Mixer shows the strips of the tracks a
  /// person scrolled to, so a place can hold the strip of another track. That is not a reason to
  /// stop the command that is reading, and the kind of a track nobody can see is `other`.
  private func kind(of track: Track, in mixer: (any AXNode)?) -> Track.Kind {
    guard let mixer else {
      return .other
    }
    return TrackReader.type(ofTrackNumber: track.index, named: track.name, in: mixer)
  }

  /// The plugins of one track: what the Mixer shows for it, or what the last state gave it.
  ///
  /// The strip of a track is found by its place among the strips, and the Mixer shows the strips
  /// of the tracks a person scrolled to. So a place can hold the strip of another track, or hold
  /// nothing at all, and neither is a reason to stop the command that is reading. The plugins of
  /// the last state stand instead, and the plugin commands open the Mixer themselves.
  private func plugins(
    of track: Track, in mixer: (any AXNode)?, after previous: State?
  ) -> [Plugin] {
    guard let mixer,
      let read = try? ChannelStrip.plugins(
        ofTrackNumber: track.index, named: track.name, in: mixer)
    else {
      return StateReader.plugins(ofTrackNumber: track.index, in: previous)
    }
    return read
  }

  /// The plugins one track carried in the state of the last step, or none when that state held no
  /// track of that number.
  static func plugins(ofTrackNumber number: Int, in previous: State?) -> [Plugin] {
    previous?.tracks.first { $0.index == number }?.plugins ?? []
  }
}

extension StateReader {
  /// What Logic writes inside the project when a person saves it.
  ///
  /// An autosave writes into `Alternatives/000/Autosave/` and leaves this file alone, measured on
  /// Logic 12.3.1 on 2026-09-25, so this is the file that says when the project was last saved.
  public static let projectData = "Alternatives/000/ProjectData"

  /// When the project at one path was last saved, or nothing when nothing was saved there.
  public static func saveTime(ofProjectAt path: String) -> Date? {
    let file = URL(fileURLWithPath: path).appending(path: projectData)
    let read = try? FileManager.default.attributesOfItem(atPath: file.path)
    return read?[.modificationDate] as? Date
  }

  /// The reader over the Logic that runs on this Mac.
  ///
  /// Each read walks to the window again rather than holding one, because Logic builds its windows
  /// afresh as projects open and close, and a window read once is a handle to the window of that
  /// moment.
  public static func live() -> StateReader {
    let project = ProjectReader.live()
    let driver = AXDriver()
    return StateReader(
      tree: LogicTree.ofRunningLogic,
      status: driver.status,
      name: project.name,
      path: project.path,
      tempo: TempoField.readTheLogicOfThisMac,
      openMixer: StateReader.openTheMixerOfThisMac,
      closeMixer: StateReader.closeTheMixerOfThisMac)
  }

  /// The subrole of the button that closes a window. Accessibility names the three buttons of a
  /// title bar by subrole alone, and each one carries no title and no description.
  static let closeButtonSubrole = "AXCloseButton"

  /// Opens the Mixer of the Logic that runs, through the Window menu of its menu bar.
  ///
  /// Measured on this Mac on 2026-09-26 (Logic 12.3.1, a copy under /tmp): the Window menu holds
  /// an item titled `Open Mixer` while a project is open, and pressing it opens a window of its
  /// own, titled `<project>.logicx - Mixer: Tracks`. A press through Accessibility is not a mouse
  /// event, so it does not go through the input gate: it asks the one element the walk found to
  /// act on itself.
  ///
  /// Logic builds the window after the press answers, so this waits for the window to be there and
  /// gives up with `timeout` rather than letting the caller walk a tree that has not got it yet.
  /// No recorded tree holds a menu bar, so the live acceptance is what proves this walk.
  public static func openTheMixerOfThisMac() throws {
    try press(Locators.openMixer)
    try Wait.until {
      let tree = try LogicTree.ofRunningLogic()
      return ChannelStrip.window(of: tree) != nil
    }
  }

  /// Closes the Mixer of the Logic that runs, by pressing the close button of its window.
  ///
  /// A Mixer that is not there any more is closed already, so this answers rather than refusing: a
  /// person is free to close it themselves while a command runs.
  public static func closeTheMixerOfThisMac() throws {
    let tree = try LogicTree.ofRunningLogic()
    guard let window = ChannelStrip.window(of: tree) else {
      return
    }
    guard let button = StateReader.closeButton(of: window) else {
      throw Refusal(
        reason: "The Mixer window carries no close button, so it stays open.",
        code: .internalFailure, locator: Locators.mixerWindow.name)
    }
    try StateReader.press(button, called: "the close button of the Mixer")
  }

  /// The close button of one window, found by its subrole.
  ///
  /// `AXNode` carries no subrole, because `inspect` writes none and no recorded tree holds one.
  /// So this asks Accessibility itself, and a window of a recorded tree answers nothing.
  private static func closeButton(of window: any AXNode) -> LiveAXNode? {
    window.children.compactMap { $0 as? LiveAXNode }.first { node in
      var subrole: CFTypeRef?
      let answered = AXUIElementCopyAttributeValue(
        node.element, kAXSubroleAttribute as CFString, &subrole)
      guard answered == .success, let named = subrole as? String else {
        return false
      }
      return named == StateReader.closeButtonSubrole
    }
  }

  /// Presses the one element a locator names, in the tree of the Logic that runs.
  private static func press(_ locator: Locator) throws {
    let tree = try LogicTree.ofRunningLogic()
    let element = try LocatorResolver.element(of: locator, in: tree.root)
    guard let live = element as? LiveAXNode else {
      throw Refusal(
        reason: "\(locator.name) was found in a recorded tree, which nothing can press.",
        code: .internalFailure, locator: locator.name)
    }
    try StateReader.press(live, called: locator.name)
  }

  /// Asks one element of the running Logic to press itself.
  private static func press(_ node: LiveAXNode, called name: String) throws {
    let answered = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
    guard answered == .success else {
      throw Refusal(
        reason: "Logic refused the press of \(name), error \(answered.rawValue).",
        code: .internalFailure)
    }
  }
}
