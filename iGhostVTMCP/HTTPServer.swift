import Darwin
import Dispatch
import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Parses `application/x-www-form-urlencoded` body into key-value pairs.
    func formParameters() -> [String: String] {
        guard let raw = String(data: body, encoding: .utf8), !raw.isEmpty else {
            return [:]
        }
        return Self.parseFormEncoded(raw)
    }

    static func parseFormEncoded(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decodeFormComponent(String(parts[0]))
            let value = parts.count > 1 ? decodeFormComponent(String(parts[1])) : ""
            result[key] = value
        }
        return result
    }

    private static func decodeFormComponent(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}

struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [(String, String)]
    var body: Data

    init(status: Int, reason: String? = nil, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.reason = reason ?? Self.defaultReason(for: status)
        self.headers = headers
        self.body = body
    }

    static func json(_ object: Any, status: Int = 200, extraHeaders: [(String, String)] = []) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var headers: [(String, String)] = [
            ("Content-Type", "application/json; charset=utf-8"),
            ("Cache-Control", "no-store"),
        ]
        headers.append(contentsOf: extraHeaders)
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    static let defaultContentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'"

    static func html(
        _ html: String,
        status: Int = 200,
        extraHeaders: [(String, String)] = [],
        contentSecurityPolicy: String = defaultContentSecurityPolicy,
    ) -> HTTPResponse {
        var headers: [(String, String)] = [
            ("Content-Type", "text/html; charset=utf-8"),
            ("Cache-Control", "no-store"),
            ("X-Frame-Options", "DENY"),
            ("Content-Security-Policy", contentSecurityPolicy),
        ]
        headers.append(contentsOf: extraHeaders)
        return HTTPResponse(status: status, headers: headers, body: Data(html.utf8))
    }

    static func text(_ text: String, status: Int = 200, extraHeaders: [(String, String)] = []) -> HTTPResponse {
        var headers: [(String, String)] = [
            ("Content-Type", "text/plain; charset=utf-8"),
            ("Cache-Control", "no-store"),
        ]
        headers.append(contentsOf: extraHeaders)
        return HTTPResponse(status: status, headers: headers, body: Data(text.utf8))
    }

    static func redirect(to location: String) -> HTTPResponse {
        HTTPResponse(
            status: 302,
            headers: [
                ("Location", location),
                ("Cache-Control", "no-store"),
            ],
        )
    }

    func serialize() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var hasContentLength = false
        var hasConnection = false
        for (name, value) in headers {
            let lower = name.lowercased()
            if lower == "content-length" { hasContentLength = true }
            if lower == "connection" { hasConnection = true }
            head += "\(name): \(value)\r\n"
        }
        if !hasContentLength {
            head += "Content-Length: \(body.count)\r\n"
        }
        if !hasConnection {
            head += "Connection: close\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func defaultReason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 302: "Found"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}

/// Minimal HTTP/1.1 server built on Network.framework (zero third-party deps).
///
/// It listens on every address this device has, so an app on another device
/// on the local network can reach it, and serves only a peer on the local
/// network or this device (`RemoteNetwork.isLocal`): a Mac with a public
/// address takes no request from the internet, and neither does a tunnel.
final class LocalHTTPServer {
    private static let maxHeaderBytes = 32 * 1024
    private static let maxBodyBytes = 2 * 1024 * 1024

    private let requestedPort: UInt16
    private let handler: (HTTPRequest) -> HTTPResponse
    private let listenerQueue = DispatchQueue(label: "wiki.qaq.ighostvt.mcp.http")
    private let workerQueue = DispatchQueue(label: "wiki.qaq.ighostvt.mcp.worker", attributes: .concurrent)

    private var listener: NWListener?
    private(set) var boundPort: UInt16 = 0

    init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.requestedPort = port
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Off every tunnel and cellular, as remote access keeps its own
        // local links; loopback, Wi-Fi and wired stay.
        parameters.prohibitedInterfaceTypes = [.cellular, .other]

        // The port is named once, here. A required local endpoint beside it
        // (how the loopback-only listener was bound) fails with EINVAL.
        let nwPort = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        let listener = try NWListener(using: parameters, on: nwPort)

        let readySemaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.boundPort = listener.port?.rawValue ?? self?.requestedPort ?? 0
                readySemaphore.signal()
            case let .failed(error):
                if startError == nil {
                    startError = error
                    readySemaphore.signal()
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: listenerQueue)
        self.listener = listener

        if readySemaphore.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw NSError(domain: "LocalHTTPServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out binding port \(requestedPort)"])
        }
        if let startError {
            listener.cancel()
            throw startError
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        guard RemoteNetwork.isLocal(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: listenerQueue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let content {
                accumulated.append(content)
            }

            switch Self.tryParseRequest(accumulated) {
            case .incomplete:
                if isComplete {
                    connection.cancel()
                    return
                }
                if accumulated.count > Self.maxHeaderBytes + Self.maxBodyBytes {
                    self.send(HTTPResponse.text("Payload too large", status: 413), on: connection)
                    return
                }
                self.readRequest(on: connection, buffer: accumulated)

            case let .invalid(status, message):
                self.send(HTTPResponse.text(message, status: status), on: connection)

            case let .complete(request):
                self.workerQueue.async {
                    let response = self.handler(request)
                    self.send(response, on: connection)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private enum ParseResult {
        case incomplete
        case invalid(Int, String)
        case complete(HTTPRequest)
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private static func tryParseRequest(_ data: Data) -> ParseResult {
        guard let range = data.range(of: headerTerminator) else {
            if data.count > maxHeaderBytes {
                return .invalid(400, "Headers too large")
            }
            return .incomplete
        }

        let headerData = data[..<range.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid(400, "Invalid header encoding")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid(400, "Missing request line")
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .invalid(400, "Malformed request line")
        }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else {
                return .invalid(400, "Invalid Content-Length")
            }
            if parsed > maxBodyBytes {
                return .invalid(413, "Payload too large")
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }

        let bodyStart = range.upperBound
        let availableBody = data.count - bodyStart
        if availableBody < contentLength {
            return .incomplete
        }

        let body = contentLength > 0 ? data[bodyStart ..< (bodyStart + contentLength)] : Data()

        let path: String
        let query: [String: String]
        if let qIndex = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<qIndex])
            query = HTTPRequest.parseFormEncoded(String(rawTarget[rawTarget.index(after: qIndex)...]))
        } else {
            path = rawTarget
            query = [:]
        }

        return .complete(HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: Data(body),
        ))
    }
}
