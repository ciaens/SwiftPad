import NIOSSL

enum NIOTLS {
    static func clientConfiguration(additionalTrustRootPEMFiles paths: [String]) throws -> TLSConfiguration {
        guard !paths.isEmpty else {
            throw NIOTransportError(description: "additionalTrustRootPEMFiles is empty")
        }
        var certificates: [NIOSSLCertificate] = []
        for path in paths {
            certificates.append(contentsOf: try NIOSSLCertificate.fromPEMFile(path))
        }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.additionalTrustRoots = [.certificates(certificates)]
        return configuration
    }
}
