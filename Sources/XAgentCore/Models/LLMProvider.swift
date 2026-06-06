import Foundation

/// Protocol that defines the interface for a language model provider.
/// Implementations may be local, remote, or mock.
public protocol LLMProvider: Sendable {
    /// Synchronous (single-turn) completion: prompt → full response text.
    func complete(prompt: String) async throws -> String

    /// Streaming completion: prompt → async sequence of text chunks.
    func stream(prompt: String) -> AsyncThrowingStream<String, Error>
}

/// A deterministic mock provider that returns canned responses.
/// Useful for testing and development without a live backend.
public struct MockProvider: LLMProvider {
    public init() {}

    public func complete(prompt: String) async throws -> String {
        "Mock response for: \(prompt)"
    }

    public func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let chunks = ["Mock ", "streaming ", "response ", "for: ", prompt]
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
