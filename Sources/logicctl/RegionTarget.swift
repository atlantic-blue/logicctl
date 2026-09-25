import LogicctlCore

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
  struct NoRegion: FailureCarrying, Equatable {
    /// The track the region was asked for on.
    let track: Int

    /// The number a person asked for.
    let region: Int

    var failure: Failure {
      Failure(
        code: .regionNotFound,
        message: "Track \(track) has no region \(region)",
        details: .object([
          "track": .number(Double(track)),
          "region": .number(Double(region)),
        ]))
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
      throw NoRegion(track: number, region: asked)
    }
    return region
  }
}
