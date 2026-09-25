import Foundation

/// The settings of the plugins a project holds, read from one saved `ProjectData` file.
///
/// Logic writes a project as `Alternatives/<n>/ProjectData`, a run of chunks, each one named by a
/// tag of 4 characters. The settings of one plugin sit in one chunk tagged `UCuA`.
///
/// The hash is taken over one chunk and never over the file, because a save rewrites bytes that
/// belong to no plugin. Two saves of one project with nothing changed between them differ in the
/// header and in one byte of the `gnoS` song chunk, so a hash of the file moves at every save and
/// says nothing about the plugins.
///
/// Every number here was measured against Logic 12.3.1 and a project of 5 channel strips. Nothing
/// reads Logic: a hash is read from a file that Logic has already saved.
public enum ProjectData {
  /// One plugin chunk of a saved project.
  public struct PluginChunk: Sendable, Equatable {
    /// The name Logic wrote in the chunk, for example `Channel EQ`, or nothing when the chunk
    /// carries no name. A chunk that holds the state of a plugin rather than its settings, such
    /// as a property list, carries none.
    public var name: String?

    /// Where the chunk starts in the file.
    public var offset: Int

    /// How many bytes the chunk holds.
    public var length: Int

    /// The SHA-256 of the bytes of the chunk, in lower case hexadecimal.
    public var stateHash: String

    public init(name: String?, offset: Int, length: Int, stateHash: String) {
      self.name = name
      self.offset = offset
      self.length = length
      self.stateHash = stateHash
    }
  }

  /// What reading a saved project can refuse.
  public enum Refusal: Error, Equatable {
    /// The file is not there, or nothing can read it.
    case unreadableFile(path: String)

    /// A chunk says it is longer than what is left of the file. A file that was cut short reads
    /// as a plugin whose settings are half there, and a hash of half a chunk is a hash of
    /// nothing.
    case chunkRunsPastTheEnd(offset: Int, length: Int)
  }

  /// The tag that names a plugin chunk.
  static let pluginTag: [UInt8] = Array("UCuA".utf8)

  /// Where a chunk says how long its header is, and the one length that Logic 12.3.1 writes.
  static let headerLengthAt = 10
  static let headerLength = 36

  /// Where a chunk says how many bytes its body holds.
  static let bodyLengthAt = 28

  /// Where the name of the plugin sits, and how many bytes it may take. The four characters of
  /// the manufacturer, `GAME` for the plugins of Logic, follow the field.
  static let nameAt = 156
  static let nameLength = 12

  /// The plugin chunks of one saved project, in the order they sit in the file.
  public static func pluginChunks(ofFileAt url: URL) throws -> [PluginChunk] {
    guard let contents = try? Data(contentsOf: url) else {
      throw Refusal.unreadableFile(path: url.path)
    }
    return try pluginChunks(of: contents)
  }

  /// The plugin chunks of the bytes of one saved project.
  ///
  /// The scan goes on after the end of each chunk it reads, so the same four characters inside the
  /// body of a chunk cannot be read as a chunk of its own.
  public static func pluginChunks(of contents: Data) throws -> [PluginChunk] {
    let bytes = [UInt8](contents)
    var chunks: [PluginChunk] = []
    var from = 0
    while let start = firstPluginTag(in: bytes, from: from) {
      guard start + headerLength <= bytes.count,
        number(in: bytes, at: start + headerLengthAt) == headerLength
      else {
        // Four characters that read as the tag, in something that is not a chunk.
        from = start + 1
        continue
      }
      let length = headerLength + number(in: bytes, at: start + bodyLengthAt)
      guard start + length <= bytes.count else {
        throw Refusal.chunkRunsPastTheEnd(offset: start, length: length)
      }
      let chunk = bytes[start..<(start + length)]
      chunks.append(
        PluginChunk(
          name: name(in: chunk),
          offset: start,
          length: length,
          stateHash: InputFile.sha256(of: Data(chunk))))
      from = start + length
    }
    return chunks
  }

  /// Where the next plugin tag sits, at or after one place in the bytes.
  static func firstPluginTag(in bytes: [UInt8], from: Int) -> Int? {
    guard from >= 0, bytes.count >= pluginTag.count else {
      return nil
    }
    var at = from
    while at + pluginTag.count <= bytes.count {
      if pluginTag.indices.allSatisfy({ bytes[at + $0] == pluginTag[$0] }) {
        return at
      }
      at += 1
    }
    return nil
  }

  /// One number of 4 bytes, smallest byte first, as Logic writes it.
  static func number(in bytes: [UInt8], at index: Int) -> Int {
    guard index >= 0, index + 4 <= bytes.count else {
      return 0
    }
    var value = 0
    for step in 0..<4 {
      value |= Int(bytes[index + step]) << (8 * step)
    }
    return value
  }

  /// The name one chunk carries, or nothing when the field holds no name.
  ///
  /// The name ends at a zero inside its own field. A field that runs to its end without one is
  /// some other part of the chunk that happens to read as text.
  static func name(in chunk: ArraySlice<UInt8>) -> String? {
    guard chunk.count >= nameAt + nameLength else {
      return nil
    }
    var text = ""
    for step in 0..<nameLength {
      let byte = chunk[chunk.startIndex + nameAt + step]
      if byte == 0 {
        return text.isEmpty ? nil : text
      }
      guard byte >= 0x20, byte < 0x7f else {
        return nil
      }
      text.append(Character(UnicodeScalar(byte)))
    }
    return nil
  }
}
