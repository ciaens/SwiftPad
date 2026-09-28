// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SwiftPadCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SwiftPadCore", targets: ["SwiftPadCore"]),
        .library(name: "SwiftPadNIOTransport", targets: ["SwiftPadNIOTransport"]),
        .executable(name: "swiftpad-cli", targets: ["swiftpad-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.36.1"),
        .package(url: "https://github.com/vapor/websocket-kit.git", exact: "2.16.2"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.4"),
    ],
    targets: [
        .target(
            name: "CQuickJS",
            path: "Sources/CQuickJS",
            sources: [
                "upstream/quickjs.c",
                "upstream/libregexp.c",
                "upstream/libunicode.c",
                "upstream/dtoa.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("upstream"),
                .define("_GNU_SOURCE"),
                .define("QUICKJS_NG_BUILD"),
                .unsafeFlags([
                    "-Wno-implicit-fallthrough",
                    "-Wno-sign-compare",
                    "-Wno-unused-parameter",
                    "-Wno-unused-but-set-variable",
                ]),
            ]
        ),
        .target(
            name: "SwiftPadCore",
            dependencies: [
                "CQuickJS",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/SwiftPadCore",
            resources: [
                .copy("Resources/worker.bundle.min.js"),
                .copy("Resources/bootstrap.js"),
                .copy("Resources/application_config.js"),
                .copy("Resources/nacl-fast.min.js"),
                .copy("Resources/scrypt-async.min.js"),
            ]
        ),
        .target(
            name: "SwiftPadNIOTransport",
            dependencies: [
                "SwiftPadCore",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/SwiftPadNIOTransport"
        ),
        .executableTarget(
            name: "swiftpad-cli",
            dependencies: ["SwiftPadCore"],
            path: "Sources/swiftpad-cli"
        ),
    ]
)
