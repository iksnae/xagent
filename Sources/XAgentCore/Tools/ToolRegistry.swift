/// Errors thrown by ToolRegistry operations.
public enum ToolRegistryError: Error, Sendable {
    /// Attempted to register a tool whose name is already present.
    case duplicateToolName(String)
}

/// Thread-safe registry that stores AnyTool-conforming tools keyed by name.
/// Registration rejects duplicates; lookups are O(1) and return an optional.
public actor ToolRegistry {
    private var tools: [String: any AnyTool]

    public init() {
        self.tools = [:]
    }

    /// Register a new tool.  Throws `ToolRegistryError.duplicateToolName`
    /// when a tool with the same name already exists.
    public func register(_ tool: any AnyTool) throws {
        guard tools[tool.name] == nil else {
            throw ToolRegistryError.duplicateToolName(tool.name)
        }
        tools[tool.name] = tool
    }

    /// Returns the tool registered under `name`, or `nil` when no match is found.
    public func lookup(by name: String) -> (any AnyTool)? {
        tools[name]
    }

    /// All currently-registered tools in no guaranteed order.
    public var allTools: [any AnyTool] {
        Array(tools.values)
    }
}
