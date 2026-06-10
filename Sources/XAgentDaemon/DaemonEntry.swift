import Foundation
import Dispatch
import XAgentCore
import XAgentHTTP

// MARK: - Entry Point

/// The daemon's `@main` entry point.  Starts an `XAgentDaemon` wired to
/// an HTTP + SSE server on `localhost:8080`.
@main
struct DaemonEntry {
    static func main() {
        Task {
            await startDaemon()
        }
        dispatchMain()
    }

    /// Configures the agent runtime, creates the daemon, builds the HTTP
    /// route table, and starts the HTTP server.
    private static func startDaemon() async {
        // 1. Build the agent runtime with a default agent and mock provider.
        let agent = DefaultAgent(
            identifier: "xagentd-default",
            systemPrompt: "You are a helpful AI assistant."
        )
        let registry = ToolRegistry()
        let provider = MockProvider()
        let runtime = AgentRuntime(
            agent: agent,
            toolRegistry: registry,
            provider: provider
        )

        // 2. Create the daemon.
        let daemon = XAgentDaemon(runtime: runtime)
        await daemon.start()

        // 3. Build HTTP route table.
        let handler: HTTPHandler = { request in
            await route(request, daemon: daemon)
        }

        let server = HTTPServer(port: 8080, handler: handler)

        do {
            try server.start()
            print("xagentd listening on http://localhost:8080")
        } catch {
            print("xagentd failed to start HTTP server: \(error)")
        }
    }

    /// Routes an incoming HTTP request to the appropriate handler.
    private static func route(
        _ request: HTTPRequest,
        daemon: XAgentDaemon
    ) async -> HTTPResponse {
        switch (request.method, request.path) {
        // --- Health ---
        case ("GET", "/health"):
            return .ok(text: "OK")

        // --- Submit a task (JSON in, JSON out) ---
        case ("POST", "/runs"):
            return await handleSubmitRun(request, daemon: daemon)

        // --- SSE event stream for a run ---
        case ("GET", let path) where path.hasPrefix("/runs/") && path.hasSuffix("/events"):
            return await handleSSEStream(request, daemon: daemon)

        // --- Catch-all ---
        default:
            return .notFound()
        }
    }

    // MARK: - POST /runs

    /// Parses `{"task": "..."}` from the request body, executes it via the
    /// daemon's `run(task:)`, and returns `{"result": "..."}` as JSON.
    private static func handleSubmitRun(
        _ request: HTTPRequest,
        daemon: XAgentDaemon
    ) async -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(
            with: request.body
        ) as? [String: String],
              let task = body["task"],
              !task.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return .badRequest(
                "Expected JSON body with non-empty \"task\" field"
            )
        }

        do {
            let result = try await daemon.run(task: task)
            let responseJSON = try JSONSerialization.data(
                withJSONObject: ["result": result]
            )
            return .ok(json: responseJSON)
        } catch {
            return .internalServerError("\(error)")
        }
    }

    // MARK: - GET /runs/:id/events

    /// Opens an SSE stream that yields chunks from the daemon's
    /// `runStreaming(task:)`.  The task is submitted via query parameter
    /// `?task=...`.
    private static func handleSSEStream(
        _ request: HTTPRequest,
        daemon: XAgentDaemon
    ) async -> HTTPResponse {
        // Extract the task from the query string.
        guard let queryStart = request.path.firstIndex(of: "?"),
              let task = parseQueryParam(
                String(request.path[request.path.index(after: queryStart)...]),
                name: "task"
              ),
              !task.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return .badRequest(
                "Expected ?task=... query parameter for SSE stream"
            )
        }

        // Build an SSE stream by wrapping the daemon's runStreaming.
        // The handler yields fully-formatted SSE frames (including [DONE]);
        // the server writes them verbatim without additional wrapping.
        let (sseStream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        Task {
            do {
                let runtimeStream = await daemon.runStreaming(task: task)
                for try await chunk in runtimeStream {
                    continuation.yield(
                        SSEStream.event(data: chunk)
                    )
                }
                continuation.yield(SSEStream.done())
                continuation.finish()
            } catch {
                continuation.yield(
                    SSEStream.event(
                        data: "[ERROR] \(error)",
                        event: "error"
                    )
                )
                continuation.finish()
            }
        }

        return .sse(stream: sseStream)
    }

    /// Parses a simple `key=value` pair from a query string.
    private static func parseQueryParam(
        _ query: String,
        name: String
    ) -> String? {
        let pairs = query.components(separatedBy: "&")
        for pair in pairs {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2,
               kv[0].removingPercentEncoding == name {
                return kv[1].removingPercentEncoding
            }
        }
        return nil
    }
}
