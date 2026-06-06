import Foundation

/// A minimal HTTP client for the xagentd daemon API.
///
/// Supports two operations:
/// - `submit(task:)` — POST /runs (fire-and-forget, returns the result).
/// - `stream(task:)` — GET /runs/stream/events?task=...  (SSE stream).
public struct APIClient: Sendable {
    /// The base URL of the daemon, e.g. `http://localhost:8080`.
    public let baseURL: URL

    /// The URLSession used for requests.  Ephemeral to avoid caching.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    // MARK: - Initialization

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    // MARK: - Public API

    /// Submits a task to the daemon and returns the full response text.
    ///
    /// - Parameter task: The natural-language task to execute.
    /// - Returns: The agent's response.
    /// - Throws: `APIClientError` for HTTP-level or unexpected payload errors.
    public func submit(task: String) async throws -> String {
        let url = baseURL.appendingPathComponent("runs")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["task": task]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIClientError.httpError(statusCode: httpResponse.statusCode, body: message)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
            let result = json["result"]
        else {
            throw APIClientError.unexpectedPayload(String(data: data, encoding: .utf8) ?? "")
        }

        return result
    }

    /// Opens an SSE stream for a task and yields each event as it arrives.
    ///
    /// The stream ends when the server sends `[DONE]` or the connection closes.
    ///
    /// - Parameter task: The natural-language task to execute.
    /// - Returns: An `AsyncThrowingStream` that yields SSE data payloads.
    public func stream(task: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var components = URLComponents(
                        url: baseURL.appendingPathComponent("runs/stream/events"),
                        resolvingAgainstBaseURL: false
                    )!
                    components.queryItems = [
                        URLQueryItem(name: "task", value: task)
                    ]

                    let request = URLRequest(url: components.url!)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode)
                    else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw APIClientError.httpError(
                            statusCode: statusCode,
                            body: "SSE connection failed"
                        )
                    }

                    // Parse SSE: each event is one or more `data:` lines
                    // followed by a blank line.
                    var currentDataLines: [String] = []
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let payload = String(line.dropFirst(6))
                            if payload == "[DONE]" {
                                break
                            }
                            currentDataLines.append(payload)
                        } else if line.isEmpty {
                            // End of event — yield accumulated data.
                            if !currentDataLines.isEmpty {
                                let eventData = currentDataLines.joined(separator: "\n")
                                continuation.yield(eventData)
                                currentDataLines = []
                            }
                        }
                        // Ignore other SSE fields (event:, id:, etc.).
                    }

                    // Yield any remaining data (should not happen with DONE,
                    // but handle gracefully).
                    if !currentDataLines.isEmpty {
                        let eventData = currentDataLines.joined(separator: "\n")
                        continuation.yield(eventData)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Errors

public enum APIClientError: Error, Sendable {
    /// The response could not be cast to HTTPURLResponse.
    case invalidResponse
    /// The server returned a non-2xx status code.
    case httpError(statusCode: Int, body: String)
    /// The response body could not be parsed as the expected JSON structure.
    case unexpectedPayload(String)
}
