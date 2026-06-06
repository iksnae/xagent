import XCTest
@testable import XAgentDaemon
import XAgentCore

// MARK: - Helpers for daemon tests

/// A spy event store that captures events for assertion.
final class SpyEventStore: EventStore, @unchecked Sendable {
    private(set) var events: [RunEvent] = []
    private let queue = DispatchQueue(label: "spy-event-store")

    func record(_ event: RunEvent) async {
        queue.sync {
            events.append(event)
        }
    }

    var eventCount: Int {
        queue.sync { events.count }
    }

    var latestEvent: RunEvent? {
        queue.sync { events.last }
    }
}

/// An LLM provider that throws a canned error, used to test failure paths.
struct ThrowingProvider: LLMProvider, @unchecked Sendable {
    let errorMessage: String

    func complete(prompt: String) async throws -> String {
        throw NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: errorMessage])
    }

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
        }
    }
}

/// Helper to build a configured daemon for tests.
func makeTestDaemon(
    agent: DefaultAgent? = nil,
    eventStore: (any EventStore)? = nil,
    provider: (any LLMProvider)? = nil
) async -> XAgentDaemon {
    let resolvedAgent = agent ?? DefaultAgent(
        identifier: "daemon-test-agent",
        systemPrompt: "You are a test assistant."
    )
    let registry = ToolRegistry()
    let resolvedProvider = provider ?? MockProvider()
    let runtime = AgentRuntime(
        agent: resolvedAgent,
        toolRegistry: registry,
        provider: resolvedProvider
    )
    let store = eventStore ?? NoOpEventStore()
    return XAgentDaemon(runtime: runtime, eventStore: store)
}

// MARK: - Daemon lifecycle tests

final class XAgentDaemonLifecycleTests: XCTestCase {

    func testDaemonStartsInIdleState() async {
        let daemon = await makeTestDaemon()
        let state = await daemon.state
        XCTAssertEqual(state, .idle, "Daemon should start in idle state")
    }

    func testStartTransitionsToRunning() async {
        let daemon = await makeTestDaemon()
        await daemon.start()
        let state = await daemon.state
        XCTAssertEqual(state, .running, "Daemon should transition to running after start")
    }

    func testShutdownFromRunningTransitionsToDraining() async {
        let daemon = await makeTestDaemon()
        await daemon.start()
        await daemon.shutdown()
        let state = await daemon.state
        XCTAssertEqual(state, .draining, "Daemon should transition to draining on shutdown")
    }

    func testMarkStoppedTransitionsToStopped() async {
        let daemon = await makeTestDaemon()
        await daemon.start()
        await daemon.shutdown()
        await daemon.markStopped()
        let state = await daemon.state
        XCTAssertEqual(state, .stopped, "Daemon should transition to stopped")
    }

    func testDoubleStartIsNoOp() async {
        let daemon = await makeTestDaemon()
        await daemon.start()
        await daemon.start()
        let state = await daemon.state
        XCTAssertEqual(state, .running, "Double start should be a no-op")
    }

    func testShutdownFromIdleDoesNotChangeState() async {
        let daemon = await makeTestDaemon()
        await daemon.shutdown()
        let state = await daemon.state
        // shutdownRequested is set, but state remains idle because it wasn't running.
        XCTAssertEqual(state, .idle, "Shutdown from idle should keep state idle")
    }
}

// MARK: - Daemon task execution tests

final class XAgentDaemonTaskExecutionTests: XCTestCase {

    func testRunReturnsResponseFromRuntime() async throws {
        let agent = DefaultAgent(
            identifier: "exec-test",
            systemPrompt: "You are a helpful assistant."
        )
        let daemon = await makeTestDaemon(agent: agent)
        await daemon.start()

        let result = try await daemon.run(task: "Hello, world!")

        XCTAssertFalse(result.isEmpty, "Result should not be empty")
        XCTAssertTrue(result.contains("Mock response for:"), "Result should contain mock response prefix")
        XCTAssertTrue(result.contains("You are a helpful assistant"), "Result should contain system prompt")
    }

    func testRunIncrementsRunCount() async throws {
        let daemon = await makeTestDaemon()
        await daemon.start()

        _ = try await daemon.run(task: "First task")
        _ = try await daemon.run(task: "Second task")
        _ = try await daemon.run(task: "Third task")

        let count = await daemon.runCount
        XCTAssertEqual(count, 3, "Run count should equal number of successful runs")
    }

    func testRunThrowsNotRunningWhenIdle() async {
        let daemon = await makeTestDaemon()
        // Daemon is idle — run should throw.

        do {
            _ = try await daemon.run(task: "Should fail")
            XCTFail("Expected notRunning error")
        } catch let error as DaemonError {
            XCTAssertEqual(error, .notRunning, "Should throw notRunning when idle")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunThrowsNotRunningWhenStopped() async {
        let daemon = await makeTestDaemon()
        await daemon.start()
        await daemon.shutdown()
        await daemon.markStopped()

        do {
            _ = try await daemon.run(task: "Should fail")
            XCTFail("Expected notRunning error")
        } catch let error as DaemonError {
            XCTAssertEqual(error, .notRunning, "Should throw notRunning when stopped")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMultipleRunsAreIndependent() async throws {
        let daemon = await makeTestDaemon()
        await daemon.start()

        let result1 = try await daemon.run(task: "Task one")
        let result2 = try await daemon.run(task: "Task two")

        XCTAssertTrue(result1.contains("Task one"), "First result should mention first task")
        XCTAssertTrue(result2.contains("Task two"), "Second result should mention second task")
        XCTAssertNotEqual(result1, result2, "Two different tasks should produce different output")
    }
}

// MARK: - Event store tests

final class XAgentDaemonEventStoreTests: XCTestCase {

    func testSuccessfulRunRecordsEvent() async throws {
        let spy = SpyEventStore()
        let daemon = await makeTestDaemon(eventStore: spy)
        await daemon.start()

        _ = try await daemon.run(task: "Event test")

        XCTAssertEqual(spy.eventCount, 1, "One event should be recorded")
        let event = spy.latestEvent
        XCTAssertEqual(event?.task, "Event test", "Event should contain the task")
        XCTAssertNotNil(event?.result, "Event should have a result on success")
        XCTAssertNil(event?.error, "Event should have no error on success")
        XCTAssertNotNil(event?.startedAt, "Event should have a start time")
        XCTAssertNotNil(event?.finishedAt, "Event should have a finish time")
        XCTAssertLessThanOrEqual(
            event!.startedAt,
            event!.finishedAt,
            "Started at should be <= finished at"
        )
    }

    func testFailedRunRecordsEventWithError() async throws {
        // Use a ThrowingProvider so the runtime throws mid-execution,
        // which the daemon catches and records as a failed event.
        let spy = SpyEventStore()
        let daemon = await makeTestDaemon(
            eventStore: spy,
            provider: ThrowingProvider(errorMessage: "Boom")
        )
        await daemon.start()

        do {
            _ = try await daemon.run(task: "Will fail")
            XCTFail("Expected taskFailed error")
        } catch {
            // Expected — the daemon wraps runtime errors in DaemonError.taskFailed.
        }

        // The event IS recorded even on failure.
        XCTAssertEqual(spy.eventCount, 1, "One event should be recorded even on failure")
        let event = spy.latestEvent
        XCTAssertEqual(event?.task, "Will fail", "Event should contain the task")
        XCTAssertNotNil(event?.error, "Event should have an error on failure")
        XCTAssertNil(event?.result, "Event should have no result on failure")
    }

    func testMultipleRunsRecordMultipleEvents() async throws {
        let spy = SpyEventStore()
        let daemon = await makeTestDaemon(eventStore: spy)
        await daemon.start()

        _ = try await daemon.run(task: "First")
        _ = try await daemon.run(task: "Second")
        _ = try await daemon.run(task: "Third")

        XCTAssertEqual(spy.eventCount, 3, "Three events should be recorded for three runs")
        let tasks = spy.events.map(\.task)
        XCTAssertEqual(tasks, ["First", "Second", "Third"], "Events should be in order")
    }

    func testNoOpEventStoreDoesNotCrash() async throws {
        let daemon = await makeTestDaemon(eventStore: NoOpEventStore())
        await daemon.start()

        // Should complete without error — NoOpEventStore silently discards.
        let result = try await daemon.run(task: "No-op store test")
        XCTAssertFalse(result.isEmpty, "Run should succeed with NoOpEventStore")
    }
}

// MARK: - RunEvent Codable tests

final class RunEventTests: XCTestCase {

    func testRunEventCodingRoundTrip() throws {
        let now = Date()
        let later = now.addingTimeInterval(1.5)

        let event = RunEvent(
            task: "Test task",
            startedAt: now,
            finishedAt: later,
            result: "Success!",
            error: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RunEvent.self, from: data)

        XCTAssertEqual(decoded.task, "Test task")
        XCTAssertEqual(decoded.result, "Success!")
        XCTAssertNil(decoded.error)
        // Date encoding loses sub-second precision in JSON, so compare with tolerance.
        XCTAssertEqual(decoded.startedAt.timeIntervalSinceReferenceDate,
                       now.timeIntervalSinceReferenceDate,
                       accuracy: 1.0)
        XCTAssertEqual(decoded.finishedAt.timeIntervalSinceReferenceDate,
                       later.timeIntervalSinceReferenceDate,
                       accuracy: 1.0)
    }

    func testRunEventWithErrorCodingRoundTrip() throws {
        let event = RunEvent(
            task: "Failing task",
            startedAt: Date(),
            finishedAt: Date(),
            result: nil,
            error: "Something went wrong"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RunEvent.self, from: data)

        XCTAssertNil(decoded.result)
        XCTAssertEqual(decoded.error, "Something went wrong")
    }
}

// MARK: - DaemonError tests

final class DaemonErrorTests: XCTestCase {

    func testNotRunningErrorEquatable() {
        XCTAssertEqual(DaemonError.notRunning, DaemonError.notRunning)
    }

    func testTaskFailedErrorEquatable() {
        let e1 = DaemonError.taskFailed("error A")
        let e2 = DaemonError.taskFailed("error A")
        let e3 = DaemonError.taskFailed("error B")
        XCTAssertEqual(e1, e2)
        XCTAssertNotEqual(e1, e3)
    }

    func testNotRunningErrorDescription() {
        let desc = String(describing: DaemonError.notRunning)
        XCTAssertTrue(desc.contains("notRunning") || desc.contains("NotRunning"))
    }

    func testTaskFailedErrorDescription() {
        let error = DaemonError.taskFailed("something broke")
        let desc = String(describing: error)
        XCTAssertTrue(desc.contains("something broke") || desc.contains("taskFailed"))
    }
}

// MARK: - Daemon state tests

final class DaemonStateTests: XCTestCase {

    func testAllStatesAreDistinct() {
        let states: [DaemonState] = [.idle, .running, .draining, .stopped]
        XCTAssertEqual(states.count, Set(states).count, "All daemon states should be distinct")
    }

    func testDaemonStateEquatable() {
        XCTAssertEqual(DaemonState.idle, DaemonState.idle)
        XCTAssertEqual(DaemonState.running, DaemonState.running)
        XCTAssertEqual(DaemonState.draining, DaemonState.draining)
        XCTAssertEqual(DaemonState.stopped, DaemonState.stopped)
        XCTAssertNotEqual(DaemonState.idle, DaemonState.running)
        XCTAssertNotEqual(DaemonState.running, DaemonState.stopped)
    }
}
