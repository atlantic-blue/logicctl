import ApplicationServices
import CoreGraphics
import Foundation

/// What this Mac lets logicctl do, and the prompt that asks for what it does not.
///
/// Accessibility lets logicctl read the interface of Logic and press things in it. Screen Recording
/// lets it save the picture of the window that every step of a session carries. Without both,
/// logicctl can do nothing with Logic at all, so a command answers before it asks Logic anything.
///
/// Every read and every prompt is a closure the caller gives. The pipeline has no grant and no
/// window server, so a test drives this with the answers it wants and macOS opens nothing.
public struct Grants {
  /// Reads whether this Mac granted one thing to logicctl.
  public typealias Reader = () -> Bool

  /// Opens the prompt of macOS for one grant.
  public typealias Prompt = () -> Void

  /// Reads whether logicctl may read the interface of Logic and drive it.
  public let accessibility: Reader

  /// Reads whether logicctl may take a picture of the window of Logic.
  public let screenRecording: Reader

  /// Opens the prompt for Accessibility.
  public let promptForAccessibility: Prompt

  /// Opens the prompt for Screen Recording.
  public let promptForScreenRecording: Prompt

  public init(
    accessibility: @escaping Reader,
    screenRecording: @escaping Reader,
    promptForAccessibility: @escaping Prompt,
    promptForScreenRecording: @escaping Prompt
  ) {
    self.accessibility = accessibility
    self.screenRecording = screenRecording
    self.promptForAccessibility = promptForAccessibility
    self.promptForScreenRecording = promptForScreenRecording
  }
}

extension Grants {
  /// The grants of this process, as macOS answers them now.
  ///
  /// A grant keys on the signature of the binary, so a build signed with another identity is
  /// another application to macOS and starts with neither grant (story S0.2). The pipeline never
  /// reads these, because a runner grants nothing and there is nobody to answer a prompt.
  public static func live() -> Grants {
    Grants(
      accessibility: { AXIsProcessTrusted() },
      screenRecording: { CGPreflightScreenCaptureAccess() },
      promptForAccessibility: {
        // The key of the option is the string that `kAXTrustedCheckOptionPrompt` carries. That
        // constant is an unmanaged global, and reading one from here is not concurrency safe.
        let options: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
      },
      promptForScreenRecording: { _ = CGRequestScreenCaptureAccess() })
  }
}
