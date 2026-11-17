// swift-tools-version:5.9
import PackageDescription

// With Command Line Tools only (no Xcode), the Swift Testing macro plugin is not on the
// default plugin search path, so point the test target at it explicitly.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

let package = Package(
    name: "Frontier",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FrontierCore"),
        .executableTarget(name: "Frontier", dependencies: ["FrontierCore"], exclude: ["Resources"]),
        .testTarget(name: "FrontierCoreTests", dependencies: ["FrontierCore"],
                    swiftSettings: [.unsafeFlags(["-plugin-path", testingPlugins])]),
    ]
)
