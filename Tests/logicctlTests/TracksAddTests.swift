import ArgumentParser
import Foundation
import LogicctlCore
import LogicctlMac
import LogicctlTesting
import Testing

@testable import logicctl

/// A clock and a sleep the test moves itself, so a wait of any length costs no real time.
private final class Time {
  var now = 0

  func read() -> Int {
    now
  }

  func sleep(_ span: Int) {
    now += span
  }
}

/// What one run of the command wrote, on each channel, and the number it exited with.
private final class Answer {
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

  /// The row the answer carries under `data.track`.
  func row() throws -> [String: Any] {
    let data = try printed()["data"] as? [String: Any] ?? [:]
    return data["track"] as? [String: Any] ?? [:]
  }

  /// The code of the failure the answer carries, or nil when it carries none.
  func failureCode() throws -> String? {
    let failure = try printed()["error"] as? [String: Any]
    return failure?["code"] as? String
  }
}

/// What the Logic of a test was asked to press.
private final class Menu {
  /// The items that were pressed, in the order they were pressed.
  var pressed: [Locator] = []

  /// The title of the last item that was pressed, which is what the Track menu shows.
  var lastTitle: String? {
    pressed.last?.path.last?.title
  }
}

/// A folder that carries no session, so nothing of a run reaches the disk.
private func noSession() -> URL {
  URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "logicctl-no-session")
}

/// Runs `logicctl tracks add` against a Logic that holds these tracks.
///
/// The words go through the parser of the subcommand first, exactly as a command line does, so a
/// type the flag does not take is refused there and the Logic below is never asked anything. The
/// press is what Logic does when the item is pressed, so a test says what its Logic makes of it.
private func tracksAdd(
  _ line: [String],
  driver: FakeLogicDriver,
  menu: Menu,
  root: URL? = nil,
  press: @escaping (FakeLogicDriver) -> Void
) -> Answer {
  let answer = Answer()
  let time = Time()
  do {
    let command = try Tracks.Add.parse(line)
    let actions = TrackActions { locator in
      menu.pressed.append(locator)
      press(driver)
    }
    answer.status = Tracks.Add.answer(
      driver: driver,
      actions: actions,
      type: command.type,
      confirmed: command.guarded.confirm,
      root: root ?? noSession(),
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

/// The track Logic makes for `--type audio`, as a reader of the track headers reads it back.
///
/// The name is the one Logic gives a new audio track. The kind reads as neither, because the
/// header of a track carries the same nine controls whichever kind it is and none of them says
/// which, so a reader of the headers cannot answer that question.
private func anAudioTrack(numbered index: Int) -> Track {
  Track(index: index, name: "Audio 1", type: .other)
}

/// A project that holds these tracks, open in Logic, saved nowhere.
private func aLogicHolding(_ tracks: [Track]) -> FakeLogicDriver {
  FakeLogicDriver(tracks: tracks)
}

/// A person or an agent asks for a kind of track that logicctl does not offer.
///
/// `--type` takes two words, and `drummer` is not one of them. The refusal costs nothing: it
/// happens where the arguments are read, so Logic is never asked for an item it may not even
/// have, the project of the person is untouched, and the journal gains no step for a word that
/// was typed by mistake. The person gets the same answer as for any other wrong flag, which is
/// one JSON object with the code `invalid_argument`, one line on standard error, and exit 2. An
/// agent reads that number and asks again.
@Test func anUnknownTrackTypeStopsBeforeLogic() throws {
  let driver = aLogicHolding([Track(index: 1, name: "Deluxe Classic", type: .other)])
  let menu = Menu()

  let answer = tracksAdd(["--type", "drummer"], driver: driver, menu: menu) { fake in
    fake.state?.tracks.append(anAudioTrack(numbered: 2))
  }

  #expect(answer.status == 2, "the number the design system gives invalid_argument")
  #expect(try answer.failureCode() == "invalid_argument", "the arguments were wrong")
  #expect(try answer.printed()["data"] is NSNull, "a refusal carries no answer")
  #expect(menu.pressed.isEmpty, "no item of the Track menu was pressed")
  #expect(driver.state?.tracks.count == 1, "Logic holds the tracks it held before")

  let printed = try answer.printed()
  let meta = printed["meta"] as? [String: Any]
  #expect(meta?["session"] is NSNull, "Logic was never asked, so no session was opened")
  #expect(meta?["step"] is NSNull, "and no step was written")

  let message = (printed["error"] as? [String: Any])?["message"] as? String
  #expect(answer.err == "logicctl: invalid_argument: \(message ?? "")\n", "one line, for a person")
  #expect(answer.out.filter(\.isNewline).count == 1, "one JSON object and a newline")
}

/// A person or an agent adds an audio track to a project that holds one track already.
///
/// logicctl presses the one item of the Track menu that makes an audio track, reads the project
/// again, and prints the row of the track the project gained: the number that names it to every
/// other `tracks` command, the name Logic gave it, and the kind that was asked for. The kind is
/// the one the person asked for and not the one the header reads as, because the header of a
/// track says nothing about its kind and Logic has one menu item for each.
@Test func addingAnAudioTrackPrintsTheRowOfTheTrackItAdded() throws {
  let driver = aLogicHolding([Track(index: 1, name: "Deluxe Classic", type: .other)])
  let menu = Menu()

  let answer = tracksAdd(["--type", "audio"], driver: driver, menu: menu) { fake in
    fake.state?.tracks.append(anAudioTrack(numbered: 2))
  }

  #expect(answer.status == 0, "the command worked")
  #expect(try answer.printed()["error"] is NSNull, "so it carries no failure")
  #expect(answer.err == "", "and standard error stays empty")
  #expect(menu.lastTitle == "New Audio Track", "the item of the Track menu that makes one")

  let row = try answer.row()
  #expect(row["index"] as? Int == 2, "the number a person gives --index for the new track")
  #expect(row["name"] as? String == "Audio 1", "the name Logic gave it")
  #expect(row["type"] as? String == "audio", "the kind the person asked for")
  #expect(row["mute"] as? Bool == false, "a new track is not muted")
  #expect(row["solo"] as? Bool == false, "a new track is not soloed")
  #expect(row["arm"] as? Bool == false, "and it is not armed")
  #expect(driver.state?.tracks.count == 2, "Logic holds one track more than it held")
}

/// The other kind of track presses the other item.
///
/// Two words, two items, and each word reaches its own. A command that pressed the same item for
/// both would give a person an audio track for every ask, and the row would still read as the
/// kind they typed, so nothing in the answer would say what had happened.
@Test func addingASoftwareInstrumentTrackPressesTheItemThatMakesOne() throws {
  let driver = aLogicHolding([])
  let menu = Menu()

  let answer = tracksAdd(["--type", "software-instrument"], driver: driver, menu: menu) { fake in
    fake.state?.tracks.append(Track(index: 1, name: "Deluxe Classic", type: .other))
  }

  #expect(answer.status == 0, "the command worked")
  #expect(
    menu.lastTitle == "New Software Instrument Track",
    "the item of the Track menu that makes a software instrument track")
  #expect(try answer.row()["type"] as? String == "software-instrument", "the kind that was asked")
  #expect(try answer.row()["index"] as? Int == 1, "the first track of a project that had none")
}

/// Logic puts a new track under the track that is selected, so the new row is not always the last.
///
/// The row that goes out is the one the project gained, found by reading the two lists against
/// each other. A command that answered the last row would hand back a track the person already
/// had, and every later command that took that number would change the wrong track.
@Test func theRowIsTheTrackTheProjectGainedAndNotTheLastOne() throws {
  let driver = aLogicHolding([
    Track(index: 1, name: "Bass", type: .other),
    Track(index: 2, name: "Drums", type: .other),
  ])
  let menu = Menu()

  let answer = tracksAdd(["--type", "audio"], driver: driver, menu: menu) { fake in
    fake.state?.tracks = [
      Track(index: 1, name: "Bass", type: .other),
      anAudioTrack(numbered: 2),
      Track(index: 3, name: "Drums", type: .other),
    ]
  }

  #expect(answer.status == 0, "the command worked")
  #expect(try answer.row()["name"] as? String == "Audio 1", "the track that went in")
  #expect(try answer.row()["index"] as? Int == 2, "at the number Logic gave it")
}

/// Logic takes the press and makes no track.
///
/// The command reads the project until it holds one track more, and that read is the whole of the
/// evidence that the press did what it was asked to do. A command that printed a row here would
/// report a track that Logic never made. It gives up at the limit instead, with `timeout`, and it
/// says how long it gave Logic, so a person runs it again with a longer `--timeout`.
@Test func aPressThatMadeNoTrackFailsWithTimeout() throws {
  let driver = aLogicHolding([Track(index: 1, name: "Deluxe Classic", type: .other)])
  let menu = Menu()

  let answer = tracksAdd(["--type", "audio"], driver: driver, menu: menu) { _ in }

  #expect(answer.status == 6, "the number the design system gives timeout")
  #expect(try answer.failureCode() == "timeout", "Logic did not make the track")
  #expect(menu.pressed.count == 1, "the item was pressed once, and once only")
  #expect(driver.state?.tracks.count == 1, "Logic holds the tracks it held before")

  let failure = try answer.printed()["error"] as? [String: Any]
  let details = failure?["details"] as? [String: Any]
  #expect(details?["waitedMs"] as? Int == 50, "the answer says how long Logic was given")
}

/// A person opens a project they wrote themselves, and an agent asks logicctl to add a track.
///
/// The work in that project is theirs, so logicctl does not change it on its own word. The agent
/// reads `confirm_required` and exit 7, no item of the Track menu is pressed, and the project is
/// as the person left it. The person then says `--confirm`, and the same command goes through.
@Test func addingATrackToAProjectLogicctlDidNotMakeNeedsConfirm() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("logicctl-add-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let driver = FakeLogicDriver(
    tracks: [Track(index: 1, name: "Deluxe Classic", type: .other)],
    project: "Their Sketch",
    path: "/Users/someone/Music/Their Sketch.logicx")
  let menu = Menu()

  let answer = tracksAdd(["--type", "audio"], driver: driver, menu: menu, root: root) { fake in
    fake.state?.tracks.append(anAudioTrack(numbered: 2))
  }

  #expect(answer.status == 7, "the number the design system gives confirm_required")
  #expect(try answer.failureCode() == "confirm_required", "logicctl did not make this project")
  #expect(menu.pressed.isEmpty, "no item of the Track menu was pressed")
  #expect(driver.state?.tracks.count == 1, "the project of the person is as they left it")
}

/// The walk to the two items of the Track menu reaches the items, and each word reaches its own.
///
/// The tree here is written by this test from the Track menu of Logic 12.3.1 as it was read on
/// this Mac. It is not a tree that `inspect` recorded: the menu bar of an application sits beside
/// its windows and not under one, and `inspect --window main` writes the window in front, so no
/// recorded tree holds a menu bar. This proves the shape of the walk and the title of each item.
/// Whether Logic itself still shows them is what the live suite of phase 2 answers.
@Test func theWalkToTheTrackMenuReachesItsItems() throws {
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
                      { "role": "AXMenuItem", "title": "New Software Instrument Track" }
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

  let audio = try LocatorResolver.element(of: Locators.newAudioTrack, in: tree.root)
  let instrument = try LocatorResolver.element(
    of: Locators.newSoftwareInstrumentTrack, in: tree.root)
  let menu = try LocatorResolver.element(of: Locators.trackMenu, in: tree.root)

  #expect(menu.role == "AXMenuBarItem", "the walk reaches the Track menu of the menu bar")
  #expect(audio.title == "New Audio Track", "the item that makes an audio track")
  #expect(
    instrument.title == "New Software Instrument Track",
    "the item that makes a software instrument track")
  #expect(
    TrackActions.menuItem(for: .audio).name == Locators.newAudioTrack.name,
    "--type audio presses the item that makes an audio track")
  #expect(
    TrackActions.menuItem(for: .softwareInstrument).name
      == Locators.newSoftwareInstrumentTrack.name,
    "--type software-instrument presses the item that makes a software instrument track")
}
