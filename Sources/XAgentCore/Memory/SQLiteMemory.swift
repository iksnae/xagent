import Foundation
import CSQLite3

/// SQLite-backed implementation of the `Memory` protocol.
///
/// Each instance manages its own database connection.  The database is
/// stored at the URL passed at init time; when that URL is `nil` an
/// in-memory database is opened instead (useful for testing or transient
/// agents).
public final class SQLiteMemory: Memory, @unchecked Sendable {
    private nonisolated(unsafe) let db: OpaquePointer
    private let queue = DispatchQueue(label: "xagent.sqlitememory", qos: .utility)

    // MARK: - Init / deinit

    /// Create a new SQLite-backed memory store.
    ///
    /// - Parameter url: File URL for the database.  Pass `nil` for an
    ///   in-memory store.
    public init(url: URL?) throws {
        var handle: OpaquePointer?
        let path = url?.path ?? ":memory:"
        let rc = sqlite3_open(path, &handle)
        guard rc == SQLITE_OK, let db = handle else {
            throw SQLiteMemoryError.openFailed(Int32(rc))
        }
        self.db = db
        // Create schema synchronously during init — safe because the
        // instance is not yet shared.
        try Self.execSync(db: db, sql: """
            CREATE TABLE IF NOT EXISTS runs (
                id         TEXT PRIMARY KEY,
                agent_id   TEXT NOT NULL,
                task       TEXT NOT NULL,
                created_at REAL NOT NULL,
                finished_at REAL,
                output     TEXT
            );
            """)
        try Self.execSync(db: db, sql: """
            CREATE TABLE IF NOT EXISTS messages (
                id         TEXT PRIMARY KEY,
                run_id     TEXT NOT NULL,
                role       TEXT NOT NULL,
                content    TEXT NOT NULL,
                timestamp  REAL NOT NULL,
                FOREIGN KEY (run_id) REFERENCES runs(id)
            );
            """)
        try Self.execSync(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_messages_run_id ON messages(run_id);")
        try Self.execSync(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_runs_agent_id ON runs(agent_id);")
        try Self.execSync(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_runs_created_at ON runs(created_at);")
        try Self.execSync(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp);")
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Run operations

    @discardableResult
    public func insert(run: RunRecord) async throws -> RunRecord {
        let sql = """
            INSERT INTO runs (id, agent_id, task, created_at, finished_at, output)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        try await execPrepared(sql) { stmt in
            Self.bind(text: run.id.uuidString, to: stmt, index: 1)
            Self.bind(text: run.agentID, to: stmt, index: 2)
            Self.bind(text: run.task, to: stmt, index: 3)
            Self.bind(real: run.createdAt.timeIntervalSince1970, to: stmt, index: 4)
            if let fa = run.finishedAt {
                Self.bind(real: fa.timeIntervalSince1970, to: stmt, index: 5)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            if let out = run.output {
                Self.bind(text: out, to: stmt, index: 6)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
        }
        return run
    }

    @discardableResult
    public func update(run: RunRecord) async throws -> RunRecord? {
        // Ensure the row exists first.
        guard let _ = try await self.run(id: run.id) else { return nil }
        let sql = """
            UPDATE runs
            SET agent_id = ?, task = ?, created_at = ?,
                finished_at = ?, output = ?
            WHERE id = ?;
            """
        try await execPrepared(sql) { stmt in
            Self.bind(text: run.agentID, to: stmt, index: 1)
            Self.bind(text: run.task, to: stmt, index: 2)
            Self.bind(real: run.createdAt.timeIntervalSince1970, to: stmt, index: 3)
            if let fa = run.finishedAt {
                Self.bind(real: fa.timeIntervalSince1970, to: stmt, index: 4)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            if let out = run.output {
                Self.bind(text: out, to: stmt, index: 5)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            Self.bind(text: run.id.uuidString, to: stmt, index: 6)
        }
        return run
    }

    public func run(id: UUID) async throws -> RunRecord? {
        let sql = "SELECT id, agent_id, task, created_at, finished_at, output FROM runs WHERE id = ?;"
        let rows: [RunRecord] = try await query(sql) { stmt in
            Self.bind(text: id.uuidString, to: stmt, index: 1)
        } mapRow: { stmt in
            Self.mapRun(stmt)
        }
        return rows.first
    }

    public func allRuns() async throws -> [RunRecord] {
        let sql = "SELECT id, agent_id, task, created_at, finished_at, output FROM runs ORDER BY created_at DESC;"
        return try await query(sql, bind: { _ in }, mapRow: { stmt in Self.mapRun(stmt) })
    }

    public func runs(agentID: String) async throws -> [RunRecord] {
        let sql = "SELECT id, agent_id, task, created_at, finished_at, output FROM runs WHERE agent_id = ? ORDER BY created_at DESC;"
        return try await query(sql) { stmt in
            Self.bind(text: agentID, to: stmt, index: 1)
        } mapRow: { stmt in
            Self.mapRun(stmt)
        }
    }

    // MARK: - Message operations

    @discardableResult
    public func insert(message: MessageRecord) async throws -> MessageRecord {
        let sql = """
            INSERT INTO messages (id, run_id, role, content, timestamp)
            VALUES (?, ?, ?, ?, ?);
            """
        try await execPrepared(sql) { stmt in
            Self.bind(text: message.id.uuidString, to: stmt, index: 1)
            Self.bind(text: message.runID.uuidString, to: stmt, index: 2)
            Self.bind(text: message.role, to: stmt, index: 3)
            Self.bind(text: message.content, to: stmt, index: 4)
            Self.bind(real: message.timestamp.timeIntervalSince1970, to: stmt, index: 5)
        }
        return message
    }

    public func messages(runID: UUID) async throws -> [MessageRecord] {
        let sql = "SELECT id, run_id, role, content, timestamp FROM messages WHERE run_id = ? ORDER BY timestamp ASC;"
        return try await query(sql) { stmt in
            Self.bind(text: runID.uuidString, to: stmt, index: 1)
        } mapRow: { stmt in
            Self.mapMessage(stmt)
        }
    }

    // MARK: - Row mapping helpers (static to avoid Sendable capture issues)

    private static func mapRun(_ stmt: OpaquePointer?) -> RunRecord {
        let idStr  = String(cString: sqlite3_column_text(stmt, 0))
        let agt    = String(cString: sqlite3_column_text(stmt, 1))
        let tsk    = String(cString: sqlite3_column_text(stmt, 2))
        let ca     = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))

        let fa: Date? = sqlite3_column_type(stmt, 4) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            : nil

        let out: String? = sqlite3_column_type(stmt, 5) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 5))
            : nil

        return RunRecord(
            id: UUID(uuidString: idStr) ?? UUID(),
            agentID: agt,
            task: tsk,
            createdAt: ca,
            finishedAt: fa,
            output: out
        )
    }

    private static func mapMessage(_ stmt: OpaquePointer?) -> MessageRecord {
        let idStr   = String(cString: sqlite3_column_text(stmt, 0))
        let ridStr  = String(cString: sqlite3_column_text(stmt, 1))
        let rl      = String(cString: sqlite3_column_text(stmt, 2))
        let cnt     = String(cString: sqlite3_column_text(stmt, 3))
        let ts      = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))

        return MessageRecord(
            id: UUID(uuidString: idStr) ?? UUID(),
            runID: UUID(uuidString: ridStr) ?? UUID(),
            role: rl,
            content: cnt,
            timestamp: ts
        )
    }

    // MARK: - Synchronous helper (used only during init)

    private static func execSync(db: OpaquePointer, sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteMemoryError.execFailed(Int32(rc), msg)
        }
    }

    // MARK: - Async low-level SQLite helpers

    private func execPrepared(
        _ sql: String,
        bind: @escaping @Sendable (OpaquePointer?) throws -> Void
    ) async throws {
        let db = self.db
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                var stmt: OpaquePointer?
                let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
                guard rc == SQLITE_OK, let s = stmt else {
                    let msg = String(cString: sqlite3_errmsg(db))
                    cont.resume(throwing: SQLiteMemoryError.prepareFailed(Int32(rc), msg))
                    return
                }
                defer { sqlite3_finalize(s) }

                do {
                    try bind(s)
                    let stepRc = sqlite3_step(s)
                    if stepRc != SQLITE_DONE {
                        let msg = String(cString: sqlite3_errmsg(db))
                        cont.resume(throwing: SQLiteMemoryError.stepFailed(Int32(stepRc), msg))
                    } else {
                        cont.resume()
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func query<T: Sendable>(
        _ sql: String,
        bind: @escaping @Sendable (OpaquePointer?) throws -> Void,
        mapRow: @escaping @Sendable (OpaquePointer?) -> T
    ) async throws -> [T] {
        let db = self.db
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[T], Error>) in
            queue.async {
                var stmt: OpaquePointer?
                let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
                guard rc == SQLITE_OK, let s = stmt else {
                    let msg = String(cString: sqlite3_errmsg(db))
                    cont.resume(throwing: SQLiteMemoryError.prepareFailed(Int32(rc), msg))
                    return
                }
                defer { sqlite3_finalize(s) }

                do {
                    try bind(s)
                    cont.resume(returning: Self.collectRows(s, mapRow: mapRow))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Collect all rows from a prepared statement that has been bound and
    /// is ready to step.  Extracted to a standalone function so the
    /// returned array is clearly transferred (no mutable variable crosses
    /// the sendable boundary).
    private static func collectRows<T>(
        _ stmt: OpaquePointer,
        mapRow: @Sendable (OpaquePointer?) -> T
    ) -> [T] {
        var rows: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(mapRow(stmt))
        }
        return rows
    }

    // MARK: - Binding helpers (static to avoid Sendable capture issues)

    /// `SQLITE_TRANSIENT` instructs SQLite to make its own private copy of
    /// the bound text before `sqlite3_bind_text` returns.  The C macro
    /// `SQLITE_TRANSIENT` is `((sqlite3_destructor_type)-1)` which is not
    /// imported into Swift, so we replicate it with `unsafeBitCast`.
    private static let SQLITE_TRANSIENT: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = {
        unsafeBitCast(-1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    }()

    /// Bind a text value, asking SQLite to copy the string immediately.
    private static func bind(text: String, to stmt: OpaquePointer?, index: Int32) {
        _ = text.withCString { cStr in
            sqlite3_bind_text(stmt, index, cStr, -1, Self.SQLITE_TRANSIENT)
        }
    }

    private static func bind(real: TimeInterval, to stmt: OpaquePointer?, index: Int32) {
        sqlite3_bind_double(stmt, index, real)
    }
}

// MARK: - Errors

public enum SQLiteMemoryError: Error, Sendable {
    case openFailed(Int32)
    case execFailed(Int32, String)
    case prepareFailed(Int32, String)
    case stepFailed(Int32, String)
}
