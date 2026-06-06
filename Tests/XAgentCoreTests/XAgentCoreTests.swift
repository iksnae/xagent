import XCTest
@testable import XAgentCore

/// End-to-end integration test: wires Agent + ToolRegistry + MockProvider + AgentRuntime
/// and runs a full task loop, mirroring the CLI smoke test but suited for CI.
final class XAgentCoreTests: XCTestCase {

    func testEndToEndWithToolCall() async throws {
        // 1. Create the LLM provider (mock).
        let provider = MockProvider()

        // 2. Build a tool registry with echo and date tools.
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

        // 3. Create an agent.
        let agent = DefaultAgent(
            identifier: "integration-test-agent",
            systemPrompt: "You are a helpful assistant. Use tools when needed."
        )

        // 4. Wire up the runtime.
        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: toolRegistry,
            provider: provider
        )

        // 5. Run with a sample task.
        let task = "Echo hello world and tell me the date"
        let result = try await runtime.run(task: task)

        // The MockProvider returns a canned response (no <tool_call> blocks),
        // so the integration test primarily verifies that the full pipeline
        // composes without errors and produces non-empty output.
        XCTAssertFalse(result.isEmpty, "Result should not be empty")
        XCTAssertTrue(
            result.contains("Mock response for:"),
            "Result should contain the mock provider's canned response prefix"
        )
        XCTAssertTrue(
            result.contains("You are a helpful assistant"),
            "Prompt should carry the system prompt into the mock response"
        )
        XCTAssertTrue(
            result.contains(task),
            "Prompt should carry the user task into the mock response"
        )
    }

    func testEndToEndWithToolCallResponse() async throws {
        // A provider that simulates a tool-call response.
        let toolCallProvider = TestToolCallProvider(
            response: """
            Let me echo that for you.

            <tool_call>
            name: echo
            message: integration test
            </tool_call>
            """
        )

        let toolRegistry = ToolRegistry()
        try await toolRegistry.register(TypedTool<EchoParams, EchoResult>(
            name: "echo",
            description: "Echoes input back.",
            parameterSchema: [
                ToolParameter(name: "message", type: "string", description: "Text to echo.", required: true)
            ],
            handler: { params in
                EchoResult(echoed: params.message)
            }
        ))

        let agent = DefaultAgent(
            identifier: "tool-call-agent",
            systemPrompt: "You are helpful."
        )

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: toolRegistry,
            provider: toolCallProvider
        )

        let result = try await runtime.run(task: "Echo integration test")

        XCTAssertTrue(result.contains("integration test"), "Result should contain the echoed message")
        XCTAssertTrue(result.contains("[Tool echo result]"), "Result should contain the tool result annotation")
    }
}
