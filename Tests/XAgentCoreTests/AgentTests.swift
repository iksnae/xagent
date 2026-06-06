import XCTest
@testable import XAgentCore

final class AgentTests: XCTestCase {

    // MARK: - Construction

    func testDefaultAgentConstruction() {
        let agent = DefaultAgent(
            identifier: "test-bot",
            systemPrompt: "You are a helpful testing bot."
        )

        XCTAssertEqual(agent.identifier, "test-bot")
        XCTAssertEqual(agent.systemPrompt, "You are a helpful testing bot.")
    }

    func testDefaultAgentDefaultMetadataIsEmpty() {
        let agent = DefaultAgent(
            identifier: "minimal",
            systemPrompt: "Minimal prompt."
        )

        XCTAssertEqual(agent.metadata.count, 0)
        XCTAssertTrue(agent.metadata.isEmpty)
    }

    func testDefaultAgentExplicitMetadata() {
        let agent = DefaultAgent(
            identifier: "configured",
            systemPrompt: "Configured agent.",
            metadata: [
                "model": "gpt-4",
                "temperature": "0.7",
                "tags": "utility,test",
            ]
        )

        XCTAssertEqual(agent.metadata.count, 3)
        XCTAssertEqual(agent.metadata["model"], "gpt-4")
        XCTAssertEqual(agent.metadata["temperature"], "0.7")
        XCTAssertEqual(agent.metadata["tags"], "utility,test")
    }

    func testDefaultAgentEmptyMetadataLiteral() {
        let agent = DefaultAgent(
            identifier: "empty-meta",
            systemPrompt: "Prompt.",
            metadata: [:]
        )

        XCTAssertEqual(agent.metadata.count, 0)
    }

    // MARK: - Agent protocol conformance

    func testDefaultAgentConformsToAgentProtocol() {
        // Compile-time: DefaultAgent can be assigned to a variable of type any Agent.
        let agent: any Agent = DefaultAgent(
            identifier: "proto-check",
            systemPrompt: "Protocol conformance test."
        )

        XCTAssertEqual(agent.identifier, "proto-check")
        XCTAssertEqual(agent.systemPrompt, "Protocol conformance test.")
        XCTAssertTrue(agent.metadata.isEmpty)
    }

    // MARK: - Edge cases

    func testDefaultAgentEmptyIdentifier() {
        let agent = DefaultAgent(
            identifier: "",
            systemPrompt: "Empty ID agent."
        )

        XCTAssertEqual(agent.identifier, "")
        XCTAssertEqual(agent.systemPrompt, "Empty ID agent.")
    }

    func testDefaultAgentEmptySystemPrompt() {
        let agent = DefaultAgent(
            identifier: "no-prompt",
            systemPrompt: ""
        )

        XCTAssertEqual(agent.systemPrompt, "")
        XCTAssertEqual(agent.identifier, "no-prompt")
    }

    func testMultipleDefaultAgentsAreIndependent() {
        let agentA = DefaultAgent(
            identifier: "a",
            systemPrompt: "Prompt A",
            metadata: ["role": "first"]
        )
        let agentB = DefaultAgent(
            identifier: "b",
            systemPrompt: "Prompt B",
            metadata: ["role": "second"]
        )

        XCTAssertEqual(agentA.identifier, "a")
        XCTAssertEqual(agentB.identifier, "b")
        XCTAssertEqual(agentA.systemPrompt, "Prompt A")
        XCTAssertEqual(agentB.systemPrompt, "Prompt B")
        XCTAssertEqual(agentA.metadata["role"], "first")
        XCTAssertEqual(agentB.metadata["role"], "second")
    }
}
