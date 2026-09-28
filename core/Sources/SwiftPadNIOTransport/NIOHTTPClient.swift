import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import AsyncHTTPClient
import SwiftPadCore

public struct NIOHTTPClient: SwiftPadCore.HTTPClient {
    let maxBodyBytes: Int
    let client: AsyncHTTPClient.HTTPClient

    public init(maxBodyBytes: Int = 52_428_800) {
        self.maxBodyBytes = maxBodyBytes
        self.client = Self.defaultClient
    }

    public init(maxBodyBytes: Int = 52_428_800, additionalTrustRootPEMFiles: [String]) throws {
        self.maxBodyBytes = maxBodyBytes
        let tls = try NIOTLS.clientConfiguration(additionalTrustRootPEMFiles: additionalTrustRootPEMFiles)
        self.client = AsyncHTTPClient.HTTPClient(eventLoopGroup: NIOTransportGroup.shared,
                                                 configuration: Self.makeConfiguration(tls: tls))
    }

    static let defaultClient = AsyncHTTPClient.HTTPClient(eventLoopGroup: NIOTransportGroup.shared,
                                                          configuration: makeConfiguration(tls: nil))

    static func makeConfiguration(tls: TLSConfiguration?) -> AsyncHTTPClient.HTTPClient.Configuration {
        var config = AsyncHTTPClient.HTTPClient.Configuration(
            redirectConfiguration: .disallow,
            timeout: .init(connect: .seconds(30), read: .seconds(60)),
            decompression: .enabled(limit: .ratio(50))
        )
        config.tlsConfiguration = tls
        config.connectionPool.retryConnectionEstablishment = false
        return config
    }

    public func get(url: URL) async throws -> HTTPResponse {
        try await get(url: url, headers: [:])
    }

    public func get(url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = HTTPClientRequest(url: url.absoluteString)
        for (name, value) in headers { request.headers.add(name: name, value: value) }
        let response = try await execute(request)
        return HTTPResponse(status: Int(response.status.code),
                            body: try await Self.collect(response.body, cap: maxBodyBytes))
    }

    public func postJSON(url: URL, body: Data, maxResponseBytes: Int?) async throws -> HTTPResponse {
        let cap = maxResponseBytes ?? maxBodyBytes
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(body)
        let response = try await execute(request)
        return HTTPResponse(status: Int(response.status.code),
                            body: try await Self.collect(response.body, cap: cap))
    }

    public func getStream(url: URL, maxBytes: Int?) async throws -> HTTPStream {
        let cap = maxBytes ?? maxBodyBytes
        let chunkBytes = 64 * 1024
        let request = HTTPClientRequest(url: url.absoluteString)
        let response = try await execute(request)
        let puller = NIOByteChunkPuller(response.body, cap: cap)
        let stream = AsyncThrowingStream<Data, Error>(unfolding: {
            try await puller.nextChunk(chunkBytes: chunkBytes)
        })
        return HTTPStream(status: Int(response.status.code), bytes: stream)
    }

    func execute(_ request: HTTPClientRequest) async throws -> HTTPClientResponse {
        do {
            return try await client.execute(request, deadline: .distantFuture)
        } catch {
            throw NIOTransportError.bounded(error)
        }
    }

    static func collect(_ body: HTTPClientResponse.Body, cap: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(4096, cap))
        for try await buffer in body {
            if data.count + buffer.readableBytes > cap {
                throw HTTPError.bodyTooLarge(limit: cap)
            }
            data.append(contentsOf: buffer.readableBytesView)
        }
        return data
    }
}

public struct NIOTransportError: Error, LocalizedError, CustomStringConvertible {
    public let description: String
    public var errorDescription: String? { description }

    static func bounded(_ error: Error) -> NIOTransportError {
        if let ahc = error as? HTTPClientError {
            return NIOTransportError(description: ahc.shortDescription)
        }
        return NIOTransportError(description: String(describing: type(of: error)))
    }
}

private final class NIOByteChunkPuller: @unchecked Sendable {
    private var iterator: HTTPClientResponse.Body.AsyncIterator
    private var pending = ByteBuffer()
    private let cap: Int
    private var total = 0
    private var finished = false

    init(_ body: HTTPClientResponse.Body, cap: Int) {
        self.iterator = body.makeAsyncIterator()
        self.cap = cap
    }

    func nextChunk(chunkBytes: Int) async throws -> Data? {
        if finished { return nil }
        var chunk = Data()
        chunk.reserveCapacity(chunkBytes)
        while chunk.count < chunkBytes {
            if pending.readableBytes == 0 {
                do {
                    guard let next = try await iterator.next() else {
                        finished = true
                        return chunk.isEmpty ? nil : chunk
                    }
                    pending = next
                } catch {
                    finished = true
                    throw NIOTransportError.bounded(error)
                }
            }
            let take = min(chunkBytes - chunk.count, pending.readableBytes)
            if total + take > cap {
                finished = true
                throw HTTPError.bodyTooLarge(limit: cap)
            }
            chunk.append(contentsOf: pending.readableBytesView.prefix(take))
            pending.moveReaderIndex(forwardBy: take)
            total += take
        }
        return chunk
    }
}
