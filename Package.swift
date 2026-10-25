// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalPrompt",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "LocalPrompt", targets: ["LocalPrompt"])],
    targets: [
        .target(name: "PromptCore"),
        .executableTarget(name: "LocalPrompt", dependencies: ["PromptCore"]),
        .testTarget(name: "PromptCoreTests", dependencies: ["PromptCore"])
    ],
    swiftLanguageModes: [.v5]
)
