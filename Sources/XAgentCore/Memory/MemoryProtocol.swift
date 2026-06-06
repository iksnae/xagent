import Foundation

// MARK: - Data records

/// A single agent run — one task execution from start to finish.
public struct RunRecord: Sendable, Codable, Equatable {
    public let id: UUID
    public let agentID: String
    public let task: String
    public let createdAt: Date
    public let finishedAt: Date?
    public let output: String?

    public init(
        id: UUID = UUID(),
        agentID: String,
        task: String,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        output: String? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.task = task
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.output = output
    }
}

/// A single message within a conversation — the immutable record of a turn.
public struct MessageRecord: Sendable, Codable, Equatable {
    public let id: UUID
    public let runID: UUID
    public let role: String
    public let content: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        role: String,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

// MARK: - Memory protocol

/// The persistence contract for agent run history and conversation storage.
public protocol Memory: Sendable {
    /// Insert a new run record.  Implementations should assign an id if
    /// the caller supplied a nil-UUID.
    @discardableResult
    func insert(run: RunRecord) async throws -> RunRecord

    /// Update an existing run — typically to set `finishedAt` and `output`.
    @discardableResult
    func update(run: RunRecord) async throws -> RunRecord?

    /// Fetch the run identified by `id`, or `nil` when no such run exists.
    func run(id: UUID) async throws -> RunRecord?

    /// Return every run, ordered most-recent-first by `createdAt`.
    func allRuns() async throws -> [RunRecord]

    /// Return runs belonging to a specific agent, ordered most-recent-first.
    func runs(agentID: String) async throws -> [RunRecord]

    /// Append a message to a run's conversation.
    @discardableResult
    func insert(message: MessageRecord) async throws -> MessageRecord

    /// Retrieve all messages for a given run, ordered oldest-first.
    func messages(runID: UUID) async throws -> [MessageRecord]
}
