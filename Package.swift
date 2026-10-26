// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalPrompt",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "LocalPrompt", targets: ["LocalPrompt"]),
        .executable(name: "LocalPromptSlidesHost", targets: ["LocalPromptSlidesHost"])
    ],
    targets: [
        .target(name: "PromptCore"),
        .target(name: "SlidesBridgeKit"),
        .executableTarget(name: "LocalPrompt", dependencies: ["PromptCore", "SlidesBridgeKit"]),
        .executableTarget(name: "LocalPromptSlidesHost", dependencies: ["SlidesBridgeKit"]),
        .testTarget(name: "PromptCoreTests", dependencies: ["PromptCore"]),
        .testTarget(name: "SlidesBridgeKitTests", dependencies: ["SlidesBridgeKit"])
    ],
    swiftLanguageModes: [.v5]
)
