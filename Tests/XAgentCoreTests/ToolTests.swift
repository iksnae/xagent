import XCTest
@testable import XAgentCore

final class ToolTests: XCTestCase {

    // MARK: - ToolParameter tests

    func testToolParameterConstruction() {
        let param = ToolParameter(
            name: "message",
            type: "string",
            description: "The message to echo.",
            required: true
        )

        XCTAssertEqual(param.name, "message")
        XCTAssertEqual(param.type, "string")
        XCTAssertEqual(param.description, "The message to echo.")
        XCTAssertTrue(param.required)
    }

    func testToolParameterNotRequired() {
        let param = ToolParameter(
            name: "count",
            type: "integer",
            description: "Optional repeat count.",
            required: false
        )

        XCTAssertEqual(param.name, "count")
        XCTAssertEqual(param.type, "integer")
        XCTAssertFalse(param.required)
    }

    func testToolParameterEmptyDescription() {
        let param = ToolParameter(
            name: "x",
            type: "float",
            description: "",
            required: true
        )

        XCTAssertEqual(param.description, "")
    }

    // MARK: - Tool construction

    func testToolConstruction() {
        let tool = Tool(
            name: "greet",
            description: "Returns a greeting.",
            parameters: [
                ToolParameter(
                    name: "name",
                    type: "string",
                    description: "Who to greet.",
                    required: true
                )
            ],
            handler: { _ in "hello" }
        )

        XCTAssertEqual(tool.name, "greet")
        XCTAssertEqual(tool.description, "Returns a greeting.")
        XCTAssertEqual(tool.parameters.count, 1)
        XCTAssertEqual(tool.parameters.first?.name, "name")
    }

    func testToolConstructionWithMultipleParameters() {
        let tool = Tool(
            name: "search",
            description: "Search for items.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Search query.", required: true),
                ToolParameter(name: "limit", type: "integer", description: "Max results.", required: false),
                ToolParameter(name: "offset", type: "integer", description: "Pagination offset.", required: false),
            ],
            handler: { _ in "results" }
        )

        XCTAssertEqual(tool.parameters.count, 3)
        XCTAssertEqual(tool.parameters.map(\.name), ["query", "limit", "offset"])
    }

    func testToolConstructionWithNoParameters() {
        let tool = Tool(
            name: "now",
            description: "Returns the current time.",
            parameters: [],
            handler: { _ in "12:00" }
        )

        XCTAssertEqual(tool.parameters.count, 0)
    }

    // MARK: - Handler invocation

    func testHandlerInvocationWithMatchingParams() async throws {
        let tool = Tool(
            name: "add",
            description: "Adds two numbers.",
            parameters: [
                ToolParameter(name: "a", type: "integer", description: "First operand.", required: true),
                ToolParameter(name: "b", type: "integer", description: "Second operand.", required: true),
            ],
            handler: { params in
                let a = Int(params["a"] ?? "") ?? 0
                let b = Int(params["b"] ?? "") ?? 0
                return "\(a + b)"
            }
        )

        let result = try await tool.handler(["a": "3", "b": "4"])
        XCTAssertEqual(result, "7")
    }

    func testHandlerInvocationWithFewerParams() async throws {
        let tool = Tool(
            name: "greet",
            description: "Greets a user with optional title.",
            parameters: [
                ToolParameter(name: "name", type: "string", description: "User name.", required: true),
                ToolParameter(name: "title", type: "string", description: "Honorific.", required: false),
            ],
            handler: { params in
                let name = params["name"] ?? "there"
                let title = params["title"] ?? ""
                let prefix = title.isEmpty ? "Hello" : "Hello \(title)"
                return "\(prefix) \(name)"
            }
        )

        // Only provide the required param — title is omitted.
        let result = try await tool.handler(["name": "Alice"])
        XCTAssertEqual(result, "Hello Alice")
    }

    func testHandlerInvocationWithExtraParams() async throws {
        let tool = Tool(
            name: "log",
            description: "Logs a message.",
            parameters: [
                ToolParameter(name: "level", type: "string", description: "Log level.", required: true),
            ],
            handler: { params in
                // Handler ignores extra keys gracefully.
                "\(params["level"] ?? "info"): \(params.count) keys received"
            }
        )

        let result = try await tool.handler([
            "level": "error",
            "source": "unit-test",
            "line": "42",
        ])
        XCTAssertTrue(result.contains("error"))
        XCTAssertTrue(result.contains("3 keys received"))
    }

    func testHandlerInvocationWithEmptyParams() async throws {
        let tool = Tool(
            name: "ping",
            description: "Always returns pong.",
            parameters: [],
            handler: { params in
                "pong (\(params.count) params)"
            }
        )

        let result = try await tool.handler([:])
        XCTAssertEqual(result, "pong (0 params)")
    }

    func testHandlerThrowsError() async throws {
        let tool = Tool(
            name: "crash",
            description: "Always throws.",
            parameters: [],
            handler: { _ in
                throw NSError(domain: "ToolError", code: 99, userInfo: [NSLocalizedDescriptionKey: "simulated failure"])
            }
        )

        do {
            _ = try await tool.handler([:])
            XCTFail("Expected handler to throw")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 99)
            XCTAssertEqual(error.domain, "ToolError")
        }
    }
}
