import Foundation

// MARK: - HTTP Request

/// A parsed, immutable HTTP request.
public struct HTTPRequest: Sendable {
    /// The HTTP method (e.g. GET, POST).
    public let method: String
    /// The request path (e.g. /runs).
    public let path: String
    /// Lowercased header names mapped to values.
    public let headers: [String: String]
    /// Raw request body.
    public let body: Data

    public init(
        method: String,
        path: String,
        headers: [String: String],
        body: Data
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

// MARK: - HTTP Response

/// An HTTP response, optionally carrying an SSE stream.
///
/// When `sseStream` is non-nil the server sends SSE headers and
/// streams each string as a `data:` frame before closing.
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let statusText: String
    public let headers: [String: String]
    public let body: Data
    /// If non-nil, the server will stream the response as SSE.
    public let sseStream: AsyncThrowingStream<String, any Error>?

    public init(
        statusCode: Int,
        statusText: String = "",
        headers: [String: String] = [:],
        body: Data = Data(),
        sseStream: AsyncThrowingStream<String, any Error>? = nil
    ) {
        self.statusCode = statusCode
        self.statusText = statusText.isEmpty
            ? Self.defaultStatusText(for: statusCode)
            : statusText
        self.headers = headers
        self.body = body
        self.sseStream = sseStream
    }

    // MARK: - Factory helpers

    /// 200 OK with a UTF-8 plain-text body.
    public static func ok(text: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/plain"],
            body: text.data(using: .utf8) ?? Data()
        )
    }

    /// 200 OK with a JSON body.
    public static func ok(json: Data) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: json
        )
    }

    /// 202 Accepted.
    public static func accepted() -> HTTPResponse {
        HTTPResponse(statusCode: 202)
    }

    /// 400 Bad Request with a plain-text message.
    public static func badRequest(_ message: String = "Bad Request") -> HTTPResponse {
        HTTPResponse(
            statusCode: 400,
            headers: ["Content-Type": "text/plain"],
            body: message.data(using: .utf8) ?? Data()
        )
    }

    /// 404 Not Found.
    public static func notFound(_ message: String = "Not Found") -> HTTPResponse {
        HTTPResponse(
            statusCode: 404,
            headers: ["Content-Type": "text/plain"],
            body: message.data(using: .utf8) ?? Data()
        )
    }

    /// 500 Internal Server Error.
    public static func internalServerError(_ message: String = "Internal Server Error") -> HTTPResponse {
        HTTPResponse(
            statusCode: 500,
            headers: ["Content-Type": "text/plain"],
            body: message.data(using: .utf8) ?? Data()
        )
    }

    /// 200 OK with Server-Sent Events streaming.
    public static func sse(
        stream: AsyncThrowingStream<String, any Error>
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
            ],
            sseStream: stream
        )
    }

    // MARK: - Private helpers

    private static func defaultStatusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default:  return "Unknown"
        }
    }
}

// MARK: - SSE formatting

/// Utility for formatting Server-Sent Events frames.
public enum SSEStream {
    /// Creates a single SSE `data:` frame, with optional `event:` and `id:`.
    ///
    /// - Parameters:
    ///   - data: The event payload.
    ///   - id: Optional event identifier.
    ///   - event: Optional event type name.
    /// - Returns: A string suitable for writing to an SSE connection.
    public static func event(
        data: String,
        id: String? = nil,
        event: String? = nil
    ) -> String {
        var result = ""
        if let event = event {
            result += "event: \(event)\n"
        }
        if let id = id {
            result += "id: \(id)\n"
        }
        for line in data.components(separatedBy: .newlines) {
            result += "data: \(line)\n"
        }
        result += "\n"
        return result
    }

    /// The terminating SSE message.
    public static func done() -> String {
        "data: [DONE]\n\n"
    }
}

// MARK: - HTTP parsing (internal)

enum HTTPParser {
    /// Attempts to parse an HTTP request from raw bytes.
    /// Returns `nil` if the data is not a well-formed HTTP request.
    static func parse(data: Data) -> HTTPRequest? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }

        // Split headers from optional body.
        let parts = string.components(separatedBy: "\r\n\r\n")
        guard let headerSection = parts.first else { return nil }
        let bodySection = parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : ""

        var lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else { return nil }

        let method = requestParts[0].uppercased()
        let path = requestParts[1]

        var headers: [String: String] = [:]
        for line in lines {
            let kv = line.components(separatedBy: ": ")
            if kv.count == 2 {
                headers[kv[0].lowercased()] = kv[1]
            }
        }

        let body = bodySection.data(using: .utf8) ?? Data()

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

// MARK: - HTTP response formatting (internal)

enum HTTPFormatter {
    /// Formats a standard (non-streaming) HTTP response as raw bytes.
    static func format(response: HTTPResponse) -> Data {
        var output = "HTTP/1.1 \(response.statusCode) \(response.statusText)\r\n"
        var allHeaders = response.headers
        if response.sseStream == nil {
            allHeaders["Content-Length"] = "\(response.body.count)"
        }
        for (key, value) in allHeaders {
            output += "\(key): \(value)\r\n"
        }
        output += "\r\n"
        var data = output.data(using: .utf8) ?? Data()
        if response.sseStream == nil {
            data.append(response.body)
        }
        return data
    }

    /// Formats a single SSE frame for writing during a stream.
    static func sseFrame(_ s: String) -> Data {
        (s.data(using: .utf8) ?? Data())
    }
}
