import XCTest
@testable import XAgentCore

final class ToolRegistryTests: XCTestCase {

    // MARK: - Helpers

    func makeEchoTool(name: String = "echo") -> Tool {
        Tool(
            name: name,
            description: "Echoes the message parameter back to the caller.",
            parameters: [
                ToolParameter(
                    name: "message",
                    type: "string",
                    description: "The text to echo.",
                    required: true
                )
            ],
            handler: { params in
                params["message"] ?? "(no message)"
            }
        )
    }

    // MARK: - Registration

    func testRegistration() async throws {
        let registry = ToolRegistry()
        let tool = makeEchoTool()
        try await registry.register(tool)

        let tools = await registry.allTools
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "echo")
    }

    func testDuplicateRejection() async throws {
        let registry = ToolRegistry()
        let tool = makeEchoTool()
        try await registry.register(tool)

        do {
            try await registry.register(tool)
            XCTFail("Expected duplicate registration to throw")
        } catch let error as ToolRegistryError {
            switch error {
            case .duplicateToolName(let name):
                XCTAssertEqual(name, "echo")
            }
        }
    }

    func testDuplicateRejectionDifferentInstanceSameName() async throws {
        let registry = ToolRegistry()
        let toolA = makeEchoTool(name: "search")
        let toolB = makeEchoTool(name: "search")
        try await registry.register(toolA)

        do {
            try await registry.register(toolB)
            XCTFail("Expected duplicate registration to throw")
        } catch let error as ToolRegistryError {
            switch error {
            case .duplicateToolName(let name):
                XCTAssertEqual(name, "search")
            }
        }
    }

    // MARK: - Lookup

    func testSuccessfulLookup() async throws {
        let registry = ToolRegistry()
        let tool = makeEchoTool(name: "greet")
        try await registry.register(tool)

        let found = await registry.lookup(by: "greet")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "greet")
        XCTAssertEqual(found?.description, tool.description)
    }

    func testMissingLookup() async throws {
        let registry = ToolRegistry()
        let found = await registry.lookup(by: "nonexistent")
        XCTAssertNil(found)
    }

    // MARK: - Enumeration

    func testAllToolsInitiallyEmpty() async throws {
        let registry = ToolRegistry()
        let tools = await registry.allTools
        XCTAssertEqual(tools.count, 0)
    }

    func testAllToolsReturnsRegisteredTools() async throws {
        let registry = ToolRegistry()
        try await registry.register(makeEchoTool(name: "a"))
        try await registry.register(makeEchoTool(name: "b"))
        try await registry.register(makeEchoTool(name: "c"))

        let tools = await registry.allTools
        XCTAssertEqual(tools.count, 3)
        let names = tools.map(\.name).sorted()
        XCTAssertEqual(names, ["a", "b", "c"])
    }

    // MARK: - Handler invocation

    func testHandlerIsInvokable() async throws {
        let tool = makeEchoTool(name: "upper")
        let result = try await tool.handler(["message": "hello"])
        XCTAssertEqual(result, "hello")
    }
}
