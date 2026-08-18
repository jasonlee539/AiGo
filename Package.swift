// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AiGo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AiGo", targets: ["AiGo"]),
        .executable(name: "AiGoSelfTests", targets: ["AiGoSelfTests"])
    ],
    targets: [
        .target(
            name: "AiGoKit",
            path: "Sources/AiGo",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "AiGo",
            dependencies: ["AiGoKit"],
            path: "Sources/AiGoApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "AiGoSelfTests",
            dependencies: ["AiGoKit"],
            path: "Sources/AiGoSelfTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
