import Foundation

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

// MARK: - Structured Tool I/O

/// The typed input a tool handler receives.
public protocol ToolParameters: Codable, Sendable {}

/// The typed output a tool handler returns.
public protocol ToolResult: Codable, Sendable {}

/// A type-erased tool that can be stored homogeneously.
/// Tools accept JSON-encoded `Data` for their parameters and return
/// JSON-encoded `Data` for their results.
public protocol AnyTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameterSchema: [ToolParameter] { get }

    func handle(_ input: Data) async throws -> Data
}

/// A generic, typed tool that conforms to `AnyTool`.
///
/// `TypedTool<Params, Result>` wraps a typed `handler` and bridges between
/// JSON-encoded `Data` (the `AnyTool` contract) and the strongly-typed
/// parameter/result types the handler expects.
public struct TypedTool<Params: ToolParameters, Result: ToolResult>: AnyTool {
    public let name: String
    public let description: String
    public let parameterSchema: [ToolParameter]
    public let handler: @Sendable (Params) async throws -> Result

    public init(
        name: String,
        description: String,
        parameterSchema: [ToolParameter],
        handler: @escaping @Sendable (Params) async throws -> Result
    ) {
        self.name = name
        self.description = description
        self.parameterSchema = parameterSchema
        self.handler = handler
    }

    /// Decodes `Params` from JSON data, invokes the typed handler, and
    /// encodes the `Result` back to JSON data.
    public func handle(_ input: Data) async throws -> Data {
        let decoder = JSONDecoder()
        let params = try decoder.decode(Params.self, from: input)
        let result = try await handler(params)
        let encoder = JSONEncoder()
        return try encoder.encode(result)
    }
}
