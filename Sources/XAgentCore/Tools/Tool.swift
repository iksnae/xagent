/// Describes a single parameter accepted by a Tool.
public struct ToolParameter: Sendable {
    public let name: String
    public let type: String
    public let description: String
    public let required: Bool

    public init(name: String, type: String, description: String, required: Bool) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

/// A callable tool registered with the agent runtime.  Each tool has a name,
/// a human-readable description, a typed parameter schema, and an async
/// handler that receives string-keyed parameter values and returns a result.
public struct Tool: Sendable {
    public let name: String
    public let description: String
    public let parameters: [ToolParameter]
    public let handler: @Sendable ([String: String]) async throws -> String

    public init(
        name: String,
        description: String,
        parameters: [ToolParameter],
        handler: @escaping @Sendable ([String: String]) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.handler = handler
    }
}
