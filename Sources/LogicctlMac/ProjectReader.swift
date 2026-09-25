import ApplicationServices
import Foundation
import LogicctlCore

/// Where the project Logic has open sits, what it is called, and which process holds it.
///
/// A session is found by the path of the project, so this is the read that decides which history
/// every step of every command lands in. Logic carries that path in the `AXDocument` attribute of
/// the main window, as a file url, and carries nothing there for a project it never saved.
///
/// Every read is a closure the caller gives, as they are for `InputGate` and for `TempoField`. The
/// pipeline has no Logic, so a test drives the same reads with a project of its own.
public struct ProjectReader {
  /// Why the reader refused what Logic answered. The reason reaches the answer of the command, so a
  /// person reads what Logic said without going to look for a log.
  public struct Refusal: FailureCarrying, Equatable, Sendable {
    /// One short reason, in the words of the Mac that refused.
    public let reason: String

    /// The code a caller reads and exits with.
    public let code: ErrorCode

    public init(reason: String, code: ErrorCode = .internalFailure) {
      self.reason = reason
      self.code = code
    }

    /// The failure the caller prints and exits with.
    public var failure: Failure {
      Failure(code: code, message: reason)
    }
  }

  /// The Logic that runs now, or nothing when none runs.
  public typealias LogicRead = () throws -> RunningLogic?

  /// The document the main window carries, written as text, or nothing when it carries none.
  public typealias DocumentRead = () throws -> String?

  /// The title of the main window, or nothing when Logic shows no window.
  public typealias TitleRead = () throws -> String?

  private let readLogic: LogicRead
  private let readDocument: DocumentRead
  private let readTitle: TitleRead

  public init(
    logic: @escaping LogicRead,
    document: @escaping DocumentRead,
    title: @escaping TitleRead
  ) {
    readLogic = logic
    readDocument = document
    readTitle = title
  }

  /// Where the project that Logic has open sits, or nothing when Logic never saved it.
  ///
  /// A Mac where Logic is not running refuses, as `FakeLogicDriver` refuses: a path answered there
  /// would send the steps of a command into the session of a project nobody has open.
  public func path() throws -> String? {
    _ = try runningLogic()
    guard let document = try readDocument(), !document.isEmpty else {
      return nil
    }
    guard let path = ProjectReader.path(ofDocument: document) else {
      throw Refusal(
        reason: "Logic names the project it has open as \(document), which is no file url.")
    }
    return path
  }

  /// What the project Logic has open is called, or nothing when the window names no project.
  public func name() throws -> String? {
    _ = try runningLogic()
    guard let title = try readTitle() else {
      return nil
    }
    return ProjectReader.name(inTitle: title)
  }

  /// The process id of the Logic that runs.
  ///
  /// A command reads it before its action and again after it, so a Logic that went away between the
  /// two is the answer of the command rather than a state nobody measured.
  public func processID() throws -> Int32 {
    try runningLogic().processID
  }

  /// The Logic that runs, or the refusal every read about a project answers without one.
  private func runningLogic() throws -> RunningLogic {
    guard let logic = try readLogic() else {
      throw DriverRefusal.logicNotRunning
    }
    return logic
  }
}

extension ProjectReader {
  /// What Logic writes in front of the path of a project.
  public static let fileScheme = "file://"

  /// What Logic writes between the file of the project and what the window shows of it.
  public static let titleSeparator = ".logicx - "

  /// The path a document url names, or nothing when the text names no file.
  ///
  /// Measured on Logic 12.3.1 on 2026-09-25: the attribute reads
  /// `file:///private/tmp/logicctl-fixtures/F-T13.logicx/`. Neither the percent escapes nor the
  /// trailing slash is promised, and a path that keeps either one matches no session, because a
  /// session is found by the path as the file system writes it. The text is read here rather than
  /// through `URL`, so a space written as a space reads the same as a space written as an escape.
  public static func path(ofDocument document: String) -> String? {
    guard document.hasPrefix(fileScheme) else {
      return nil
    }
    let afterScheme = String(document.dropFirst(fileScheme.count))
    guard afterScheme.hasPrefix("/") else {
      return nil
    }
    var path = afterScheme.removingPercentEncoding ?? afterScheme
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  /// The name of the project a window title carries, or nothing when it carries none.
  ///
  /// The cut is made at the extension and not at the first dash, because a project can be called
  /// `A - B`, and a cut at the first dash would name that project `A`. Only the first cut counts:
  /// the Mixer window reads `F-T0.logicx - Mixer: Tracks`.
  public static func name(inTitle title: String) -> String? {
    guard let separator = title.range(of: titleSeparator) else {
      return nil
    }
    let named = String(title[title.startIndex..<separator.lowerBound])
    return named.isEmpty ? nil : named
  }

  /// The text of a document attribute, whether Logic answers a string or a url object.
  ///
  /// The measured Logic answers a string. An element of macOS can carry a url object in the same
  /// attribute, and a reader that took the string alone would read that Mac as a project nobody
  /// saved.
  public static func text(ofDocument carried: AnyObject?) -> String? {
    if let text = carried as? String {
      return text
    }
    if let url = carried as? URL {
      return url.absoluteString
    }
    return nil
  }
}

extension ProjectReader {
  /// The project of the Logic that runs on this Mac.
  ///
  /// Each read walks to the window again rather than holding it, because Logic builds its windows
  /// afresh as projects open and close, and a window read once is a handle to the window of that
  /// moment.
  public static func live() -> ProjectReader {
    ProjectReader(
      logic: AppControl.readTheLogicOfThisMac,
      document: ProjectReader.documentOfThisMac,
      title: ProjectReader.titleOfThisMac)
  }

  /// The document the main window of this Mac carries, or nothing when it carries none.
  ///
  /// An attribute Accessibility refuses reads as nothing, because a project Logic never saved
  /// carries no document at all, and both mean one thing to the caller.
  public static func documentOfThisMac() throws -> String? {
    guard let window = try ProjectReader.mainWindowOfThisMac() else {
      return nil
    }
    guard let live = window as? LiveAXNode else {
      throw Refusal(
        reason: "The main window was found in a recorded tree, which carries no document.")
    }
    var carried: CFTypeRef?
    let answered = AXUIElementCopyAttributeValue(
      live.element, kAXDocumentAttribute as CFString, &carried)
    guard answered == .success else {
      return nil
    }
    return ProjectReader.text(ofDocument: carried)
  }

  /// The title of the main window of this Mac, or nothing when Logic shows no project window.
  public static func titleOfThisMac() throws -> String? {
    try ProjectReader.mainWindowOfThisMac()?.title
  }

  /// The main window of the Logic that runs, or nothing when Logic shows none.
  ///
  /// The name of the project is in the title of the window the tracks sit in. The Mixer and the
  /// Event List carry the name too, and they carry the view after it, so a read of the window in
  /// front would name the project from whichever window a person opened last.
  private static func mainWindowOfThisMac() throws -> (any AXNode)? {
    guard let project = try AXDriver.treeOfRunningLogic()?.atTheProjectWindow() else {
      return nil
    }
    return try LocatorResolver.element(of: Locators.mainWindow, in: project.root)
  }
}
