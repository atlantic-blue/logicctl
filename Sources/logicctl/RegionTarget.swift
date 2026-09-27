import LogicctlCore
import LogicctlMac

/// Turns `--track <n> --region <n>` into the one region those two numbers name.
///
/// Every MIDI edit and every automation command names its region this way, so the walk from two
/// numbers to a region is written once here. It resolves against the state the command read, which
/// is what the tracks and their regions are counted in.
enum RegionTarget {
  /// The project has no track with that number.
  struct NoTrack: FailureCarrying, Equatable {
    /// The number a person asked for.
    let index: Int

    var failure: Failure {
      Failure(
        code: .trackNotFound,
        message: "No track at index \(index)",
        details: .object(["index": .number(Double(index))]))
    }
  }

  /// The track is there and it has no region with that number.
  ///
  /// The number of a region is the place it sits in from the left, and Logic writes that number
  /// nowhere on the screen. So the count of the regions the track has goes out with the failure: it
  /// says which numbers name a region, and a person or an agent asks again without opening Logic to
  /// look.
  struct NoRegion: FailureCarrying, Equatable {
    /// The track the region was asked for on.
    let track: Int

    /// The number a person asked for.
    let region: Int

    /// How many regions the track has.
    let regions: Int

    var failure: Failure {
      Failure(
        code: .regionNotFound,
        message: "Track \(track) has \(regions) region\(regions == 1 ? "" : "s")",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
          "regions": .number(Double(regions)),
        ]))
    }
  }

  /// The state holds the region and the Tracks window shows no item for it.
  ///
  /// Logic draws the regions of a project in the Tracks window, so a project whose window is not
  /// open shows no item to select. The sentence says which region was not there rather than naming
  /// an element nobody asked about.
  struct NoRegionItem: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    var failure: Failure {
      Failure(
        code: .elementNotFound,
        message:
          "Logic shows no region \(region) on track \(track) in its Tracks window, so that "
          + "region cannot be selected. Open the Tracks window of the project.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
        ]))
    }
  }

  /// Logic holds a region selected that nobody named, so there is no one region to read.
  ///
  /// The Event List shows the region Logic holds, so a command that read on through this would
  /// answer the events of a region a person never asked about, under the numbers they did ask
  /// about. The regions Logic kept go out with the failure, as Logic describes each one.
  struct SelectionKept: FailureCarrying, Equatable {
    /// The track the region sits on.
    let track: Int

    /// The number of the region on that track.
    let region: Int

    /// Every region Logic holds after the writes, in the order Accessibility answers them.
    let selected: [String]

    var failure: Failure {
      Failure(
        code: .selectionMismatch,
        message:
          "Logic holds \(SelectionKept.words(of: selected)) selected after region \(region) on "
          + "track \(track) was selected alone, so nothing was read.",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
          "selected": .array(selected.map { JSONValue.string($0) }),
        ]))
    }

    /// The regions of a selection as the message reads them, and `no region` when Logic holds none.
    private static func words(of selected: [String]) -> String {
      selected.isEmpty ? "no region" : selected.joined(separator: ", ")
    }
  }

  /// Makes the region the two numbers name the only region Logic holds selected.
  ///
  /// Every command that reads the Event List calls this before it reads. Measured on Logic 12.3.1
  /// 2026-09-27: the Event List shows whichever region is selected and follows a change at once, so
  /// a command that read the window as it found it answered the events of another region under the
  /// numbers a person typed. A wrong answer of real events is worse than no answer, because nothing
  /// later in a session shows which region they came from.
  ///
  /// The walk is the one `automation add` selects with: it reads every region item, writes only on
  /// the items whose state is wrong, and reads the selection back. A readback holding anything else
  /// stops the command here, so nothing is read and nothing is changed.
  static func selectOnly(
    _ option: RegionOption,
    numbered region: Int,
    under root: any AXNode,
    through selection: AutomationMenus.RegionSelection
  ) throws {
    let track = option.track.value
    guard let item = AutomationMenus.regionItem(number: region, ofTrack: track, in: root) else {
      throw NoRegionItem(track: track, region: region)
    }
    do {
      try selection.makeTheOnlySelection(item, under: root)
    } catch let refused as AutomationMenus.SelectionRefused {
      throw SelectionKept(track: track, region: region, selected: refused.selected)
    }
  }

  /// The region the two numbers name, in the state the command read.
  static func region(_ option: RegionOption, in state: State) throws -> Region {
    let number = option.track.value
    guard let track = state.tracks.first(where: { $0.index == number }) else {
      throw NoTrack(index: number)
    }
    let asked = option.region.value
    guard let region = track.regions.first(where: { $0.index == asked }) else {
      throw NoRegion(track: number, region: asked, regions: track.regions.count)
    }
    return region
  }
}
