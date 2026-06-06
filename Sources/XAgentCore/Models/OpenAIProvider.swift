import Foundation

// MARK: - OpenAI-compatible LLM provider

/// Errors thrown by ``OpenAIProvider``.
public enum OpenAIProviderError: Error, Sendable {
    /// The environment variable named by `apiKeyEnv` is not set or is empty.
    case missingAPIKey(String)
    /// The base URL is invalid.
    case invalidBaseURL(String)
    /// A non-200 HTTP status was returned.
    case httpError(Int, String)
    /// The response body could not be decoded.
    case decodingError(String)
    /// The API returned an error payload.
    case apiError(String)
}

/// An ``LLMProvider`` that talks to any OpenAI-compatible chat completions
/// endpoint over HTTP.
///
/// Configure with a `baseURL`, the name of an environment variable that
/// holds the API key, and an optional default model name.
///
/// ```swift
/// let provider = OpenAIProvider(
///     baseURL: "https://api.openai.com/v1",
///     apiKeyEnv: "OPENAI_API_KEY",
///     defaultModel: "gpt-4.1-mini"
/// )
/// ```
public struct OpenAIProvider: LLMProvider {
    /// The base URL for the API (e.g. `https://api.openai.com/v1`).
    /// Must not end with a trailing slash.
    public let baseURL: String

    /// Name of the environment variable that contains the API key.
    public let apiKeyEnv: String

    /// Model name sent in every request.
    public let defaultModel: String

    /// The `URLSession` used for all requests.
    private let session: URLSession

    // MARK: - Initializers

    /// Creates a new OpenAI-compatible provider.
    ///
    /// - Parameters:
    ///   - baseURL: Base URL for the API. Must not end with `/`.
    ///   - apiKeyEnv: Environment variable name holding the API key.
    ///   - defaultModel: Model identifier sent in requests.
    ///   - session: URLSession to use. Defaults to `.shared`.
    public init(
        baseURL: String,
        apiKeyEnv: String,
        defaultModel: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKeyEnv = apiKeyEnv
        self.defaultModel = defaultModel
        self.session = session
    }

    // MARK: - LLMProvider conformance

    public func complete(prompt: String) async throws -> String {
        let request = try buildRequest(prompt: prompt, stream: false)
        let (data, response) = try await session.data(for: request)

        // Check for an API error payload first — even non-200 responses may
        // carry a structured error that callers want surfaced as `.apiError`.
        if let apiError = try? decodeAPIError(data: data) {
            throw apiError
        }

        try validateHTTP(response: response, data: data)
        return try decodeCompleteResponse(data: data)
    }

    public func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(prompt: prompt, stream: true)
                    let (bytes, response) = try await session.bytes(for: request)
                    try validateHTTP(response: response, data: nil)

                    var byteBuffer = Data()
                    for try await byte in bytes {
                        byteBuffer.append(byte)

                        // Flush whenever we hit a newline.
                        if byte == UInt8(ascii: "\n") {
                            if let line = String(data: byteBuffer, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            {
                                byteBuffer = Data()

                                guard !line.isEmpty else { continue }

                                if line.hasPrefix("data: ") {
                                    let jsonString = String(line.dropFirst(6))
                                    if jsonString == "[DONE]" {
                                        continuation.finish()
                                        return
                                    }
                                    if let chunk = try decodeStreamChunk(jsonString: jsonString) {
                                        continuation.yield(chunk)
                                    }
                                }
                            } else {
                                // Could not decode — reset and keep going.
                                byteBuffer = Data()
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request building

    private func resolveAPIKey() throws -> String {
        guard let key = ProcessInfo.processInfo.environment[apiKeyEnv], !key.isEmpty else {
            throw OpenAIProviderError.missingAPIKey(apiKeyEnv)
        }
        return key
    }

    private func buildRequest(prompt: String, stream: Bool) throws -> URLRequest {
        let apiKey = try resolveAPIKey()

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw OpenAIProviderError.invalidBaseURL(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let body = ChatCompletionRequest(
            model: defaultModel,
            messages: parseMessages(from: prompt),
            stream: stream
        )
        request.httpBody = try JSONEncoder().encode(body)

        return request
    }

    // MARK: - Prompt → messages

    /// Converts the runtime's prompt format into chat messages.
    ///
    /// Expected format:
    /// ```
    /// [System]: <system prompt>
    ///
    /// [User]: <task>
    /// ```
    ///
    /// When the prompt does not follow this convention the entire text is
    /// sent as a single user message.
    private func parseMessages(from prompt: String) -> [ChatMessage] {
        var messages: [ChatMessage] = []

        let scanner = PromptScanner(prompt)
        if let system = scanner.extract(tag: "System") {
            messages.append(ChatMessage(role: "system", content: system))
        }
        if let user = scanner.extract(tag: "User") {
            messages.append(ChatMessage(role: "user", content: user))
        }

        if messages.isEmpty {
            messages.append(ChatMessage(role: "user", content: prompt))
        }

        return messages
    }

    // MARK: - HTTP validation

    private func validateHTTP(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIProviderError.httpError(0, "Not an HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let body: String
            if let data, let text = String(data: data, encoding: .utf8) {
                body = text
            } else {
                body = "(no body)"
            }
            throw OpenAIProviderError.httpError(http.statusCode, body)
        }
    }

    // MARK: - Response decoding

    /// Attempts to decode the response body as an OpenAI error payload.
    /// Returns `nil` when the body does not represent an API error.
    private func decodeAPIError(data: Data) -> OpenAIProviderError? {
        guard let errorResp = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) else {
            return nil
        }
        return .apiError(errorResp.error.message)
    }

    private func decodeCompleteResponse(data: Data) throws -> String {
        let decoder = JSONDecoder()
        let response: ChatCompletionResponse
        do {
            response = try decoder.decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw OpenAIProviderError.decodingError(
                "Failed to decode response: \(error.localizedDescription)"
            )
        }

        guard let choice = response.choices.first else {
            throw OpenAIProviderError.decodingError("No choices in response")
        }

        return choice.message.content
    }

    private func decodeStreamChunk(jsonString: String) throws -> String? {
        guard let data = jsonString.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        let chunk: ChatCompletionChunk
        do {
            chunk = try decoder.decode(ChatCompletionChunk.self, from: data)
        } catch {
            return nil
        }

        return chunk.choices.first?.delta.content
    }
}

// MARK: - Prompt scanner

/// Tiny helper that extracts a tagged section from the runtime prompt format.
private struct PromptScanner {
    private let lines: [String]

    init(_ prompt: String) {
        self.lines = prompt.components(separatedBy: .newlines)
    }

    func extract(tag: String) -> String? {
        var capturing = false
        var content: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[\(tag)]:") {
                capturing = true
                let afterTag = trimmed.dropFirst(tag.count + 4) // "[Tag]: "
                let value = afterTag.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    content.append(value)
                }
                continue
            }

            // Stop capturing when we hit another tag.
            if capturing && trimmed.hasPrefix("[") && trimmed.contains("]:") {
                capturing = false
                continue
            }

            if capturing {
                content.append(line)
            }
        }

        let joined = content
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return joined.isEmpty ? nil : joined
    }
}

// MARK: - OpenAPI request / response types

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
}

private struct ChatCompletionResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

private struct ChatCompletionChunk: Codable {
    struct Choice: Codable {
        struct Delta: Codable {
            let content: String?
        }
        let delta: Delta
    }
    let choices: [Choice]
}

private struct OpenAIErrorResponse: Codable {
    struct ErrorDetail: Codable {
        let message: String
    }
    let error: ErrorDetail
}
