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

/// A streaming provider that yields a fixed sequence of chunks and tracks lastPrompt.
final class ChunkedStreamProvider: LLMProvider, @unchecked Sendable {
    let chunks: [String]
    var lastPrompt: String?

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func complete(prompt: String) async throws -> String {
        chunks.joined()
    }

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        lastPrompt = prompt
        return AsyncThrowingStream { continuation in
            for chunk in self.chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

/// A streaming provider that throws after yielding all chunks.
final class FailingStreamProvider: LLMProvider, @unchecked Sendable {
    let chunks: [String]
    let failure: Error

    init(chunks: [String], failure: Error) {
        self.chunks = chunks
        self.failure = failure
    }

    func complete(prompt: String) async throws -> String {
        throw failure
    }

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for chunk in self.chunks {
                continuation.yield(chunk)
            }
            continuation.finish(throwing: self.failure)
        }
    }
}

final class AgentRuntimeTests: XCTestCase {

    // MARK: - Helpers

    func makeEchoTool() -> TypedTool<EchoParams, EchoResult> {
        TypedTool<EchoParams, EchoResult>(
            name: "echo",
            description: "Echoes the message parameter back to the caller.",
            parameterSchema: [
                ToolParameter(
                    name: "message",
                    type: "string",
                    description: "The text to echo.",
                    required: true
                )
            ],
            handler: { params in
                EchoResult(echoed: params.message)
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
        let failingTool = TypedTool<EmptyParams, EmptyResult>(
            name: "flaky",
            description: "Always throws an error.",
            parameterSchema: [],
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

    // MARK: - Streaming prompt construction

    func testRunStreamingPromptIncludesSystemPromptAndTask() async throws {
        let agent = DefaultAgent(
            identifier: "test-agent",
            systemPrompt: "You are a streaming test bot."
        )
        let registry = ToolRegistry()
        let chunks: [String] = ["Hello ", "streaming ", "world!"]
        let provider = ChunkedStreamProvider(chunks: chunks)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        let stream = await runtime.runStreaming(task: "Do something streaming")
        // Drain the stream to completion so lastPrompt is captured.
        for try await _ in stream { }

        let prompt = provider.lastPrompt ?? ""
        XCTAssertTrue(prompt.contains("You are a streaming test bot."),
                       "Prompt should include system prompt")
        XCTAssertTrue(prompt.contains("Do something streaming"),
                       "Prompt should include the user task")
    }

    // MARK: - Streaming tool-call resolution
    //
    // These tests verify that runStreaming(task:) correctly parses tool-call
    // blocks from accumulated stream chunks, executes the requested tools,
    // and yields tool results as additional stream elements after the LLM
    // chunks. Error paths (toolNotFound, toolExecutionFailed) are also
    // verified to throw the correct AgentRuntimeError through the stream.

    func testRunStreamingWithToolCallYieldsToolResultAfterChunks() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry()
        try await registry.register(makeEchoTool())

        // Chunks that, when accumulated, contain a tool_call block.
        let chunks: [String] = [
            "I'll help with that.\n\n",
            "<tool_call>\n",
            "name: echo\n",
            "message: streaming hello\n",
            "</tool_call>",
        ]
        let provider = ChunkedStreamProvider(chunks: chunks)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        let stream = await runtime.runStreaming(task: "Echo via stream")

        var received: [String] = []
        for try await chunk in stream {
            received.append(chunk)
        }

        // First N chunks should be the LLM output.
        XCTAssertEqual(received.count, chunks.count + 1,
                       "Should have LLM chunks plus one tool-result chunk")
        for (i, expectedChunk) in chunks.enumerated() {
            XCTAssertEqual(received[i], expectedChunk,
                           "Chunk \(i) should match the provider chunk")
        }
        // Last chunk is the tool result.
        XCTAssertTrue(received.last?.contains("[Tool echo result]") ?? false,
                      "Last chunk should be the tool result")
        XCTAssertTrue(received.last?.contains("streaming hello") ?? false,
                      "Tool result should contain the echoed message")
    }

    func testRunStreamingWithMultipleToolCallsYieldsAllToolResults() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry()
        try await registry.register(makeEchoTool())

        let chunks: [String] = [
            "Let me echo twice.\n\n",
            "<tool_call>\nname: echo\nmessage: first\n</tool_call>\n\n",
            "<tool_call>\nname: echo\nmessage: second\n</tool_call>",
        ]
        let provider = ChunkedStreamProvider(chunks: chunks)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        let stream = await runtime.runStreaming(task: "Echo twice via stream")

        var received: [String] = []
        for try await chunk in stream {
            received.append(chunk)
        }

        // LLM chunks + two tool results.
        XCTAssertEqual(received.count, chunks.count + 2,
                       "Should have LLM chunks plus two tool-result chunks")

        // First N chunks should be the LLM output unchanged.
        for (i, expectedChunk) in chunks.enumerated() {
            XCTAssertEqual(received[i], expectedChunk,
                           "LLM chunk \(i) should match the provider chunk")
        }

        // Last two chunks should be tool results.
        let toolResults = received.suffix(2)
        let resultsJoined = toolResults.joined()
        XCTAssertTrue(resultsJoined.contains("first"),
                      "Tool results should contain first echo")
        XCTAssertTrue(resultsJoined.contains("second"),
                      "Tool results should contain second echo")
        XCTAssertTrue(resultsJoined.contains("[Tool echo result]"),
                      "Tool results should be marked with [Tool echo result]")
    }

    func testRunStreamingToolNotFoundThrowsError() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry() // empty — no tools registered

        let chunks: [String] = [
            "Calling a missing tool.\n",
            "<tool_call>\nname: ghost\nparam: val\n</tool_call>",
        ]
        let provider = ChunkedStreamProvider(chunks: chunks)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        let stream = await runtime.runStreaming(task: "Use missing tool via stream")

        do {
            for try await _ in stream { }
            XCTFail("Expected toolNotFound error to be thrown from stream")
        } catch let error as AgentRuntimeError {
            switch error {
            case .toolNotFound(let name):
                XCTAssertEqual(name, "ghost")
            case .toolExecutionFailed:
                XCTFail("Expected toolNotFound, got toolExecutionFailed")
            }
        }
    }

    func testRunStreamingToolExecutionFailedThrowsError() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry()

        let failingTool = TypedTool<EmptyParams, EmptyResult>(
            name: "flaky",
            description: "Always throws an error.",
            parameterSchema: [],
            handler: { _ in
                throw NSError(domain: "ToolFlake", code: 99, userInfo: [NSLocalizedDescriptionKey: "stream flake"])
            }
        )
        try await registry.register(failingTool)

        let chunks: [String] = [
            "Triggering flaky.\n",
            "<tool_call>\nname: flaky\n</tool_call>",
        ]
        let provider = ChunkedStreamProvider(chunks: chunks)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        let stream = await runtime.runStreaming(task: "Trigger flaky via stream")

        do {
            for try await _ in stream { }
            XCTFail("Expected toolExecutionFailed error to be thrown from stream")
        } catch let error as AgentRuntimeError {
            switch error {
            case .toolExecutionFailed(let name, let underlying):
                XCTAssertEqual(name, "flaky")
                let nsError = underlying as NSError
                XCTAssertEqual(nsError.domain, "ToolFlake")
                XCTAssertEqual(nsError.code, 99)
            case .toolNotFound:
                XCTFail("Expected toolExecutionFailed, got toolNotFound")
            }
        }
    }

    func testRunStreamingWithoutToolCallYieldsOnlyChunks() async throws {
        let agent = makeTestAgent()
        let registry = ToolRegistry()
        try await registry.register(makeEchoTool())

        let chunks: [String] = [
            "Just a ",
            "plain response ",
            "with no tool calls.",
        ]
        let provider = ChunkedStreamProvider(chunks: chunks)

        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        let stream = await runtime.runStreaming(task: "Say hello")

        var received: [String] = []
        for try await chunk in stream {
            received.append(chunk)
        }

        XCTAssertEqual(received, chunks,
                       "When no tool calls exist, chunks should match provider exactly")
        XCTAssertEqual(received.joined(), "Just a plain response with no tool calls.")
    }
}
