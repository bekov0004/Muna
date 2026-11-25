import Foundation

/// The start of an HTTP/1.1 request.
public struct HTTPRequestHead: Equatable {
    public var method: String
    /// The path without the query, e.g. "/api/localsend/v2/upload".
    public var path: String
    public var query: [String: String]
    /// Header names in lower case.
    public var headers: [String: String]

    public var contentLength: Int? { headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    public var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false }
    public var keepAlive: Bool { headers["connection"]?.lowercased() != "close" }

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
    }
}

public enum HTTPError: Error, Equatable {
    case badRequest(String)
    case headTooLarge
}

/// Reads HTTP/1.1 requests from the bytes of a connection, piece by piece: the head, then the body
/// in chunks as it arrives (an upload is never held in memory whole), then the end. Several
/// requests may follow each other on one connection.
public final class HTTPRequestParser {
    public enum Event: Equatable {
        case head(HTTPRequestHead)
        case body(Data)
        case end
    }

    public static let maxHeadSize = 64 * 1024

    private enum State {
        case head
        case body(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkDataEnd
        case trailers
    }

    private var state = State.head
    private var buffer = Data()

    public init() {}

    /// Takes the next bytes; returns what they completed.
    public func feed(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while true {
            switch state {
            case .head:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > Self.maxHeadSize { throw HTTPError.headTooLarge }
                    return events
                }
                let head = try Self.parseHead(buffer.subdata(in: buffer.startIndex..<end.lowerBound))
                buffer = Data(buffer[end.upperBound...])
                events.append(.head(head))
                if head.isChunked {
                    state = .chunkSize
                } else if let length = head.contentLength, length > 0 {
                    state = .body(remaining: length)
                } else {
                    events.append(.end)
                    state = .head
                }
            case .body(let remaining):
                guard !buffer.isEmpty else { return events }
                let take = min(remaining, buffer.count)
                events.append(.body(Data(buffer.prefix(take))))
                buffer = Data(buffer.dropFirst(take))
                if take == remaining {
                    events.append(.end)
                    state = .head
                } else {
                    state = .body(remaining: remaining - take)
                    return events
                }
            case .chunkSize:
                guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { return events }
                let line = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
                buffer = Data(buffer[lineEnd.upperBound...])
                let hex = line.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let size = Int(hex, radix: 16), size >= 0 else { throw HTTPError.badRequest("bad chunk size") }
                state = size == 0 ? .trailers : .chunkData(remaining: size)
            case .chunkData(let remaining):
                guard !buffer.isEmpty else { return events }
                let take = min(remaining, buffer.count)
                events.append(.body(Data(buffer.prefix(take))))
                buffer = Data(buffer.dropFirst(take))
                state = take == remaining ? .chunkDataEnd : .chunkData(remaining: remaining - take)
            case .chunkDataEnd:
                guard buffer.count >= 2 else { return events }
                buffer = Data(buffer.dropFirst(2))
                state = .chunkSize
            case .trailers:
                guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { return events }
                let empty = lineEnd.lowerBound == buffer.startIndex
                buffer = Data(buffer[lineEnd.upperBound...])
                if empty {
                    events.append(.end)
                    state = .head
                }
            }
        }
    }

    static func parseHead(_ data: Data) throws -> HTTPRequestHead {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { throw HTTPError.badRequest("bad request line") }
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let components = URLComponents(string: "http://h" + (target.hasPrefix("/") ? target : "/" + target))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return HTTPRequestHead(method: String(requestLine[0]).uppercased(), path: components?.path ?? target,
                               query: query, headers: headers)
    }
}

/// An HTTP answer.
public struct HTTPResponse: Equatable {
    public var status: Int
    public var contentType: String?
    public var body: Data

    public init(status: Int, contentType: String? = nil, body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    public static func message(_ status: Int, _ text: String) -> HTTPResponse {
        json(status, ["message": text])
    }

    public func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
