import Foundation

public struct JSResourceProvider: Sendable {
    public let load: @Sendable (_ fileName: String) throws -> Data

    public init(load: @escaping @Sendable (_ fileName: String) throws -> Data) {
        self.load = load
    }

    public static func directory(_ directory: URL) -> JSResourceProvider {
        JSResourceProvider { fileName in
            let leaf = (fileName as NSString).lastPathComponent
            return try Data(contentsOf: directory.appendingPathComponent(leaf))
        }
    }

    #if canImport(Darwin)
    public static let bundle = JSResourceProvider { fileName in
        let ext = (fileName as NSString).pathExtension
        let name = (fileName as NSString).deletingPathExtension
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw BundleMiss(fileName: fileName)
        }
        return try Data(contentsOf: url)
    }
    #endif
}

private struct BundleMiss: Error { let fileName: String }
