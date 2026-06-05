import XCTest
@testable import XAgentCore

final class LLMProviderTests: XCTestCase {
    func testSyncCompletion() async throws {
        let provider = MockProvider()
        let response = try await provider.complete(prompt: "Hello, world!")
        XCTAssertEqual(response, "Mock response for: Hello, world!")
    }

    func testSyncCompletionDifferentPrompt() async throws {
        let provider = MockProvider()
        let response = try await provider.complete(prompt: "Swift")
        XCTAssertEqual(response, "Mock response for: Swift")
    }

    func testStreaming() async throws {
        let provider = MockProvider()
        let stream = provider.stream(prompt: "world")
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        let expected: [String] = ["Mock ", "streaming ", "response ", "for: ", "world"]
        XCTAssertEqual(chunks, expected)
        XCTAssertEqual(chunks.joined(), "Mock streaming response for: world")
    }

    func testStreamingEmptyPrompt() async throws {
        let provider = MockProvider()
        let stream = provider.stream(prompt: "")
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        let expected: [String] = ["Mock ", "streaming ", "response ", "for: ", ""]
        XCTAssertEqual(chunks, expected)
        XCTAssertEqual(chunks.joined(), "Mock streaming response for: ")
    }
}
