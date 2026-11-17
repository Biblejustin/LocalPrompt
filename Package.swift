// swift-tools-version: 6.2
import Foundation
import PackageDescription

let slidesHostInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/LocalPromptSlidesHost/Info.plist").path

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
        .executableTarget(
            name: "LocalPromptSlidesHost",
            dependencies: ["SlidesBridgeKit"],
            exclude: ["Info.plist"],
            // A sandboxed helper needs its own bundle identifier. Browsers start
            // it directly, so it has no bundle; embed the plist in the binary.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker", slidesHostInfoPlist])]
        ),
        .testTarget(name: "PromptCoreTests", dependencies: ["PromptCore"]),
        .testTarget(name: "SlidesBridgeKitTests", dependencies: ["SlidesBridgeKit"])
    ],
    swiftLanguageModes: [.v5]
)
