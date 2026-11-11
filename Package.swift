// swift-tools-version: 5.10
import PackageDescription

// This package compiles the app's real protocol implementation. It has no
// simulator, WebKit, UIKit, fixture application or copied-source dependency.
let package = Package(
    name: "AnimeSyncCoreProtocols",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AnimeSyncCore", targets: ["AnimeSync"])],
    targets: [
        .target(
            name: "AnimeSync",
            path: "AnimeSync/Core",
            exclude: ["QAFixture.swift", "TVDiscovery.swift"],
            sources: [
                "AppConfiguration.swift", "AppWebPolicy.swift", "CoreHTTP.swift", "CoreSecrets.swift", "HomeHistory.swift",
                "ProtocolModels.swift", "SyncService.swift", "TVClient.swift"
            ]
        ),
        .testTarget(
            name: "CoreProtocolTests",
            dependencies: ["AnimeSync"],
            path: "Tests",
            exclude: ["AppModelTests.swift", "NativePlaybackTests.swift", "NetworkRoutingTests.swift", "ProviderTests.swift", "QAAcceptanceTests.swift"],
            sources: ["ProtocolTests.swift", "AppConfigurationTests.swift"],
            swiftSettings: [.define("CORE_PROTOCOLS_ONLY")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
