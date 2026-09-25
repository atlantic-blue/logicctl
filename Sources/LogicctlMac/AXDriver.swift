import AppKit
import Foundation
import LogicctlCore

/// What logicctl reads from the Logic that runs on this Mac.
///
/// This is the one driver every command talks to. It joins the readers over Accessibility: the
/// state from `StateReader`, the path and the process id from `ProjectReader`, and the modal window
/// from `DialogReader`. `status` stands beside them and answers before any project is open.
///
/// Four reads answer `status`, and each one comes from a different place. Whether Logic runs, and
/// which version it is, come from the application bundle that macOS has open. Whether Logic is in
/// front comes from the workspace. The title of the window comes from the Accessibility tree. So
/// the driver is given the tree and the front application rather than reaching for them, and the
/// pipeline, which has no Logic, drives the same code against a tree that `inspect` recorded from
/// Logic 12.3.1.
///
/// Every other read is given the same way, so the pipeline proves the joining as well: a driver
/// built over the recorded trees answers the conformance suite that `FakeLogicDriver` answers.
public struct AXDriver: LogicDriver, LogicStatusReader {
  /// The tree of the Logic that runs, or nothing when no Logic runs.
  public typealias TreeRead = () throws -> LogicTree?

  /// The state of the project Logic has open, told what the read before it held.
  public typealias StateRead = (State?) throws -> State

  /// Where the project Logic has open sits, or nothing when Logic never saved it.
  public typealias PathRead = () throws -> String?

  /// The process id of the Logic that runs.
  public typealias ProcessIDRead = () throws -> Int32

  /// The window Logic waits on in one tree, or nothing when it waits on none.
  public typealias DialogRead = (any AXNode) -> ModalDialog?

  /// The state the session of the project at one path recorded last, or nothing when no session
  /// carries that path.
  public typealias RecordedStateRead = (String) -> State?

  /// The tree of the Logic that runs, or nothing when no Logic runs.
  private let tree: TreeRead

  /// The bundle identifier of the application in front, or nothing when macOS names none.
  private let applicationInFront: () -> String?

  private let readWholeState: StateRead
  private let readProjectPath: PathRead
  private let readProcessID: ProcessIDRead
  private let readDialog: DialogRead
  private let readRecordedState: RecordedStateRead

  /// The state this driver read last, in this process.
  private let held = LastRead()

  public init(
    tree: @escaping TreeRead = AXDriver.treeOfRunningLogic,
    applicationInFront: @escaping () -> String? = AXDriver.applicationInFrontOfThisMac,
    state: @escaping StateRead = AXDriver.stateOfRunningLogic(after:),
    path: @escaping PathRead = AXDriver.pathOfTheOpenProject,
    processID: @escaping ProcessIDRead = AXDriver.processIDOfRunningLogic,
    dialog: @escaping DialogRead = AXDriver.dialogTheRunningLogicWaitsOn(in:),
    recordedState: @escaping RecordedStateRead = { _ in nil }
  ) {
    self.tree = tree
    self.applicationInFront = applicationInFront
    readWholeState = state
    readProjectPath = path
    readProcessID = processID
    readDialog = dialog
    readRecordedState = recordedState
  }

  /// What Logic is doing now.
  ///
  /// A Mac with no Logic answers `running` false and nothing else, and it does not throw. Every
  /// other read of a driver refuses there, because there is no project to answer about. This one
  /// is the question of whether there is a Logic at all, and a refusal would leave a script with
  /// an exit code instead of an answer.
  public func status() throws -> LogicStatus {
    guard let open = try tree() else {
      return LogicStatus.notRunning
    }
    return LogicStatus(
      running: true,
      frontmost: applicationInFront() == LogicTree.bundleIdentifier,
      window: open.atTheFrontWindow()?.root.title,
      version: open.logicVersion.isEmpty ? nil : open.logicVersion)
  }

  /// The state of the project Logic has open, from one walk of its tree.
  ///
  /// The plugins of a track are read from the Mixer, and Logic shows the Mixer only while a person
  /// keeps it open. So the read is told what the read before it held, and a track whose strip this
  /// walk cannot see keeps the plugins it had. The first read of a command is told the state the
  /// session recorded last, because a first read that answered no plugin would reach the
  /// comparison with `state.json` as a person who removed every plugin.
  public func readState() throws -> State {
    let read = try readWholeState(stateBeforeThisRead())
    held.state = read
    return read
  }

  /// Where the project that Logic has open sits, or nothing when Logic never saved it.
  public func projectPath() throws -> String? {
    try readProjectPath()
  }

  /// The process id of the Logic that runs.
  public func processID() throws -> Int32 {
    try readProcessID()
  }

  /// The window Logic waits on, or nothing when it waits on none.
  ///
  /// A Mac where Logic is not running refuses, as every other read about a project refuses. A
  /// driver that answered "no dialog" where it cannot see would let a command act while Logic is
  /// taking nothing.
  public func modalDialog() throws -> ModalDialog? {
    guard let open = try tree() else {
      throw DriverRefusal.logicNotRunning
    }
    return readDialog(open.root)
  }

  /// What the plugins of a track that this walk cannot see come from: the state this driver read
  /// last, and before the first read of a command, the state the session of that project recorded.
  ///
  /// A project that sits nowhere has no session to read, and a project with no session has nothing
  /// recorded, and both answer nothing. A read that refuses answers nothing as well, because the
  /// read of the state is about to refuse for the same reason.
  private func stateBeforeThisRead() -> State? {
    if let read = held.state {
      return read
    }
    do {
      guard let path = try readProjectPath() else {
        return nil
      }
      return readRecordedState(path)
    } catch {
      return nil
    }
  }
}

extension AXDriver {
  /// The driver over the Logic that runs on this Mac.
  ///
  /// The state the session recorded last is given by the caller, because a session is the journal
  /// and this module does not see it.
  public static func live(
    recordedState: @escaping RecordedStateRead = { _ in nil }
  ) -> AXDriver {
    AXDriver(recordedState: recordedState)
  }

  /// The tree of the Logic that runs on this Mac, or nothing when no Logic runs.
  ///
  /// `LogicTree.ofRunningLogic` refuses where there is no Logic, because a walk of nothing prints
  /// an empty tree and an empty tree reads the same as a Logic that shows nothing. `status` asks a
  /// different question, so that one refusal reads here as the answer nothing.
  public static func treeOfRunningLogic() throws -> LogicTree? {
    do {
      return try LogicTree.ofRunningLogic()
    } catch DriverRefusal.logicNotRunning {
      return nil
    }
  }

  /// What macOS says is the application in front, by bundle identifier.
  public static func applicationInFrontOfThisMac() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
  }

  /// The state of the project the Logic of this Mac has open.
  public static func stateOfRunningLogic(after previous: State?) throws -> State {
    try StateReader.live().state(after: previous)
  }

  /// Where the project the Logic of this Mac has open sits.
  public static func pathOfTheOpenProject() throws -> String? {
    try ProjectReader.live().path()
  }

  /// The process id of the Logic of this Mac.
  public static func processIDOfRunningLogic() throws -> Int32 {
    try ProjectReader.live().processID()
  }

  /// The window the Logic of this Mac waits on, read from one tree of it.
  public static func dialogTheRunningLogicWaitsOn(in root: any AXNode) -> ModalDialog? {
    DialogReader.live().dialog(in: root)
  }
}

/// The state one driver read last.
///
/// `LogicDriver.readState` takes nothing, and the reader of the state needs the read before it. A
/// command hands the driver on by value, so the memory sits behind a reference and every copy of
/// one driver reads the same one. It lasts as long as the process, which is one command.
private final class LastRead {
  var state: State?
}
