import Foundation

/// Protocol describing an agent configuration.
/// An agent carries its identity, a system prompt that defines its persona,
/// and optional metadata (model preferences, tags, etc.).
public protocol Agent: Sendable {
    /// A unique identifier for this agent.
    var identifier: String { get }
    /// The system prompt that defines the agent's persona and capabilities.
    var systemPrompt: String { get }
    /// Optional key-value metadata (e.g. model preferences, tags).
    var metadata: [String: String] { get }
}

/// Default concrete implementation of the Agent protocol.
public struct DefaultAgent: Agent {
    public let identifier: String
    public let systemPrompt: String
    public let metadata: [String: String]

    public init(
        identifier: String,
        systemPrompt: String,
        metadata: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.systemPrompt = systemPrompt
        self.metadata = metadata
    }
}
