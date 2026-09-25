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

  private let readTree: TreeRead
  private let readStatus: StatusRead
  private let readName: NameRead
  private let readPath: PathRead
  private let readTempo: TempoRead
  private let readSaveTime: SaveTimeRead

  public init(
    tree: @escaping TreeRead,
    status: @escaping StatusRead,
    name: @escaping NameRead,
    path: @escaping PathRead,
    tempo: @escaping TempoRead = TempoField.readTheLogicOfThisMac,
    saveTime: @escaping SaveTimeRead = StateReader.saveTime(ofProjectAt:)
  ) {
    readTree = tree
    readStatus = status
    readName = name
    readPath = path
    readTempo = tempo
    readSaveTime = saveTime
  }

  /// The state of the project Logic has open, built from one walk of the tree.
  ///
  /// The state of the last step comes in, because the plugins of a track are read from the Mixer,
  /// and Logic shows the Mixer only while a person keeps it open. logicctl opens no window to
  /// read, so a track whose strip this walk cannot see keeps the plugins the last state gave it,
  /// and the difference between the two states reports no plugin change from that read.
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
    let tracks = try TrackReader.tracks(in: project.root).map { track -> Track in
      var read = track
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
      tempo: TempoField.readTheLogicOfThisMac)
  }
}
