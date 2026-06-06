import XCTest
@testable import XAgentCore

final class MemoryTests: XCTestCase {

    // MARK: - Helpers

    func makeMemory() throws -> SQLiteMemory {
        try SQLiteMemory(url: nil) // in-memory
    }

    func makeRun(
        agentID: String = "test-agent",
        task: String = "Hello, world",
        finishedAt: Date? = nil,
        output: String? = nil
    ) -> RunRecord {
        RunRecord(
            agentID: agentID,
            task: task,
            finishedAt: finishedAt,
            output: output
        )
    }

    func makeMessage(
        runID: UUID,
        role: String = "user",
        content: String = "Hello"
    ) -> MessageRecord {
        MessageRecord(runID: runID, role: role, content: content)
    }

    // MARK: - RunRecord Equatable

    func testRunRecordEquatable() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let now = Date()
        let a = RunRecord(
            id: id,
            agentID: "a",
            task: "task-a",
            createdAt: now
        )
        let b = RunRecord(
            id: id,
            agentID: "a",
            task: "task-a",
            createdAt: now
        )
        let c = RunRecord(agentID: "b", task: "task-b")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - MessageRecord Equatable

    func testMessageRecordEquatable() {
        let runID = UUID()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let now = Date()
        let a = MessageRecord(
            id: id,
            runID: runID,
            role: "user",
            content: "hello",
            timestamp: now
        )
        let b = MessageRecord(
            id: id,
            runID: runID,
            role: "user",
            content: "hello",
            timestamp: now
        )
        let c = MessageRecord(runID: runID, role: "assistant", content: "hi")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - SQLiteMemory conforms to Memory protocol

    func testSQLiteMemoryConformsToMemoryProtocol() throws {
        let mem = try makeMemory()
        // Compile-time check: assign to Memory existential.
        let _: any Memory = mem
    }

    // MARK: - Insert & fetch run

    func testInsertAndFetchRun() async throws {
        let mem = try makeMemory()
        let run = makeRun(agentID: "bot-1", task: "Say hello")
        let inserted = try await mem.insert(run: run)

        XCTAssertEqual(inserted.id, run.id)
        XCTAssertEqual(inserted.agentID, "bot-1")
        XCTAssertEqual(inserted.task, "Say hello")

        let fetched = try await mem.run(id: run.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, run.id)
        XCTAssertEqual(fetched?.agentID, "bot-1")
        XCTAssertEqual(fetched?.task, "Say hello")
    }

    func testInsertRunWithEmptyTask() async throws {
        let mem = try makeMemory()
        let run = makeRun(agentID: "bot-2", task: "")
        let inserted = try await mem.insert(run: run)

        XCTAssertEqual(inserted.task, "")
        let fetched = try await mem.run(id: run.id)
        XCTAssertEqual(fetched?.task, "")
    }

    func testInsertRunWithOutputAndFinishedAt() async throws {
        let mem = try makeMemory()
        let finished = Date().addingTimeInterval(30)
        let run = RunRecord(
            agentID: "bot-3",
            task: "Compute",
            finishedAt: finished,
            output: "42"
        )
        let inserted = try await mem.insert(run: run)

        XCTAssertEqual(inserted.output, "42")
        XCTAssertNotNil(inserted.finishedAt)

        let fetched = try await mem.run(id: run.id)
        XCTAssertEqual(fetched?.output, "42")
        XCTAssertNotNil(fetched?.finishedAt)
        if let fa = fetched?.finishedAt {
            XCTAssertEqual(fa.timeIntervalSince1970, finished.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    // MARK: - Fetch nonexistent

    func testFetchNonexistentRunReturnsNil() async throws {
        let mem = try makeMemory()
        let fetched = try await mem.run(id: UUID())
        XCTAssertNil(fetched)
    }

    // MARK: - All runs (most recent first)

    func testAllRunsReturnsMostRecentFirst() async throws {
        let mem = try makeMemory()

        let r1 = makeRun(agentID: "a", task: "first")
        let r2 = makeRun(agentID: "a", task: "second")
        let r3 = makeRun(agentID: "a", task: "third")

        // Insert with small delays so createdAt differs.
        try await mem.insert(run: r1)
        try await Task.sleep(nanoseconds: 10_000_000)
        try await mem.insert(run: r2)
        try await Task.sleep(nanoseconds: 10_000_000)
        try await mem.insert(run: r3)

        let runs = try await mem.allRuns()
        XCTAssertEqual(runs.count, 3)
        // Most recent first.
        XCTAssertEqual(runs[0].id, r3.id)
        XCTAssertEqual(runs[1].id, r2.id)
        XCTAssertEqual(runs[2].id, r1.id)
    }

    // MARK: - Runs by agent ID

    func testRunsByAgentID() async throws {
        let mem = try makeMemory()

        let r1 = makeRun(agentID: "agent-x", task: "x1")
        let r2 = makeRun(agentID: "agent-x", task: "x2")
        let r3 = makeRun(agentID: "agent-y", task: "y1")

        try await mem.insert(run: r1)
        try await Task.sleep(nanoseconds: 10_000_000)
        try await mem.insert(run: r2)
        try await mem.insert(run: r3)

        let xRuns = try await mem.runs(agentID: "agent-x")
        XCTAssertEqual(xRuns.count, 2)
        XCTAssertEqual(xRuns.map(\.agentID), ["agent-x", "agent-x"])

        let yRuns = try await mem.runs(agentID: "agent-y")
        XCTAssertEqual(yRuns.count, 1)
        XCTAssertEqual(yRuns.first?.task, "y1")

        let noRuns = try await mem.runs(agentID: "nonexistent")
        XCTAssertTrue(noRuns.isEmpty)
    }

    // MARK: - Update run

    func testUpdateRun() async throws {
        let mem = try makeMemory()
        let run = makeRun(agentID: "bot-u", task: "original")
        try await mem.insert(run: run)

        let finished = Date()
        let updated = RunRecord(
            id: run.id,
            agentID: run.agentID,
            task: "updated task",
            createdAt: run.createdAt,
            finishedAt: finished,
            output: "done"
        )

        let result = try await mem.update(run: updated)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.task, "updated task")
        XCTAssertEqual(result?.output, "done")

        let fetched = try await mem.run(id: run.id)
        XCTAssertEqual(fetched?.task, "updated task")
        XCTAssertEqual(fetched?.output, "done")
    }

    // MARK: - Insert & fetch messages

    func testInsertAndFetchMessages() async throws {
        let mem = try makeMemory()
        let run = try await mem.insert(run: makeRun())

        let m1 = makeMessage(runID: run.id, role: "user", content: "Hello")
        let m2 = makeMessage(runID: run.id, role: "assistant", content: "Hi there!")

        try await mem.insert(message: m1)
        try await mem.insert(message: m2)

        let msgs = try await mem.messages(runID: run.id)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, "user")
        XCTAssertEqual(msgs[1].role, "assistant")
        XCTAssertEqual(msgs[0].content, "Hello")
        XCTAssertEqual(msgs[1].content, "Hi there!")
    }

    func testInsertMessageWithToolRole() async throws {
        let mem = try makeMemory()
        let run = try await mem.insert(run: makeRun())

        let toolMsg = makeMessage(runID: run.id, role: "tool", content: "result")
        try await mem.insert(message: toolMsg)

        let msgs = try await mem.messages(runID: run.id)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].role, "tool")
    }

    func testInsertMessageWithEmptyContent() async throws {
        let mem = try makeMemory()
        let run = try await mem.insert(run: makeRun())

        let msg = makeMessage(runID: run.id, role: "user", content: "")
        try await mem.insert(message: msg)

        let msgs = try await mem.messages(runID: run.id)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].content, "")
    }

    // MARK: - Messages for nonexistent run

    func testMessagesForNonexistentRunReturnsEmpty() async throws {
        let mem = try makeMemory()
        let msgs = try await mem.messages(runID: UUID())
        XCTAssertTrue(msgs.isEmpty)
    }

    // MARK: - Messages across multiple runs

    func testMessagesAcrossMultipleRuns() async throws {
        let mem = try makeMemory()

        let run1 = try await mem.insert(run: makeRun(agentID: "a", task: "first"))
        let run2 = try await mem.insert(run: makeRun(agentID: "a", task: "second"))

        try await mem.insert(message: makeMessage(runID: run1.id, content: "run1-msg1"))
        try await mem.insert(message: makeMessage(runID: run1.id, content: "run1-msg2"))
        try await mem.insert(message: makeMessage(runID: run2.id, content: "run2-msg1"))

        let msgs1 = try await mem.messages(runID: run1.id)
        XCTAssertEqual(msgs1.count, 2)
        XCTAssertEqual(msgs1.map(\.content), ["run1-msg1", "run1-msg2"])

        let msgs2 = try await mem.messages(runID: run2.id)
        XCTAssertEqual(msgs2.count, 1)
        XCTAssertEqual(msgs2[0].content, "run2-msg1")
    }

    // MARK: - Messages ordered by timestamp

    func testMessagesOrderedByTimestamp() async throws {
        let mem = try makeMemory()
        let run = try await mem.insert(run: makeRun())

        let m1 = makeMessage(runID: run.id, role: "user", content: "first")
        let m2 = makeMessage(runID: run.id, role: "assistant", content: "second")
        let m3 = makeMessage(runID: run.id, role: "user", content: "third")

        try await mem.insert(message: m1)
        try await Task.sleep(nanoseconds: 10_000_000)
        try await mem.insert(message: m2)
        try await Task.sleep(nanoseconds: 10_000_000)
        try await mem.insert(message: m3)

        let msgs = try await mem.messages(runID: run.id)
        XCTAssertEqual(msgs.count, 3)
        // Oldest first by timestamp.
        XCTAssertEqual(msgs.map(\.content), ["first", "second", "third"])
    }
}
