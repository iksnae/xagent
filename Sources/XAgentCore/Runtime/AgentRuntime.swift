import Foundation

/// Errors thrown by AgentRuntime.
public enum AgentRuntimeError: Error, Sendable {
    /// No tool with the requested name is registered in the ToolRegistry.
    case toolNotFound(String)
    /// A tool's handler threw an error during execution.
    case toolExecutionFailed(String, Error)
}

/// The core agent runtime orchestrator.
///
/// AgentRuntime accepts an ``Agent``, a ``ToolRegistry``, and an ``LLMProvider``,
/// and implements a `run(task:)` loop that:
/// 1. Builds a prompt from the agent's system prompt and the user task.
/// 2. Sends that prompt to the LLM provider.
/// 3. Inspects the response for `<tool_call>...</tool_call>` blocks.
/// 4. Executes matching tools from the registry.
/// 5. Appends tool results to the response and returns it.
public actor AgentRuntime {
    private let agent: any Agent
    private let toolRegistry: ToolRegistry
    private let provider: any LLMProvider

    public init(
        agent: any Agent,
        toolRegistry: ToolRegistry,
        provider: any LLMProvider
    ) {
        self.agent = agent
        self.toolRegistry = toolRegistry
        self.provider = provider
    }

    /// Runs the agent for a given user task.
    /// - Parameter task: The user's natural-language task description.
    /// - Returns: The final response text after any tool calls have been resolved.
    public func run(task: String) async throws -> String {
        let prompt = buildPrompt(task: task)
        let response = try await provider.complete(prompt: prompt)

        let calls = parseToolCalls(from: response)
        if calls.isEmpty {
            return response
        }

        var finalResponse = response
        for call in calls {
            let result = try await executeToolCall(call)
            finalResponse += "\n\n[Tool \(call.name) result]: \(result)"
        }

        return finalResponse
    }

    /// Runs the agent for a given user task in streaming mode.
    ///
    /// Each chunk from the LLM provider is yielded to the consumer as it arrives.
    /// After the LLM stream finishes, the accumulated response is scanned for
    /// `<tool_call>…</tool_call>` blocks, each tool is executed, and the tool
    /// results are yielded as additional stream elements before the stream finishes.
    ///
    /// - Parameter task: The user's natural-language task description.
    /// - Returns: An `AsyncThrowingStream` that yields LLM response chunks in order,
    ///   followed by any tool execution results.
    public func runStreaming(task: String) -> AsyncThrowingStream<String, Error> {
        let prompt = buildPrompt(task: task)
        let providerStream = provider.stream(prompt: prompt)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var buffer = ""
                    for try await chunk in providerStream {
                        buffer += chunk
                        continuation.yield(chunk)
                    }

                    // After the LLM stream finishes, resolve any tool calls.
                    let calls = parseToolCalls(from: buffer)
                    for call in calls {
                        let result = try await executeToolCall(call)
                        continuation.yield("\n\n[Tool \(call.name) result]: \(result)")
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private helpers

    private func buildPrompt(task: String) -> String {
        """
        [System]: \(agent.systemPrompt)

        [User]: \(task)
        """
    }

    /// A parsed tool-call descriptor extracted from the LLM response.
    private struct ToolCall {
        let name: String
        let parameters: [String: String]
    }

    /// Scans the response text for `<tool_call>...</tool_call>` blocks.
    ///
    /// Expected format:
    /// ```
    /// <tool_call>
    /// name: tool_name
    /// key1: value1
    /// key2: value2
    /// </tool_call>
    /// ```
    private func parseToolCalls(from response: String) -> [ToolCall] {
        var calls: [ToolCall] = []

        let lines = response.components(separatedBy: .newlines)
        var inBlock = false
        var currentName: String?
        var currentParams: [String: String] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "<tool_call>" {
                inBlock = true
                currentName = nil
                currentParams = [:]
            } else if trimmed == "</tool_call>" {
                if inBlock, let name = currentName {
                    calls.append(ToolCall(name: name, parameters: currentParams))
                }
                inBlock = false
                currentName = nil
                currentParams = [:]
            } else if inBlock {
                let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    if key.lowercased() == "name" {
                        currentName = value
                    } else {
                        currentParams[key] = value
                    }
                }
            }
        }

        return calls
    }

    private func executeToolCall(_ call: ToolCall) async throws -> String {
        guard let tool = await toolRegistry.lookup(by: call.name) else {
            throw AgentRuntimeError.toolNotFound(call.name)
        }
        do {
            let inputData = try JSONEncoder().encode(call.parameters)
            let outputData = try await tool.handle(inputData)
            return String(data: outputData, encoding: .utf8) ?? String(describing: outputData)
        } catch {
            throw AgentRuntimeError.toolExecutionFailed(call.name, error)
        }
    }
}
