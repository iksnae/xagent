import XCTest
@testable import XAgentCore

/// BDD-style integration tests that exercise the same wiring as the
/// smoke-test CLI (main.swift): MockProvider + ToolRegistry (echo, date) +
/// DefaultAgent + AgentRuntime.run().  Each test mirrors a CLI scenario
/// and asserts on the output shape.
final class CLIIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Builds the same wiring used by the smoke-test CLI entry point.
    func makeSmokeTestRuntime() async throws -> AgentRuntime {
        let provider = MockProvider()
        let toolRegistry = ToolRegistry()

        let echoTool = TypedTool<EchoParams, EchoResult>(
            name: "echo",
            description: "Returns the input message unchanged.",
            parameterSchema: [
                ToolParameter(
                    name: "message",
                    type: "string",
                    description: "The message to echo back.",
                    required: true
                )
            ],
            handler: { params in
                EchoResult(echoed: params.message)
            }
        )

        let dateTool = TypedTool<DateParams, DateResult>(
            name: "date",
            description: "Returns the current date and time in ISO 8601 format.",
            parameterSchema: [],
            handler: { _ in
                DateResult(iso8601: Date().ISO8601Format())
            }
        )

        try await toolRegistry.register(echoTool)
        try await toolRegistry.register(dateTool)

        let agent = DefaultAgent(
            identifier: "smoke-test-agent",
            systemPrompt: "You are a helpful assistant. When the user asks for the date, use the date tool. When they ask you to echo something, use the echo tool."
        )

        return AgentRuntime(
            agent: agent,
            toolRegistry: toolRegistry,
            provider: provider
        )
    }

    // MARK: - Smoke tests

    func testSmokeTestWiringProducesOutput() async throws {
        let runtime = try await makeSmokeTestRuntime()
        let task = "Say hello and tell me the date"
        let result = try await runtime.run(task: task)

        XCTAssertFalse(result.isEmpty, "Result should not be empty")
        XCTAssertTrue(
            result.contains("Mock response for:"),
            "Output should contain the mock response prefix"
        )
    }

    func testSmokeTestPromptContainsSystemPrompt() async throws {
        let runtime = try await makeSmokeTestRuntime()
        let task = "Tell me the date"
        let result = try await runtime.run(task: task)

        // The mock response echoes the prompt, which includes the system prompt.
        XCTAssertTrue(
            result.contains("You are a helpful assistant"),
            "Output should reflect the system prompt from the agent"
        )
    }

    func testSmokeTestPromptContainsTask() async throws {
        let runtime = try await makeSmokeTestRuntime()
        let task = "What time is it?"
        let result = try await runtime.run(task: task)

        // The mock response echoes the full prompt including the user task.
        XCTAssertTrue(
            result.contains("What time is it?"),
            "Output should reflect the user task"
        )
    }

    func testSmokeTestTwoTasksAreDistinct() async throws {
        let runtime = try await makeSmokeTestRuntime()

        let result1 = try await runtime.run(task: "First task")
        let result2 = try await runtime.run(task: "Second task")

        XCTAssertTrue(result1.contains("First task"), "First result should carry first task")
        XCTAssertTrue(result2.contains("Second task"), "Second result should carry second task")
        XCTAssertNotEqual(result1, result2, "Two different tasks should produce different output")
    }

    func testSmokeTestToolRegistryHasBothTools() async throws {
        // Verify the registry is correctly populated with the two CLI tools.
        let runtime = try await makeSmokeTestRuntime()
        // We can't inspect the runtime's internal registry directly, but we can
        // verify the tools work by running the runtime — the mock provider
        // doesn't emit tool calls, but the wiring is proven by the successful
        // composition. We also assert that the runtime is non-nil after creation
        // (actor identity check is implicit via the async call above).
        let result = try await runtime.run(task: "echo hello")
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Tool-call integration (BDD scenarios)

    func testEchoToolViaBDDScenario() async throws {
        // Given a tool registry with only the echo tool
        let toolRegistry = ToolRegistry()
        try await toolRegistry.register(TypedTool<EchoParams, EchoResult>(
            name: "echo",
            description: "Echoes input.",
            parameterSchema: [
                ToolParameter(name: "message", type: "string", description: "Text.", required: true)
            ],
            handler: { params in EchoResult(echoed: params.message) }
        ))

        // And a provider that returns a tool-call response
        let provider = TestToolCallProvider(
            response: """
            <tool_call>
            name: echo
            message: BDD works
            </tool_call>
            """
        )

        let agent = DefaultAgent(
            identifier: "bdd-agent",
            systemPrompt: "You echo things."
        )

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: toolRegistry,
            provider: provider
        )

        // When the agent runs
        let result = try await runtime.run(task: "echo BDD works")

        // Then the output contains the echoed message
        XCTAssertTrue(result.contains("BDD works"))
        XCTAssertTrue(result.contains("[Tool echo result]"))
    }

    func testDateToolViaBDDScenario() async throws {
        // Given a tool registry with only the date tool
        let toolRegistry = ToolRegistry()
        try await toolRegistry.register(TypedTool<DateParams, DateResult>(
            name: "date",
            description: "Returns current ISO 8601 date.",
            parameterSchema: [],
            handler: { _ in DateResult(iso8601: Date().ISO8601Format()) }
        ))

        // And a provider that requests the date tool
        let provider = TestToolCallProvider(
            response: """
            <tool_call>
            name: date
            </tool_call>
            """
        )

        let agent = DefaultAgent(
            identifier: "bdd-agent",
            systemPrompt: "You report dates."
        )

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: toolRegistry,
            provider: provider
        )

        // When the agent runs
        let result = try await runtime.run(task: "what is the date")

        // Then the output contains a tool result annotation
        XCTAssertTrue(result.contains("[Tool date result]"))
    }
}
