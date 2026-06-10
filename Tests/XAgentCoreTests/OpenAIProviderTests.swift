import XCTest
@testable import XAgentCore

// MARK: - URLProtocol mock for OpenAI provider tests

/// A test URLProtocol that returns preconfigured responses keyed by URL path.
/// Wire into a URLSession via `URLSessionConfiguration.protocolClasses`.
private final class MockOpenAIURLProtocol: URLProtocol, @unchecked Sendable {
    static nonisolated(unsafe) var responseMap: [String: (Int, Data)] = [:]
    static nonisolated(unsafe) var lastRequest: URLRequest?

    /// Captured at init time so we preserve `httpBody` before URLProtocol strips it.
    private let capturedRequest: URLRequest

    override init(request: URLRequest, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        self.capturedRequest = request
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // Reconstruct the body: URLSession may move httpBody → httpBodyStream.
        var requestToSave = capturedRequest
        if requestToSave.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bodyData = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bodyData.append(buffer, count: count)
            }
            requestToSave.httpBody = bodyData
        }
        Self.lastRequest = requestToSave

        guard let url = capturedRequest.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let key = url.lastPathComponent
        if let (statusCode, body) = Self.responseMap[key] {
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
        } else {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: "1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
        }

        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - OpenAIProvider tests

final class OpenAIProviderTests: XCTestCase {

    // MARK: - Setup & teardown

    override func setUp() {
        super.setUp()
        MockOpenAIURLProtocol.responseMap = [:]
        MockOpenAIURLProtocol.lastRequest = nil
        setenv("TEST_OPENAI_KEY", "test-api-key-value", 1)
    }

    override func tearDown() {
        unsetenv("TEST_OPENAI_KEY")
        MockOpenAIURLProtocol.responseMap = [:]
        MockOpenAIURLProtocol.lastRequest = nil
        super.tearDown()
    }

    /// Creates a provider whose URLSession uses the mock protocol.
    private func makeProvider(
        baseURL: String = "https://api.openai.com/v1",
        apiKeyEnv: String = "TEST_OPENAI_KEY",
        defaultModel: String = "gpt-4.1-mini"
    ) -> OpenAIProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockOpenAIURLProtocol.self]
        let session = URLSession(configuration: config)
        return OpenAIProvider(
            baseURL: baseURL,
            apiKeyEnv: apiKeyEnv,
            defaultModel: defaultModel,
            session: session
        )
    }

    // MARK: - Initialization

    func testInitTrimsTrailingSlashFromBaseURL() {
        let provider = OpenAIProvider(
            baseURL: "https://api.openai.com/v1/",
            apiKeyEnv: "KEY",
            defaultModel: "m"
        )
        XCTAssertEqual(provider.baseURL, "https://api.openai.com/v1")
    }

    func testInitPreservesBaseURLWithoutSlash() {
        let provider = OpenAIProvider(
            baseURL: "https://api.openai.com/v1",
            apiKeyEnv: "KEY",
            defaultModel: "m"
        )
        XCTAssertEqual(provider.baseURL, "https://api.openai.com/v1")
    }

    // MARK: - Missing API key

    func testCompleteThrowsWhenAPIKeyMissing() async {
        let provider = makeProvider(apiKeyEnv: "NONEXISTENT_KEY_XYZ")
        do {
            _ = try await provider.complete(prompt: "Hello")
            XCTFail("Expected missingAPIKey error")
        } catch let error as OpenAIProviderError {
            if case .missingAPIKey(let env) = error {
                XCTAssertEqual(env, "NONEXISTENT_KEY_XYZ")
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamThrowsWhenAPIKeyMissing() async {
        let provider = makeProvider(apiKeyEnv: "NONEXISTENT_KEY_XYZ")
        let stream = provider.stream(prompt: "Hello")
        do {
            for try await _ in stream { }
            XCTFail("Expected missingAPIKey error")
        } catch let error as OpenAIProviderError {
            if case .missingAPIKey(let env) = error {
                XCTAssertEqual(env, "NONEXISTENT_KEY_XYZ")
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Complete (non-streaming)

    func testCompleteReturnsContentForValidResponse() async throws {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            200,
            Data("""
            {
                "choices": [
                    {
                        "message": {
                            "content": "Hello from OpenAI!"
                        }
                    }
                ]
            }
            """.utf8)
        )

        let provider = makeProvider()
        let result = try await provider.complete(prompt: "Hi")
        XCTAssertEqual(result, "Hello from OpenAI!")
    }

    func testCompleteSendsCorrectJSONBody() async throws {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            200,
            Data("""
            {"choices":[{"message":{"content":"ok"}}]}
            """.utf8)
        )

        let provider = makeProvider(defaultModel: "gpt-4")
        _ = try await provider.complete(prompt: "[System]: sys\n\n[User]: usr")

        guard let request = MockOpenAIURLProtocol.lastRequest else {
            XCTFail("No request captured")
            return
        }

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key-value")

        // Decode the body and verify structure.
        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "gpt-4")
        XCTAssertEqual(json?["stream"] as? Bool, false)

        let messages = try XCTUnwrap(json?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "sys")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "usr")
    }

    func testCompleteSendsPlainPromptAsSingleUserMessage() async throws {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            200,
            Data("""
            {"choices":[{"message":{"content":"ok"}}]}
            """.utf8)
        )

        let provider = makeProvider()
        _ = try await provider.complete(prompt: "Just a plain prompt")

        guard let request = MockOpenAIURLProtocol.lastRequest else {
            XCTFail("No request captured")
            return
        }

        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try XCTUnwrap(json?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "Just a plain prompt")
    }

    // MARK: - HTTP error

    func testCompleteThrowsOnHTTPError() async {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            500,
            Data("Internal Server Error".utf8)
        )

        let provider = makeProvider()
        do {
            _ = try await provider.complete(prompt: "Hi")
            XCTFail("Expected httpError")
        } catch let error as OpenAIProviderError {
            if case .httpError(let code, let body) = error {
                XCTAssertEqual(code, 500)
                XCTAssertTrue(body.contains("Internal Server Error"))
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCompleteThrowsOnAPIErrorPayload() async {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            400,
            Data("""
            {
                "error": {
                    "message": "Invalid model name"
                }
            }
            """.utf8)
        )

        let provider = makeProvider()
        do {
            _ = try await provider.complete(prompt: "Hi")
            XCTFail("Expected apiError")
        } catch let error as OpenAIProviderError {
            if case .apiError(let msg) = error {
                XCTAssertEqual(msg, "Invalid model name")
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Streaming

    func testStreamYieldsContentChunks() async throws {
        let sseBody = """
            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[{"delta":{"content":" world"}}]}

            data: {"choices":[{"delta":{"content":"!"}}]}

            data: [DONE]

            """.data(using: .utf8)!

        MockOpenAIURLProtocol.responseMap["completions"] = (200, sseBody)

        let provider = makeProvider()
        let stream = provider.stream(prompt: "Hi")

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks, ["Hello", " world", "!"])
    }

    func testStreamSendsStreamTrueInBody() async throws {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            200,
            Data("data: [DONE]\n".utf8)
        )

        let provider = makeProvider()
        let stream = provider.stream(prompt: "Hi")
        // Drain the stream.
        for try await _ in stream { }

        guard let request = MockOpenAIURLProtocol.lastRequest else {
            XCTFail("No request captured")
            return
        }

        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["stream"] as? Bool, true)
    }

    func testStreamSkipsNonDataLines() async throws {
        let sseBody = """
            : comment line

            data: {"choices":[{"delta":{"content":"only"}}]}

            data: [DONE]

            """.data(using: .utf8)!

        MockOpenAIURLProtocol.responseMap["completions"] = (200, sseBody)

        let provider = makeProvider()
        let stream = provider.stream(prompt: "Hi")

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks, ["only"])
    }

    func testStreamSkipsChunksWithNoContent() async throws {
        // A chunk with only a role delta (no content).
        let sseBody = """
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: {"choices":[{"delta":{"content":"text"}}]}

            data: [DONE]

            """.data(using: .utf8)!

        MockOpenAIURLProtocol.responseMap["completions"] = (200, sseBody)

        let provider = makeProvider()
        let stream = provider.stream(prompt: "Hi")

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks, ["text"], "Should skip chunks without content delta")
    }

    // MARK: - Prompt parsing (via request body inspection)

    func testPromptParsingExtractsSystemAndUser() async throws {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            200,
            Data("""
            {"choices":[{"message":{"content":"ok"}}]}
            """.utf8)
        )

        let prompt = """
            [System]: You are a helpful assistant.

            [User]: What is the weather?
            """

        let provider = makeProvider()
        _ = try await provider.complete(prompt: prompt)

        guard let request = MockOpenAIURLProtocol.lastRequest else {
            XCTFail("No request captured")
            return
        }

        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try XCTUnwrap(json?["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "You are a helpful assistant.")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "What is the weather?")
    }

    func testPromptParsingSystemOnly() async throws {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            200,
            Data("""
            {"choices":[{"message":{"content":"ok"}}]}
            """.utf8)
        )

        let prompt = "[System]: You are a bot."

        let provider = makeProvider()
        _ = try await provider.complete(prompt: prompt)

        guard let request = MockOpenAIURLProtocol.lastRequest else {
            XCTFail("No request captured")
            return
        }

        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try XCTUnwrap(json?["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "You are a bot.")
    }

    func testPromptParsingUserOnly() async throws {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            200,
            Data("""
            {"choices":[{"message":{"content":"ok"}}]}
            """.utf8)
        )

        let prompt = "[User]: Do something."

        let provider = makeProvider()
        _ = try await provider.complete(prompt: prompt)

        guard let request = MockOpenAIURLProtocol.lastRequest else {
            XCTFail("No request captured")
            return
        }

        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try XCTUnwrap(json?["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "Do something.")
    }

    // MARK: - base URL construction

    func testUsesConfiguredBaseURL() async throws {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            200,
            Data("""
            {"choices":[{"message":{"content":"ok"}}]}
            """.utf8)
        )

        let provider = makeProvider(baseURL: "http://localhost:1234/v1")
        _ = try await provider.complete(prompt: "Hi")

        guard let request = MockOpenAIURLProtocol.lastRequest else {
            XCTFail("No request captured")
            return
        }

        XCTAssertEqual(request.url?.absoluteString, "http://localhost:1234/v1/chat/completions")
    }

    // MARK: - Model parameter

    func testSendsConfiguredModel() async throws {
        MockOpenAIURLProtocol.responseMap["completions"] = (
            200,
            Data("""
            {"choices":[{"message":{"content":"ok"}}]}
            """.utf8)
        )

        let provider = makeProvider(defaultModel: "custom-model-v2")
        _ = try await provider.complete(prompt: "Hi")

        guard let request = MockOpenAIURLProtocol.lastRequest else {
            XCTFail("No request captured")
            return
        }

        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "custom-model-v2")
    }
}
