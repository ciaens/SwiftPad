import Foundation

enum CryptPadAPI {
    static func fetchConfig(serverURL: URL, client: HTTPClient) async throws -> [String: Any] {
        try await fetchAMDJSON(url: serverURL.appendingPathComponent("api/config"), client: client)
    }

    static func fetchBroadcast(serverURL: URL, client: HTTPClient) async throws -> [String: Any] {
        try await fetchAMDJSON(url: serverURL.appendingPathComponent("api/broadcast"), client: client)
    }

    private static func fetchAMDJSON(url: URL, client: HTTPClient) async throws -> [String: Any] {
        let resp: HTTPResponse
        do {
            resp = try await client.get(url: url)
        } catch let error as HTTPError {
            switch error {
            case .bodyTooLarge(let limit):
                throw SwiftPadError.protocolError("AMD body exceeded \(limit) byte cap at \(url.absoluteString)")
            }
        } catch let error as SwiftPadError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SwiftPadError.serverUnreachable("\(url.absoluteString) (\(type(of: error)))")
        }
        guard resp.status == 200 else {
            throw SwiftPadError.serverUnreachable(url.absoluteString)
        }
        guard let body = String(data: resp.body, encoding: .utf8) else {
            throw SwiftPadError.protocolError("non-UTF8 body from \(url.absoluteString)")
        }
        guard let returnKeyword = body.range(of: #"\breturn\b"#, options: .regularExpression),
              let suffix = body.range(of: "});", options: .backwards)
        else {
            throw SwiftPadError.protocolError("unexpected AMD shape at \(url.absoluteString)")
        }
        var jsonText = String(body[returnKeyword.upperBound..<suffix.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasSuffix(";") { jsonText.removeLast() }
        guard let jsonData = jsonText.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            throw SwiftPadError.protocolError("invalid JSON at \(url.absoluteString)")
        }
        return object
    }
}
