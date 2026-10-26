// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "jottie",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "jottie", targets: ["amanu"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "amanu",
            dependencies: [
                "JottieModels", "JottieLibrary", "JottieKnowledge", "JottieUI", "JottieMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                "WhisperFramework",
                "TranscribeCppFramework",
            ],
            // Sparkle is a framework, and `make app` puts it in
            // Contents/Frameworks. SwiftPM builds a bare executable and has no
            // idea a bundle is coming, so the search path it would need at
            // runtime has to be stated here.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .target(name: "JottieModels"),
        .target(name: "JottieLibrary", dependencies: ["JottieModels", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "JottieKnowledge", dependencies: ["JottieModels", "JottieLibrary", .product(name: "MSAL", package: "microsoft-authentication-library-for-objc")]),
        .target(name: "JottieUI", dependencies: ["JottieModels", "JottieLibrary", "JottieKnowledge"]),
        .target(name: "JottieMCP", dependencies: ["JottieModels", "JottieLibrary", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "JottieTests", dependencies: ["JottieModels", "JottieLibrary", "JottieKnowledge", "JottieMCP", "JottieUI"]),
        // Stable v1.9.4 and nightly b5130 are the same signed upstream commit
        // (927cfce), but the stable release was published without artifacts.
        // b5130 is therefore the official universal XCFramework for v1.9.4.
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        ),
        // Handy's native ggml runtime. It supports GigaAM-v3 GGUF models on
        // Metal and CPU without embedding Python, PyTorch or ONNX Runtime.
        .binaryTarget(
            name: "TranscribeCppFramework",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.2.0/TranscribeCpp.xcframework.zip",
            checksum: "5fffd4557d561ab6e45edd2445978682a513c1cd030c5a330c8519c5b27b64d9"
        ),
        .testTarget(
            name: "amanuTests",
            dependencies: ["amanu"]
        ),
    ]
)
