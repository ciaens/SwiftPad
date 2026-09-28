import Foundation

public protocol HTTPClient: Sendable {
    func get(url: URL) async throws -> HTTPResponse
    func get(url: URL, headers: [String: String]) async throws -> HTTPResponse
    func getStream(url: URL, maxBytes: Int?) async throws -> HTTPStream
    func postJSON(url: URL, body: Data, maxResponseBytes: Int?) async throws -> HTTPResponse
}

extension HTTPClient {
    public func get(url: URL, headers: [String: String]) async throws -> HTTPResponse {
        if !headers.isEmpty {
            Trace.warn(.transport, "HTTPClient default get(url:headers:) dropping headers [\(headers.keys.sorted().joined(separator: ","))] — conforming impl must override")
        }
        return try await get(url: url)
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public struct HTTPStream: Sendable {
    public let status: Int
    public let bytes: AsyncThrowingStream<Data, Error>

    public init(status: Int, bytes: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.bytes = bytes
    }
}

public enum HTTPError: Error, Equatable, Sendable {
    case bodyTooLarge(limit: Int)
}

#if canImport(Darwin)
public struct URLSessionHTTPClient: HTTPClient {
    let maxBodyBytes: Int

    public init(maxBodyBytes: Int = 52_428_800) {
        self.maxBodyBytes = maxBodyBytes
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config,
                          delegate: RedirectRefusingDelegate(),
                          delegateQueue: nil)
    }()

    public func get(url: URL) async throws -> HTTPResponse {
        return try await get(url: url, headers: [:])
    }

    public func get(url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (asyncBytes, response) = try await Self.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        var data = Data()
        data.reserveCapacity(min(4096, maxBodyBytes))
        for try await byte in asyncBytes {
            if data.count >= maxBodyBytes {
                throw HTTPError.bodyTooLarge(limit: maxBodyBytes)
            }
            data.append(byte)
        }
        return HTTPResponse(status: status, body: data)
    }

    public func postJSON(url: URL, body: Data, maxResponseBytes: Int?) async throws -> HTTPResponse {
        let cap = maxResponseBytes ?? maxBodyBytes
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (asyncBytes, response) = try await Self.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        var data = Data()
        data.reserveCapacity(min(4096, cap))
        for try await byte in asyncBytes {
            if data.count >= cap {
                throw HTTPError.bodyTooLarge(limit: cap)
            }
            data.append(byte)
        }
        return HTTPResponse(status: status, body: data)
    }

    public func getStream(url: URL, maxBytes: Int?) async throws -> HTTPStream {
        let cap = maxBytes ?? maxBodyBytes
        let chunkBytes = 64 * 1024
        let (asyncBytes, response) = try await Self.session.bytes(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let puller = HTTPByteChunkPuller(asyncBytes, cap: cap)
        let stream = AsyncThrowingStream<Data, Error>(unfolding: {
            try await puller.nextChunk(chunkBytes: chunkBytes)
        })
        return HTTPStream(status: status, bytes: stream)
    }
}

private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class HTTPByteChunkPuller: @unchecked Sendable {
    private var iterator: URLSession.AsyncBytes.AsyncIterator
    private let transportTask: URLSessionDataTask
    private let cap: Int
    private var total = 0
    private var finished = false

    init(_ bytes: URLSession.AsyncBytes, cap: Int) {
        self.iterator = bytes.makeAsyncIterator()
        self.transportTask = bytes.task
        self.cap = cap
    }

    deinit { transportTask.cancel() }

    func nextChunk(chunkBytes: Int) async throws -> Data? {
        if finished { return nil }
        var chunk = Data()
        chunk.reserveCapacity(chunkBytes)
        while chunk.count < chunkBytes {
            guard let byte = try await iterator.next() else {
                finished = true
                return chunk.isEmpty ? nil : chunk
            }
            if total >= cap {
                finished = true
                throw HTTPError.bodyTooLarge(limit: cap)
            }
            chunk.append(byte)
            total += 1
        }
        return chunk
    }
}
#endif
