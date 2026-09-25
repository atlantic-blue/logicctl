import CoreServices
import Foundation

/// What tells the watcher that a file under a folder changed.
///
/// The source sits behind this because a test must not wait on the file system of the machine that
/// runs it. A test gives a source of its own and reports whatever path it wants to report, and the
/// one place that talks to macOS is `FileSystemEvents` below it.
public protocol FileChangeSource: AnyObject, Sendable {
  /// Reports every file that changes under those folders, until `stop`.
  func start(watching folders: [URL], report: @escaping @Sendable (String) -> Void) throws

  /// Stops reporting.
  func stop()
}

/// Where a saved project keeps the file that carries the work.
///
/// Logic writes a project as a folder: `<name>.logicx/Alternatives/<n>/ProjectData`. A project
/// carries more than one alternative, and a save writes the one that is open, so the watcher
/// watches the whole project and reads whichever `ProjectData` changed.
public enum SavedProject {
  /// The name of the file that carries the work of one alternative.
  public static let dataFileName = "ProjectData"

  /// The name of the folder that holds the alternatives of a project.
  public static let alternativesFolderName = "Alternatives"

  /// The folder to watch for one project.
  public static func folderToWatch(ofProjectAt path: String) -> URL {
    URL(fileURLWithPath: path)
  }

  /// True when a changed file is the work of a project rather than something beside it.
  ///
  /// A save writes more than this one file, and an autosave writes a folder of its own under the
  /// alternative. Recording every one of those as a save would fill a history with steps a person
  /// never made, so one save is one change of one `ProjectData`.
  public static func isSaveOfAProject(path: String) -> Bool {
    projectPath(ofDataAt: path) != nil
  }

  /// The project that a changed file belongs to, or nothing when the file is not the work of a
  /// project.
  public static func projectPath(ofDataAt path: String) -> String? {
    var parts = URL(fileURLWithPath: path).pathComponents
    guard parts.last == dataFileName else {
      return nil
    }
    parts.removeLast()
    guard let alternatives = parts.lastIndex(of: alternativesFolderName) else {
      return nil
    }
    let kept = parts[..<alternatives].dropFirst()
    guard !kept.isEmpty else {
      return nil
    }
    return "/" + kept.joined(separator: "/")
  }
}

/// The file system events of macOS, which is how a save made in Logic reaches logicctl.
///
/// Logic writes a save through a new file and a rename, so watching one file by its descriptor
/// would follow the file that the save replaced. The events of a folder carry the rename, and they
/// carry it for every project the watcher holds, through one stream.
public final class FileSystemEvents: FileChangeSource, @unchecked Sendable {
  /// What starting a watch can refuse.
  public enum Refusal: Error, Equatable {
    /// macOS gave no stream for those folders.
    case couldNotWatch(folders: [String])

    /// The stream was made and macOS would not start it.
    case couldNotStart(folders: [String])
  }

  /// How long macOS may gather changes before it reports them, in seconds. A save writes several
  /// files, and a gathered report is one wake of this process rather than a dozen.
  public static let defaultLatencySeconds = 0.2

  /// How long macOS may gather changes before it reports them, in seconds.
  public let latencySeconds: Double

  /// Where the reports arrive.
  private let queue = DispatchQueue(label: "com.atlantic-blue.logicctl.watch.events")

  /// Keeps the stream and the reader of the two threads apart: this one and the one macOS
  /// reports on.
  private let guardian = NSLock()

  /// The stream while it runs.
  private var stream: FSEventStreamRef?

  /// Who is told about a change.
  private var report: (@Sendable (String) -> Void)?

  public init(latencySeconds: Double = FileSystemEvents.defaultLatencySeconds) {
    self.latencySeconds = latencySeconds
  }

  deinit {
    stop()
  }

  /// Starts one stream over every folder, and replaces the stream that ran before it.
  public func start(watching folders: [URL], report: @escaping @Sendable (String) -> Void) throws {
    stop()
    guard !folders.isEmpty else {
      return
    }
    guardian.lock()
    self.report = report
    guardian.unlock()

    let paths = folders.map(\.path)
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil)
    // The callback is a plain C function, so it carries nothing of its own. What it needs comes
    // back through the pointer in the context above.
    let callback: FSEventStreamCallback = { _, info, count, changed, _, _ in
      guard let info, count > 0 else {
        return
      }
      let events = Unmanaged<FileSystemEvents>.fromOpaque(info).takeUnretainedValue()
      guard let carried = unsafeBitCast(changed, to: NSArray.self) as? [String] else {
        return
      }
      for path in carried {
        events.changed(path)
      }
    }
    let made = withUnsafeMutablePointer(to: &context) { pointer in
      FSEventStreamCreate(
        nil,
        callback,
        pointer,
        paths as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latencySeconds,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer))
    }
    guard let made else {
      throw Refusal.couldNotWatch(folders: paths)
    }
    FSEventStreamSetDispatchQueue(made, queue)
    guard FSEventStreamStart(made) else {
      FSEventStreamInvalidate(made)
      FSEventStreamRelease(made)
      throw Refusal.couldNotStart(folders: paths)
    }
    guardian.lock()
    stream = made
    guardian.unlock()
  }

  /// Stops the stream and takes it away. Stopping twice is not a failure.
  public func stop() {
    guardian.lock()
    let held = stream
    stream = nil
    report = nil
    guardian.unlock()
    guard let held else {
      return
    }
    FSEventStreamStop(held)
    FSEventStreamInvalidate(held)
    FSEventStreamRelease(held)
  }

  /// Tells whoever asked for the watch about one changed file.
  private func changed(_ path: String) {
    guardian.lock()
    let told = report
    guardian.unlock()
    told?(path)
  }
}
