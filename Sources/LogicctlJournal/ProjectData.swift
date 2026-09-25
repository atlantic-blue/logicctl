import CryptoKit
import Foundation

/// The plugin settings that one saved project holds.
public enum ProjectData {
  /// One plugin chunk of a saved project.
  public struct PluginChunk: Sendable, Equatable {
    /// The name Logic wrote in the chunk, or nothing when the chunk carries no name.
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
    /// The file could not be read.
    case unreadableFile(path: String)

    /// A chunk says it is longer than what is left of the file.
    case chunkRunsPastTheEnd(offset: Int, length: Int)
  }

  /// The plugin chunks of one saved project, in the order they sit in the file.
  public static func pluginChunks(ofFileAt url: URL) throws -> [PluginChunk] {
    guard let contents = try? Data(contentsOf: url) else {
      throw Refusal.unreadableFile(path: url.path)
    }
    return try pluginChunks(of: contents)
  }

  /// The plugin chunks of the bytes of one saved project.
  public static func pluginChunks(of contents: Data) throws -> [PluginChunk] {
    []
  }
}
