import XCTest
@testable import XAgentCore

/// A test provider that returns a preconfigured response
/// and tracks invocations via a side-channel flag.
final class TestToolCallProvider: LLMProvider, @unchecked Sendable {
    let cannedResponse: String
    var completeCallCount = 0
    var lastPrompt: String?

    init(response: String) {
        self.cannedResponse = response
    }

    func complete(prompt: String) async throws -> String {
        completeCallCount += 1
        lastPrompt = prompt
        return cannedResponse
    }

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(self.cannedResponse)
            continuation.finish()
        }
    }
}

final class AgentRuntimeTests: XCTestCase {

    // MARK: - Helpers

    func makeEchoTool() -> Tool {
        Tool(
            name: "echo",
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

    func makeTestAgent() -> DefaultAgent {
        DefaultAgent(
            identifier: "test-agent",
            systemPrompt: "You are a helpful assistant."
        )
    }

    // MARK: - Tool-call execution

    func testRunWithToolCallExecutesToolAndReturnsResult() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry()
        try await registry.register(makeEchoTool())

        let toolCallResponse = """
        I'll echo that for you.

        <tool_call>
        name: echo
        message: hello world
        </tool_call>
        """
        let provider = TestToolCallProvider(response: toolCallResponse)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        let result = try await runtime.run(task: "Echo hello world")

        XCTAssertFalse(result.isEmpty, "Result should not be empty")
        XCTAssertTrue(result.contains("hello world"), "Result should contain the echoed message")
        XCTAssertEqual(provider.completeCallCount, 1, "Provider should have been called exactly once")
    }

    func testRunWithoutToolCallReturnsRawResponse() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry()
        try await registry.register(makeEchoTool())

        let plainResponse = "Sure, I can help with that!"
        let provider = TestToolCallProvider(response: plainResponse)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        let result = try await runtime.run(task: "Say hello")

        XCTAssertEqual(result, plainResponse)
        XCTAssertEqual(provider.completeCallCount, 1)
    }

    func testToolNotFoundThrowsError() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry() // empty — no tools registered

        let toolCallResponse = """
        <tool_call>
        name: nonexistent_tool
        param: value
        </tool_call>
        """
        let provider = TestToolCallProvider(response: toolCallResponse)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        do {
            _ = try await runtime.run(task: "Use a missing tool")
            XCTFail("Expected toolNotFound error")
        } catch let error as AgentRuntimeError {
            switch error {
            case .toolNotFound(let name):
                XCTAssertEqual(name, "nonexistent_tool")
            case .toolExecutionFailed:
                XCTFail("Expected toolNotFound, got toolExecutionFailed")
            }
        }
    }

    func testToolExecutionFailedThrowsError() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry()

        // Register a tool whose handler always throws.
        let failingTool = Tool(
            name: "flaky",
            description: "Always throws an error.",
            parameters: [],
            handler: { _ in
                throw NSError(domain: "ToolFlake", code: 42, userInfo: [NSLocalizedDescriptionKey: "flake"])
            }
        )
        try await registry.register(failingTool)

        let toolCallResponse = """
        <tool_call>
        name: flaky
        </tool_call>
        """
        let provider = TestToolCallProvider(response: toolCallResponse)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        do {
            _ = try await runtime.run(task: "Trigger the flaky tool")
            XCTFail("Expected toolExecutionFailed error")
        } catch let error as AgentRuntimeError {
            switch error {
            case .toolExecutionFailed(let name, let underlying):
                XCTAssertEqual(name, "flaky")
                let nsError = underlying as NSError
                XCTAssertEqual(nsError.domain, "ToolFlake")
                XCTAssertEqual(nsError.code, 42)
            case .toolNotFound:
                XCTFail("Expected toolExecutionFailed, got toolNotFound")
            }
        }
    }

    // MARK: - Prompt construction

    func testPromptIncludesSystemPromptAndTask() async throws {
        let agent = DefaultAgent(
            identifier: "test-agent",
            systemPrompt: "You are a test bot."
        )
        let registry = ToolRegistry()
        let plainResponse = "Got it."
        let provider = TestToolCallProvider(response: plainResponse)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        _ = try await runtime.run(task: "Do something")

        let prompt = provider.lastPrompt ?? ""
        XCTAssertTrue(prompt.contains("You are a test bot."), "Prompt should include system prompt")
        XCTAssertTrue(prompt.contains("Do something"), "Prompt should include the user task")
    }

    // MARK: - Multiple tool calls

    func testRunWithMultipleToolCallsExecutesAll() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry()
        try await registry.register(makeEchoTool())

        let response = """
        Let me echo twice.

        <tool_call>
        name: echo
        message: first
        </tool_call>

        <tool_call>
        name: echo
        message: second
        </tool_call>
        """
        let provider = TestToolCallProvider(response: response)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        let result = try await runtime.run(task: "Echo twice")

        XCTAssertTrue(result.contains("first"), "Result should contain first echo")
        XCTAssertTrue(result.contains("second"), "Result should contain second echo")
        XCTAssertEqual(provider.completeCallCount, 1)
    }

    // MARK: - Streaming

    func testRunStreamingWithMockProviderYieldsChunksInOrder() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry()
        let provider = MockProvider()

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        let stream = await runtime.runStreaming(task: "Hello")

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        let expectedChunks = [
            "Mock ",
            "streaming ",
            "response ",
            "for: ",
            "[System]: You are a helpful assistant.\n\n[User]: Hello",
        ]
        XCTAssertEqual(chunks, expectedChunks, "Streaming chunks should match MockProvider output in order")
    }
}
