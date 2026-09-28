import Foundation

enum JSSource {
    static func stringLiteral(_ raw: String) -> String {
        let encoded: String
        if let data = try? JSONSerialization.data(withJSONObject: [raw]),
           let str = String(data: data, encoding: .utf8) {
            encoded = String(str.dropFirst().dropLast())
        } else {
            Trace.warn(.bridge, "JSSource.stringLiteral fallback — lossy escape")
            encoded = #""""#
        }
        return escapeLineTerminators(encoded)
    }

    static func escapeLineTerminators(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
