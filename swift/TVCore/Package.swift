// swift-tools-version:5.9
import PackageDescription

// The parts of tvview that are not UI: the config model, loading, and the
// rules around it. Kept free of SwiftUI/WebKit so `swift test` runs them
// without an app or a simulator. Mirrors config.go.
let package = Package(
    name: "TVCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "TVCore", targets: ["TVCore"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")],
    targets: [
        .target(name: "TVCore", dependencies: ["Yams"]),
        .testTarget(name: "TVCoreTests", dependencies: ["TVCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
