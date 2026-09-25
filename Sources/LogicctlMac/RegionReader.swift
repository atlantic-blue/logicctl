import Foundation
import LogicctlCore

/// Reads the regions of one track out of the Tracks window of Logic.
///
/// The window holds one layout area per track under the group `Tracks contents`, and a region is
/// a layout item under the area of its track. Nothing in the tree carries a position, so the order
/// the regions read in is the order Accessibility answers them, which is the order they sit in
/// from the left.
///
/// This is all the Tracks window gives without a selection: the name of the region and the two
/// borders its help text carries. The notes of a region need the Event List, and a later step
/// reads them there.
public enum RegionReader {
  /// The description of the group that holds one layout area per track.
  public static let contentsGroup = "Tracks contents"

  /// The role of the area that holds the regions of one track.
  public static let trackRole = "AXLayoutArea"

  /// The role of a region.
  public static let regionRole = "AXLayoutItem"

  /// The regions of one track, counted from 1 in order from the left.
  ///
  /// A window that holds no track with that number answers no region, the same as a track that
  /// carries nothing. The caller says which of the two it is: it holds the state, which counts the
  /// tracks of the project, and this reads the one window Logic shows.
  public static func regions(ofTrack number: Int, in window: any AXNode) -> [Region] {
    guard let area = trackArea(number, in: window) else {
      return []
    }
    let items = area.children.filter { $0.role == regionRole }
    return items.enumerated().map { place, item in
      let borders = RegionReader.borders(of: item.help ?? "")
      return Region(
        index: place + 1,
        name: item.description ?? "",
        start: borders.start,
        end: borders.end)
    }
  }

  /// Where a region starts and ends, read out of the help text of the region item.
  ///
  /// The sentence reads "Region starts at 1 bar  and ends at 2 bars , MIDI region. ...". The start
  /// is what stands between "starts at" and "and ends at". The end is what stands between
  /// "ends at" and the first comma after it. Both are trimmed, so the two spaces Logic writes stay
  /// out of the state, and a region that does not start on a bar keeps whatever the window says,
  /// for example "1 1 3 1".
  ///
  /// A help text that does not carry that sentence answers two empty texts. The borders are what
  /// the Tracks window says about the region, and a window that says nothing about them has
  /// nothing to give.
  public static func borders(of help: String) -> (start: String, end: String) {
    guard let opens = help.range(of: startsAt),
      let closes = help.range(of: endsAt, range: opens.upperBound..<help.endIndex),
      let stops = help.range(of: ",", range: closes.upperBound..<help.endIndex)
    else {
      return ("", "")
    }
    return (
      trimmed(help[opens.upperBound..<closes.lowerBound]),
      trimmed(help[closes.upperBound..<stops.lowerBound])
    )
  }

  /// The words the start of a region stands after.
  private static let startsAt = "starts at"

  /// The words the end of a region stands after. They carry "and", because "ends at" stands
  /// inside them and a search for the shorter one finds this place anyway.
  private static let endsAt = "and ends at"

  /// The area of one track, counted from 1 among the areas that name a track.
  ///
  /// Logic puts one area under the group for every track and one more that names no track, which
  /// is the room under the last one. An area with no description is that room and is not counted.
  private static func trackArea(_ number: Int, in window: any AXNode) -> (any AXNode)? {
    guard number >= 1, let group = contents(of: window) else {
      return nil
    }
    let areas = group.children.filter { child in
      child.role == trackRole && !(child.description ?? "").isEmpty
    }
    guard number <= areas.count else {
      return nil
    }
    return areas[number - 1]
  }

  /// The group that holds the areas of the tracks, wherever it sits under the window.
  private static func contents(of node: any AXNode) -> (any AXNode)? {
    if node.description == contentsGroup {
      return node
    }
    for child in node.children {
      if let found = contents(of: child) {
        return found
      }
    }
    return nil
  }

  /// One part of a help text with the spaces around it taken off.
  private static func trimmed(_ text: Substring) -> String {
    String(text).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
