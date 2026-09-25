import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class DeleteTime {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// What one run of the command wrote, on each channel, and the number it exited with.
private final class DeleteAnswer {
  var out = ""
  var err = ""
  var status: Int32 = 0

  func write(_ text: String) {
    out += text
  }

  func writeError(_ text: String) {
    err += text
  }

  /// What standard output carried, read back as JSON.
  func printed() throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
    return parsed as? [String: Any] ?? [:]
  }

  /// The rows the answer carries under `data.tracks`.
  func rows() throws -> [[String: Any]] {
    let data = try printed()["data"] as? [String: Any] ?? [:]
    return data["tracks"] as? [[String: Any]] ?? []
  }

  /// The code of the failure the answer carries, or nil when it carries none.
  func failureCode() throws -> String? {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["code"] as? String
  }

  /// What the failure says, or nil when it carries none.
  func failureMessage() throws -> String? {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["message"] as? String
  }

  /// What the failure says in `details`, or an empty object when it says nothing.
  func failureDetails() throws -> [String: Any] {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["details"] as? [String: Any] ?? [:]
  }
}

/// Every press that reached Logic, in the order it reached it.
///
/// A delete is two presses in one order: the header of the track, then the item of the menu. Logic
/// removes the track that is selected, so a menu press that came first would remove whichever
/// track the person left selected.
private final class DeletePresses {
  /// The controls of the window that were pressed.
  var inTheWindow: [Locator] = []

  /// The items of the menu bar that were pressed.
  var inTheMenu: [Locator] = []

  /// The name of every press, window and menu alike, in the order they were made.
  var order: [String] = []
}

/// A folder that carries no session, so nothing of a run reaches the disk.
private func noDeleteSessionFolder() -> URL {
  URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "logicctl-no-session")
}

/// A project that holds these tracks, open in Logic, saved nowhere.
private func aLogicWhoseProjectHolds(_ tracks: [Track]) -> FakeLogicDriver {
  FakeLogicDriver(tracks: tracks)
}

/// Runs `logicctl tracks delete` against a Logic that holds these tracks.
///
/// The words go through the parser of the subcommand first, exactly as a command line does. The
/// delete is what Logic does when the item of the Track menu is pressed, so a test says what its
/// Logic makes of it.
private func tracksDelete(
  _ line: [String],
  driver: FakeLogicDriver,
  presses: DeletePresses,
  root: URL? = nil,
  delete: @escaping (FakeLogicDriver) -> Void
) -> DeleteAnswer {
  let answer = DeleteAnswer()
  let time = DeleteTime()
  do {
    let command = try Tracks.Delete.parse(line)
    let actions = TrackActions(
      press: { locator in
        presses.inTheMenu.append(locator)
        presses.order.append(locator.name)
        delete(driver)
      },
      pressInWindow: { locator in
        presses.inTheWindow.append(locator)
        presses.order.append(locator.name)
      })
    answer.status = Tracks.Delete.answer(
      driver: driver,
      actions: actions,
      index: command.track.index,
      confirmed: command.guarded.confirm,
      root: root ?? noDeleteSessionFolder(),
      limitMs: 50,
      argv: line,
      clock: time.read,
      sleeper: time.sleep,
      standardOutput: answer.write,
      standardError: answer.writeError)
  } catch {
    answer.status = Logicctl.report(
      error,
      arguments: line,
      standardOutput: answer.write,
      standardError: answer.writeError)
  }
  return answer
}

/// The Logic of a test removes the track at that number, and numbers the tracks it has left again
/// from 1.
///
/// Logic numbers the tracks from the top of the window, so every track under the one that went
/// moves up by one. A double that left the numbers where they were would hold a project no Logic
/// can hold, and a command that read the wrong number back would pass against it.
private func aLogicWhoseDeleteRemovesTheTrack(atIndex index: Int) -> (FakeLogicDriver) -> Void {
  { fake in
    guard var state = fake.state else {
      return
    }
    guard let place = state.tracks.firstIndex(where: { $0.index == index }) else {
      return
    }
    state.tracks.remove(at: place)
    for number in state.tracks.indices {
      state.tracks[number].index = number + 1
    }
    fake.state = state
  }
}

/// A person or an agent takes one track out of the project, and reads the project that is left.
///
/// The list in the answer is the project as Logic holds it now. That is the whole value of the
/// command: an agent deletes a track and works on from the answer, without opening Logic to look
/// and without a list of its own. A command that printed the list it read before the press would
/// name a track that is gone, and every later command would act on a project that does not exist.
@Test func deleteRemovesTheTrack() throws {
  let driver = aLogicWhoseProjectHolds([
    Track(index: 1, name: "Bass", type: .softwareInstrument),
    Track(index: 2, name: "Drums", type: .audio),
  ])
  let presses = DeletePresses()

  let answer = tracksDelete(
    ["--index", "2"],
    driver: driver,
    presses: presses,
    delete: aLogicWhoseDeleteRemovesTheTrack(atIndex: 2))

  #expect(answer.status == 0, "the command worked")
  #expect(try answer.printed()["error"] is NSNull, "so it carries no failure")
  #expect(answer.err == "", "and standard error stays empty")

  let rows = try answer.rows()
  #expect(rows.count == 1, "the project holds one track now")

  let row = try #require(rows.first, "and the answer carries it")
  #expect(row["index"] as? Int == 1, "the track that is left")
  #expect(row["name"] as? String == "Bass", "which keeps its name")
  #expect(row["type"] as? String == "software-instrument", "and its kind")
  #expect(row["mute"] as? Bool == false, "a delete leaves the mute button of another track alone")
  #expect(row["solo"] as? Bool == false, "and the solo button")
  #expect(row["arm"] as? Bool == false, "and the record enable button")
  #expect(driver.state?.tracks.count == 1, "the project of Logic holds one track")
  #expect(driver.state?.tracks.first?.name == "Bass", "and it is the one the answer names")
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and a newline")
}

/// A person or an agent takes the first of two tracks out, and the one that is left is numbered 1.
///
/// Logic numbers the tracks from the top of the window, so the track that was 2 is 1 once the
/// track above it goes. The answer says so, because it is read after the change: an answer built
/// from the list read before it would name Bass, a track the project no longer holds.
@Test func deletingTheFirstTrackNumbersTheRestAgain() throws {
  let driver = aLogicWhoseProjectHolds([
    Track(index: 1, name: "Bass", type: .softwareInstrument),
    Track(index: 2, name: "Drums", type: .audio),
  ])
  let presses = DeletePresses()

  let answer = tracksDelete(
    ["--index", "1"],
    driver: driver,
    presses: presses,
    delete: aLogicWhoseDeleteRemovesTheTrack(atIndex: 1))

  #expect(answer.status == 0, "the command worked")

  let rows = try answer.rows()
  #expect(rows.count == 1, "the project holds one track now")

  let row = try #require(rows.first, "and the answer carries it")
  #expect(row["name"] as? String == "Drums", "the track that is left is the second one")
  #expect(row["index"] as? Int == 1, "and Logic numbers it 1")
  #expect(driver.state?.tracks.first?.index == 1, "which is what the project holds")
}

/// A person or an agent names a track the project does not have.
///
/// The refusal comes before anything is pressed, so the project is as it was, and the answer names
/// the number that was asked for. An agent reads `track_not_found`, exit 10 and the index, lists
/// the tracks, and asks again.
@Test func anIndexThatNamesNoTrackFailsBeforeTheTrackIsDeleted() throws {
  let driver = aLogicWhoseProjectHolds([Track(index: 1, name: "Bass", type: .other)])
  let presses = DeletePresses()

  let answer = tracksDelete(
    ["--index", "9"],
    driver: driver,
    presses: presses,
    delete: aLogicWhoseDeleteRemovesTheTrack(atIndex: 9))

  #expect(answer.status == 10, "the number the design system gives track_not_found")
  #expect(try answer.failureCode() == "track_not_found", "the project has no track 9")
  #expect(try answer.failureMessage() == "No track at index 9", "and the answer says so")
  #expect(try answer.failureDetails()["index"] as? Int == 9, "the answer names the number asked")
  #expect(try answer.printed()["data"] is NSNull, "a refusal carries no answer")
  #expect(presses.order.isEmpty, "nothing in Logic was pressed")
  #expect(driver.state?.tracks.count == 1, "the project is as it was")
}

/// A person opens a project they wrote themselves, and an agent asks logicctl to delete a track.
///
/// The work in that project is theirs, and a delete takes a track and everything on it. So
/// logicctl does not do it on its own word. The agent reads `confirm_required` and exit 7, nothing
/// is pressed, and the project is as the person left it. The person then says `--confirm`, and the
/// same command goes through.
@Test func deletingATrackInAProjectLogicctlDidNotMakeNeedsConfirm() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-delete-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let driver = FakeLogicDriver(
    tracks: [
      Track(index: 1, name: "Bass", type: .other),
      Track(index: 2, name: "Drums", type: .other),
    ],
    project: "Their Sketch",
    path: "/Users/someone/Music/Their Sketch.logicx")
  let presses = DeletePresses()

  let answer = tracksDelete(
    ["--index", "2"],
    driver: driver,
    presses: presses,
    root: root,
    delete: aLogicWhoseDeleteRemovesTheTrack(atIndex: 2))

  #expect(answer.status == 7, "the number the design system gives confirm_required")
  #expect(try answer.failureCode() == "confirm_required", "logicctl did not make this project")
  #expect(presses.order.isEmpty, "nothing in Logic was pressed")
  #expect(driver.state?.tracks.count == 2, "the project of the person holds both tracks")
}

/// Logic takes the presses and the project holds the same tracks.
///
/// The read back is the whole of the evidence that the delete did what it was asked to do, because
/// nothing says which track Logic had selected when the menu item was pressed. A command that
/// printed a list here would report a project that Logic does not hold. It gives up at the limit
/// instead, with `timeout`, and it says how long it gave Logic, so a person runs it again with a
/// longer `--timeout`.
@Test func aDeleteThatRemovedNoTrackFailsWithTimeout() throws {
  let driver = aLogicWhoseProjectHolds([
    Track(index: 1, name: "Bass", type: .other),
    Track(index: 2, name: "Drums", type: .other),
  ])
  let presses = DeletePresses()

  let answer = tracksDelete(["--index", "2"], driver: driver, presses: presses) { _ in }

  #expect(answer.status == 6, "the number the design system gives timeout")
  #expect(try answer.failureCode() == "timeout", "Logic holds the tracks it held before")
  #expect(try answer.failureDetails()["waitedMs"] as? Int == 50, "how long Logic was given")
  #expect(try answer.printed()["data"] is NSNull, "a failure carries no answer")
  #expect(presses.inTheMenu.count == 1, "the item was pressed once, and once only")
  #expect(driver.state?.tracks.count == 2, "the project holds both tracks, as it did")
}

/// The header of the named track is selected, and then the item of the Track menu is pressed.
///
/// Logic removes the track that is selected, so the order is the command. A menu press on its own
/// would remove whichever track the person last clicked, which is a track nobody named. The number
/// a person types counts from 1 and a track header counts from 0, so a command that passed the
/// number straight through would take the track under the one that was asked for.
@Test func theDeleteSelectsTheHeaderOfTheNamedTrackAndThenPressesTheMenuItem() throws {
  let driver = aLogicWhoseProjectHolds([
    Track(index: 1, name: "Bass", type: .other),
    Track(index: 2, name: "Drums", type: .other),
  ])
  let presses = DeletePresses()

  let answer = tracksDelete(
    ["--index", "2"],
    driver: driver,
    presses: presses,
    delete: aLogicWhoseDeleteRemovesTheTrack(atIndex: 2))

  #expect(answer.status == 0, "the command worked")
  #expect(
    presses.order == [Locators.trackHeader(number: 1).name, TrackActions.deleteTrack.name],
    "the header of the second track, which counts from 0, and then the item of the Track menu")
  #expect(driver.state?.tracks.first?.name == "Bass", "the first track is the one that is left")
}

/// The item the delete presses is `Delete Track`, and never `Delete Unused Tracks`.
///
/// The Track menu of Logic 12.3.1 holds both. `Delete Unused Tracks` removes every track that
/// carries no region, so a walk that matched the first item starting with those two words would
/// take tracks nobody named, in one press, with no way back.
///
/// The tree here is written by hand and not recorded. A menu bar sits beside the windows of an
/// application rather than under one, so `inspect --window main` never reaches it and no recorded
/// tree holds one. What the tree proves is the walk: given a Track menu holding both items, the
/// locator finds one element and it is the one that removes the named track. Whether Logic itself
/// shows those items is what the live suite of phase 2 answers.
@Test func theDeleteWalkLeavesDeleteUnusedTracksAlone() throws {
  let written = """
    {
      "logicVersion": "12.3.1",
      "root": {
        "role": "AXApplication",
        "children": [
          { "role": "AXWindow", "title": "Untitled - Tracks" },
          {
            "role": "AXMenuBar",
            "children": [
              { "role": "AXMenuBarItem", "title": "File" },
              {
                "role": "AXMenuBarItem",
                "title": "Track",
                "children": [
                  {
                    "role": "AXMenu",
                    "children": [
                      { "role": "AXMenuItem", "title": "New Audio Track" },
                      { "role": "AXMenuItem", "title": "Delete Track" },
                      { "role": "AXMenuItem", "title": "Delete Unused Tracks" }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }
    }
    """
  let tree = try JSONDecoder().decode(RecordedTree.self, from: Data(written.utf8))

  let item = try LocatorResolver.element(of: TrackActions.deleteTrack, in: tree.root)

  #expect(item.title == "Delete Track", "the item that removes the track that is selected")
  #expect(
    TrackActions.deleteTrack.path.last?.title == "Delete Track",
    "the walk names the whole title, so nothing that starts with the same words matches it")
  #expect(
    TrackActions.deleteTrack.recordedFrom == "12.3.1",
    "the version of Logic the title was read from")
}
