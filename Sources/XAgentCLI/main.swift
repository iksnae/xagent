import Foundation
import XAgentCore

// MARK: - Smoke-test CLI for xagent M1

// MARK: Tool parameter & result types

struct EchoParams: ToolParameters {
    let message: String
}

struct EchoResult: ToolResult {
    let echoed: String
}

struct DateParams: ToolParameters {}

struct DateResult: ToolResult {
    let date: String
}

@main
struct XAgentCLI {
    static func main() async throws {
        // 1. Create the LLM provider (mock for now).
        let provider = MockProvider()

        // 2. Build a tool registry with demo tools: echo and date.
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
                DateResult(date: Date().ISO8601Format())
            }
        )

        try await toolRegistry.register(echoTool)
        try await toolRegistry.register(dateTool)

        // 3. Create a simple agent.
        let agent = DefaultAgent(
            identifier: "smoke-test-agent",
            systemPrompt: "You are a helpful assistant. When the user asks for the date, use the date tool. When they ask you to echo something, use the echo tool."
        )

        // 4. Wire up the runtime.
        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: toolRegistry,
            provider: provider
        )

        // 5. Run with a sample task and print the result.
        let task = "Say hello and tell me the date"
        let result = try await runtime.run(task: task)
        print(result)
    }
}
