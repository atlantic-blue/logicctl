import CoreGraphics
import Foundation

/// The picture of the window of Logic, taken by the `screencapture` tool of macOS.
///
/// macOS takes a picture of one window by the id of that window, so a capture reads the list of
/// windows on the screen first and keeps the ones the Logic process owns. A picture of the whole
/// screen would carry whatever else is open on this Mac into the history of a session, and a
/// person reading a step months later could not tell which part of it Logic drew. So the id is
/// looked up every time, and nothing is captured without one.
public struct WindowCapture {
  /// Why no picture was taken. The reason reaches the answer of the command, so a person reads
  /// what this Mac refused without going to look for a log.
  public struct Refusal: Error, Equatable, Sendable {
    /// One short reason, in the words of the Mac that refused.
    public let reason: String

    public init(reason: String) {
      self.reason = reason
    }
  }

  /// How long one capture may take, in seconds.
  public static let defaultLimitSeconds = 5.0

  /// How often the wait looks at the process again, in seconds.
  static let lookWaitSeconds = 0.01

  /// The tool that takes the picture.
  public var executable: URL

  /// How long one capture may take, in seconds.
  public var limitSeconds: Double

  public init(
    executable: URL = URL(fileURLWithPath: "/usr/sbin/screencapture"),
    limitSeconds: Double = WindowCapture.defaultLimitSeconds
  ) {
    self.executable = executable
    self.limitSeconds = limitSeconds
  }

  /// The bytes of a picture of the window of the Logic that runs as this process id.
  ///
  /// The picture is written to a file of its own and read back, because `screencapture` writes a
  /// file and answers nothing on its output. The file is removed afterwards: the bytes belong in
  /// the commit of the step and nowhere else.
  public func picture(ofLogicRunningAs processID: Int32) throws -> Data {
    let window = try WindowCapture.windowID(
      ownedBy: processID, in: WindowCapture.windowsOnTheScreen())
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("logicctl-capture-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: file) }

    try take(window, into: file)
    guard let bytes = try? Data(contentsOf: file), !bytes.isEmpty else {
      throw Refusal(reason: "screencapture wrote no picture of window \(window)")
    }
    return bytes
  }

  /// The window of Logic to photograph: the largest window the process owns that a person can
  /// see. Logic carries panels, tooltips and menus above its main window, and each of those is a
  /// window of the same process, so the largest one at the level of a normal window is the one a
  /// person means by "the window of Logic".
  static func windowID(ownedBy processID: Int32, in windows: [[String: Any]]) throws -> CGWindowID {
    let owned = windows.filter {
      number(of: $0, at: kCGWindowOwnerPID) == Int(processID)
        && number(of: $0, at: kCGWindowLayer) == 0
    }
    guard let largest = owned.max(by: { area(of: $0) < area(of: $1) }),
      let id = number(of: largest, at: kCGWindowNumber)
    else {
      throw Refusal(reason: "Logic has no window on the screen")
    }
    return CGWindowID(id)
  }

  /// The windows on the screen now, as macOS lists them.
  static func windowsOnTheScreen() -> [[String: Any]] {
    let listed = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    return (listed as? [[String: Any]]) ?? []
  }

  /// One whole number of a listed window, or nothing when the window carries none.
  static func number(of window: [String: Any], at key: CFString) -> Int? {
    (window[key as String] as? NSNumber)?.intValue
  }

  /// How much of the screen a listed window covers. A window with no bounds covers nothing, so it
  /// is never the largest.
  static func area(of window: [String: Any]) -> Double {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
      let width = (bounds["Width"] as? NSNumber)?.doubleValue,
      let height = (bounds["Height"] as? NSNumber)?.doubleValue
    else {
      return 0
    }
    return width * height
  }

  /// Runs the tool over one window, and refuses with what it did.
  ///
  /// `-x` takes the picture without the sound, and `-o` leaves out the shadow of the window, so
  /// two pictures of one window that did not change are the same bytes.
  private func take(_ window: CGWindowID, into file: URL) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["-x", "-o", "-l\(window)", file.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw Refusal(reason: "screencapture could not be started: \(error)")
    }

    if stoppedAtTheLimit(process) {
      throw Refusal(
        reason: "screencapture passed its limit of \(Int(limitSeconds)) seconds and was stopped")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Refusal(reason: "screencapture ended with status \(process.terminationStatus)")
    }
  }

  /// Waits for the tool, and stops it when it passes the limit. True when it was stopped.
  ///
  /// A capture that never ends would hold the command open with the session lock taken, and the
  /// person would get no answer at all for a picture nobody asked to wait for.
  private func stoppedAtTheLimit(_ process: Process) -> Bool {
    let limit = Date().addingTimeInterval(limitSeconds)
    while process.isRunning {
      if Date() >= limit {
        process.terminate()
        return true
      }
      Thread.sleep(forTimeInterval: WindowCapture.lookWaitSeconds)
    }
    return false
  }
}
