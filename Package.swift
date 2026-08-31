// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "connect-swift-server",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ConnectServer", targets: ["ConnectServer"]),
        // Public CLI used by `protoc` and `buf generate` to emit Connect-server bindings.
        .executable(name: "protoc-gen-connect-swift-server", targets: ["protoc-gen-connect-swift-server"]),
        // Self-testing example server. Run `swift run smoke-test` for an interactive
        // server with copy-paste-ready curl examples, or `swift run smoke-test --self-test`
        // for a single-shot pass/fail check that hits the server via URLSession.
        .executable(name: "smoke-test", targets: ["SmokeTest"]),
    ],
    traits: [
        // When enabled (the default), ConnectRouter / CORSConfiguration / ConnectServer gain
        // `init(reader:)` overloads that read configuration from a `Configuration.ConfigReader`.
        // Disable to drop the swift-configuration dependency.
        .trait(name: "ConfigurationSupport", description: "Enable support for swift-configuration."),
        .default(enabledTraits: ["ConfigurationSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.96.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.2", traits: []),
    ],
    targets: [
        .target(
            name: "ConnectServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "HummingbirdHTTP2", package: "hummingbird"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "Instrumentation", package: "swift-distributed-tracing"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Configuration", package: "swift-configuration",
                         condition: .when(traits: ["ConfigurationSupport"])),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ConnectServerGenerator",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftProtobufPluginLibrary", package: "swift-protobuf"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "protoc-gen-connect-swift-server",
            dependencies: [
                "ConnectServerGenerator"
            ],
            path: "Sources/protoc-gen-connect-swift-server",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "SmokeTest",
            dependencies: [
                "ConnectServer",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Examples/SmokeTest",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ConnectServerGeneratorTests",
            dependencies: [
                "ConnectServerGenerator",
                .product(name: "SwiftProtobufPluginLibrary", package: "swift-protobuf"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ConnectServerTests",
            dependencies: [
                "ConnectServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
