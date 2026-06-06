import Foundation
import Darwin

// MARK: - Server errors

/// Errors thrown by the HTTP server.
public enum HTTPServerError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed
    case alreadyRunning
}

// MARK: - Handler type

/// A request handler that returns either a standard response or an SSE stream.
public typealias HTTPHandler = @Sendable (HTTPRequest) async -> HTTPResponse

// MARK: - HTTP Server

/// A minimal single-threaded HTTP 1.1 server backed by POSIX sockets and
/// a Dispatch source for async accept.
///
/// Pass a handler block at init; the handler receives parsed requests and
/// returns responses (including optional SSE streams).
public final class HTTPServer: @unchecked Sendable {
    private let port: UInt16
    private let handler: HTTPHandler
    private var socketFD: Int32 = -1
    private var dispatchSource: DispatchSourceRead?
    private var isRunning = false

    /// Creates a new server instance.
    ///
    /// - Parameters:
    ///   - port: TCP port to listen on.
    ///   - handler: Async handler that processes each request.
    public init(port: UInt16, handler: @escaping HTTPHandler) {
        self.port = port
        self.handler = handler
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Binds to the configured port and begins accepting connections.
    /// Returns immediately after the socket is listening.
    public func start() throws {
        guard !isRunning else { throw HTTPServerError.alreadyRunning }

        socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw HTTPServerError.socketCreationFailed
        }

        var value: Int32 = 1
        Darwin.setsockopt(
            socketFD, SOL_SOCKET, SO_REUSEADDR,
            &value, socklen_t(MemoryLayout<Int32>.size)
        )

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(socketFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult >= 0 else {
            Darwin.close(socketFD)
            socketFD = -1
            throw HTTPServerError.bindFailed
        }

        guard Darwin.listen(socketFD, 128) >= 0 else {
            Darwin.close(socketFD)
            socketFD = -1
            throw HTTPServerError.listenFailed
        }

        isRunning = true

        dispatchSource = DispatchSource.makeReadSource(
            fileDescriptor: socketFD,
            queue: .global()
        )
        dispatchSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        dispatchSource?.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                Darwin.close(fd)
                self?.socketFD = -1
            }
        }
        dispatchSource?.resume()
    }

    /// Stops the server, closing the listening socket.
    public func stop() {
        dispatchSource?.cancel()
        dispatchSource = nil
        isRunning = false
    }

    // MARK: - Private

    private func acceptConnection() {
        var clientAddr = sockaddr_in()
        var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.accept(socketFD, sa, &clientLen)
            }
        }

        guard clientFD >= 0 else { return }

        let handler = self.handler
        Task.detached {
            await Self.handleConnection(clientFD, handler: handler)
        }
    }

    /// Reads, routes, responds, and closes a single client connection.
    private static func handleConnection(
        _ fd: Int32,
        handler: @escaping HTTPHandler
    ) async {
        defer { Darwin.close(fd) }

        // Read request.
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = Darwin.read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        let data = Data(buffer[0..<bytesRead])

        guard let request = HTTPParser.parse(data: data) else {
            let errResp = HTTPFormatter.format(
                response: .badRequest("Malformed request")
            )
            _ = errResp.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!, errResp.count)
            }
            return
        }

        let response = await handler(request)

        // Standard response.
        if response.sseStream == nil {
            let respData = HTTPFormatter.format(response: response)
            _ = respData.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!, respData.count)
            }
            return
        }

        // SSE streaming response.
        // The handler yields fully-formatted SSE frames (data: ..., [DONE]);
        // we write them verbatim — no additional SSEStream.event() wrapping.
        let headerData = HTTPFormatter.format(response: response)
        _ = headerData.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, headerData.count)
        }

        guard let stream = response.sseStream else { return }

        do {
            for try await chunk in stream {
                // chunk is already a fully-formatted SSE frame from the handler
                let frameData = HTTPFormatter.sseFrame(chunk)
                _ = frameData.withUnsafeBytes { ptr in
                    Darwin.write(fd, ptr.baseAddress!, frameData.count)
                }
            }
            // [DONE] is already sent by the handler; no extra frame here.
        } catch {
            let errFrame = SSEStream.event(
                data: "[ERROR] \(error)",
                event: "error"
            )
            let errData = HTTPFormatter.sseFrame(errFrame)
            _ = errData.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!, errData.count)
            }
        }
    }
}
