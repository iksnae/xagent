import XCTest
@testable import XAgentCore

// MARK: - Reusable Codable test payloads

struct EchoParams: ToolParameters {
    let message: String
}

struct EchoResult: ToolResult {
    let echoed: String
}

struct AddParams: ToolParameters {
    let a: Int
    let b: Int
}

struct AddResult: ToolResult {
    let sum: Int
}

struct GreetParams: ToolParameters {
    let name: String
    let title: String?
}

struct GreetResult: ToolResult {
    let greeting: String
}

struct LogParams: ToolParameters {
    let level: String
}

struct LogResult: ToolResult {
    let output: String
}

struct EmptyParams: ToolParameters {}

struct EmptyResult: ToolResult {
    let pong: String
}

struct SearchParams: ToolParameters {
    let query: String
    let limit: Int?
    let offset: Int?
}

struct SearchResult: ToolResult {
    let results: String
}

struct NowParams: ToolParameters {}
struct NowResult: ToolResult {
    let time: String
}

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

    // MARK: - Tool construction (TypedTool)

    func testToolConstruction() {
        let tool = TypedTool<GreetParams, GreetResult>(
            name: "greet",
            description: "Returns a greeting.",
            parameterSchema: [
                ToolParameter(
                    name: "name",
                    type: "string",
                    description: "Who to greet.",
                    required: true
                )
            ],
            handler: { params in
                GreetResult(greeting: "hello \(params.name)")
            }
        )

        XCTAssertEqual(tool.name, "greet")
        XCTAssertEqual(tool.description, "Returns a greeting.")
        XCTAssertEqual(tool.parameterSchema.count, 1)
        XCTAssertEqual(tool.parameterSchema.first?.name, "name")
    }

    func testToolConstructionWithMultipleParameters() {
        let tool = TypedTool<SearchParams, SearchResult>(
            name: "search",
            description: "Search for items.",
            parameterSchema: [
                ToolParameter(name: "query", type: "string", description: "Search query.", required: true),
                ToolParameter(name: "limit", type: "integer", description: "Max results.", required: false),
                ToolParameter(name: "offset", type: "integer", description: "Pagination offset.", required: false),
            ],
            handler: { _ in SearchResult(results: "results") }
        )

        XCTAssertEqual(tool.parameterSchema.count, 3)
        XCTAssertEqual(tool.parameterSchema.map(\.name), ["query", "limit", "offset"])
    }

    func testToolConstructionWithNoParameters() {
        let tool = TypedTool<NowParams, NowResult>(
            name: "now",
            description: "Returns the current time.",
            parameterSchema: [],
            handler: { _ in NowResult(time: "12:00") }
        )

        XCTAssertEqual(tool.parameterSchema.count, 0)
    }

    // MARK: - Handler invocation (round-trip bridging)

    func testHandlerInvocationWithMatchingParams() async throws {
        let tool = TypedTool<AddParams, AddResult>(
            name: "add",
            description: "Adds two numbers.",
            parameterSchema: [
                ToolParameter(name: "a", type: "integer", description: "First operand.", required: true),
                ToolParameter(name: "b", type: "integer", description: "Second operand.", required: true),
            ],
            handler: { params in
                AddResult(sum: params.a + params.b)
            }
        )

        let input = try JSONEncoder().encode(AddParams(a: 3, b: 4))
        let output = try await tool.handle(input)
        let result = try JSONDecoder().decode(AddResult.self, from: output)

        XCTAssertEqual(result.sum, 7)
    }

    func testHandlerInvocationWithFewerParams() async throws {
        let tool = TypedTool<GreetParams, GreetResult>(
            name: "greet",
            description: "Greets a user with optional title.",
            parameterSchema: [
                ToolParameter(name: "name", type: "string", description: "User name.", required: true),
                ToolParameter(name: "title", type: "string", description: "Honorific.", required: false),
            ],
            handler: { params in
                let title = params.title ?? ""
                let prefix = title.isEmpty ? "Hello" : "Hello \(title)"
                return GreetResult(greeting: "\(prefix) \(params.name)")
            }
        )

        // Only provide the required param — title is omitted.
        let input = try JSONEncoder().encode(GreetParams(name: "Alice", title: nil))
        let output = try await tool.handle(input)
        let result = try JSONDecoder().decode(GreetResult.self, from: output)

        XCTAssertEqual(result.greeting, "Hello Alice")
    }

    func testHandlerInvocationWithExtraParams() async throws {
        let tool = TypedTool<LogParams, LogResult>(
            name: "log",
            description: "Logs a message.",
            parameterSchema: [
                ToolParameter(name: "level", type: "string", description: "Log level.", required: true),
            ],
            handler: { params in
                // Handler only sees the declared key — Codable ignores unknown keys.
                LogResult(output: "\(params.level): logged")
            }
        )

        // Include extra keys that LogParams does not declare.
        let rawJSON: [String: Any] = [
            "level": "error",
            "source": "unit-test",
            "line": 42,
        ]
        let input = try JSONSerialization.data(withJSONObject: rawJSON)
        let output = try await tool.handle(input)
        let result = try JSONDecoder().decode(LogResult.self, from: output)

        XCTAssertTrue(result.output.contains("error"))
        XCTAssertTrue(result.output.contains("logged"))
    }

    func testHandlerInvocationWithEmptyParams() async throws {
        let tool = TypedTool<EmptyParams, EmptyResult>(
            name: "ping",
            description: "Always returns pong.",
            parameterSchema: [],
            handler: { _ in
                EmptyResult(pong: "pong")
            }
        )

        let input = try JSONEncoder().encode(EmptyParams())
        let output = try await tool.handle(input)
        let result = try JSONDecoder().decode(EmptyResult.self, from: output)

        XCTAssertEqual(result.pong, "pong")
    }

    func testHandlerThrowsError() async throws {
        let tool = TypedTool<EmptyParams, EmptyResult>(
            name: "crash",
            description: "Always throws.",
            parameterSchema: [],
            handler: { _ in
                throw NSError(domain: "ToolError", code: 99, userInfo: [NSLocalizedDescriptionKey: "simulated failure"])
            }
        )

        do {
            let input = try JSONEncoder().encode(EmptyParams())
            _ = try await tool.handle(input)
            XCTFail("Expected handler to throw")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 99)
            XCTAssertEqual(error.domain, "ToolError")
        }
    }
}
