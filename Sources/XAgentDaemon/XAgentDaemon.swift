import Foundation
import XAgentCore

// MARK: - xagentd — user-space agent daemon
//
// Hosts an AgentRuntime with graceful start/stop via POSIX signals
// and an event-store hook that captures every run invocation.

// MARK: - Event store hook

/// A hook that receives an event record each time the daemon runs a task.
/// Implementations may persist events to a file, database, or log stream.
public protocol EventStore: Sendable {
    /// Called synchronously after each `run(task:)` completes (success or failure).
    /// - Parameters:
    ///   - event: A structured record of the run invocation.
    func record(_ event: RunEvent) async
}

/// A single run invocation captured by the event store.
public struct RunEvent: Sendable, Codable {
    /// The task string submitted to the runtime.
    public let task: String
    /// When the run started (wall-clock).
    public let startedAt: Date
    /// When the run finished (wall-clock).
    public let finishedAt: Date
    /// The result text on success, or `nil` on failure.
    public let result: String?
    /// The error description on failure, or `nil` on success.
    public let error: String?

    public init(
        task: String,
        startedAt: Date,
        finishedAt: Date,
        result: String?,
        error: String?
    ) {
        self.task = task
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.result = result
        self.error = error
    }
}

// MARK: - Default (no-op) event store

/// An event store that silently discards all events.
/// Use as a placeholder when no persistence is configured.
public struct NoOpEventStore: EventStore {
    public init() {}
    public func record(_ event: RunEvent) async {}
}

// MARK: - Daemon state

/// Lifecycle states for the daemon.
public enum DaemonState: Sendable, Equatable {
    /// Daemon has been created but `start()` has not been called.
    case idle
    /// Daemon is running and accepting tasks.
    case running
    /// A shutdown has been requested; the daemon is draining in-flight work.
    case draining
    /// The daemon has stopped.
    case stopped
}

// MARK: - Daemon

/// The xagentd daemon: hosts an AgentRuntime, handles graceful start/stop,
/// and emits run events to an EventStore.
public actor XAgentDaemon {
    private let runtime: AgentRuntime
    private let eventStore: any EventStore

    /// Current lifecycle state.
    public private(set) var state: DaemonState = .idle

    /// Set to `true` when a shutdown signal (SIGINT / SIGTERM) is received.
    private var shutdownRequested = false

    /// Counter of completed runs (success + failure).
    public private(set) var runCount: Int = 0

    // MARK: - Initialization

    /// Creates a new daemon instance.
    /// - Parameters:
    ///   - runtime: A configured `AgentRuntime`.
    ///   - eventStore: Hook for persisting run events. Defaults to ``NoOpEventStore``.
    public init(
        runtime: AgentRuntime,
        eventStore: any EventStore = NoOpEventStore()
    ) {
        self.runtime = runtime
        self.eventStore = eventStore
    }

    // MARK: - Lifecycle

    /// Starts the daemon, registering signal handlers and entering the run loop.
    ///
    /// Callers should invoke this from an `async` context; the method blocks
    /// until `shutdown()` is called or a signal is received.
    public func start() async {
        guard state == .idle else { return }
        state = .running
        installSignalHandlers()
    }

    /// Requests a graceful shutdown.  In-flight tasks are allowed to complete;
    /// new tasks submitted after this call are rejected.
    public func shutdown() {
        shutdownRequested = true
        if state == .running {
            state = .draining
        }
    }

    /// Marks the daemon as fully stopped once draining is complete.
    public func markStopped() {
        state = .stopped
    }

    // MARK: - Task execution

    /// Runs a user task through the hosted AgentRuntime and records the event.
    ///
    /// - Parameter task: Natural-language task description.
    /// - Returns: The agent's response text.
    /// - Throws: ``DaemonError`` if the daemon is not running, or rethrows
    ///   errors from the underlying `AgentRuntime`.
    public func run(task: String) async throws -> String {
        guard state == .running else {
            throw DaemonError.notRunning
        }

        let startedAt = Date()
        let result: String
        let errorMessage: String?

        do {
            result = try await runtime.run(task: task)
            errorMessage = nil
        } catch {
            result = ""
            errorMessage = String(describing: error)
        }

        let finishedAt = Date()

        let event = RunEvent(
            task: task,
            startedAt: startedAt,
            finishedAt: finishedAt,
            result: errorMessage == nil ? result : nil,
            error: errorMessage
        )
        await eventStore.record(event)
        runCount += 1

        if let error = errorMessage {
            throw DaemonError.taskFailed(error)
        }

        return result
    }

    /// Runs a user task through the hosted AgentRuntime in streaming mode
    /// and records the event when the stream completes.
    ///
    /// - Parameter task: Natural-language task description.
    /// - Returns: An `AsyncThrowingStream` that yields LLM chunks and tool results.
    public func runStreaming(task: String) async -> AsyncThrowingStream<String, Error> {
        let runtimeStream = await runtime.runStreaming(task: task)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        Task {
            let startedAt = Date()
            var buffer = ""

            do {
                for try await chunk in runtimeStream {
                    buffer += chunk
                    continuation.yield(chunk)
                }

                let finishedAt = Date()
                let event = RunEvent(
                    task: task,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    result: buffer,
                    error: nil
                )
                await self.eventStore.record(event)
                await self.incrementRunCount()

                continuation.finish()
            } catch {
                let finishedAt = Date()
                let event = RunEvent(
                    task: task,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    result: nil,
                    error: String(describing: error)
                )
                await self.eventStore.record(event)
                await self.incrementRunCount()

                continuation.finish(throwing: error)
            }
        }

        return stream
    }

    // MARK: - Private helpers

    private func incrementRunCount() async {
        runCount += 1
    }

    /// Registers signal handlers for SIGINT and SIGTERM that trigger
    /// a graceful shutdown.
    private func installSignalHandlers() {
        // SIGINT (Ctrl-C)
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler { [weak self] in
            Task {
                await self?.shutdown()
            }
        }
        sigintSource.resume()

        // SIGTERM
        signal(SIGTERM, SIG_IGN)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler { [weak self] in
            Task {
                await self?.shutdown()
            }
        }
        sigtermSource.resume()
    }
}

// MARK: - Daemon errors

public enum DaemonError: Error, Sendable, Equatable {
    /// A task was submitted while the daemon is not in the `.running` state.
    case notRunning
    /// The underlying AgentRuntime threw an error during task execution.
    case taskFailed(String)
}
