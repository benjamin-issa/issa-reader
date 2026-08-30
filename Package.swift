// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IssaReader",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        .library(name: "IssaCore", targets: ["IssaCore"]),
        .library(name: "IssaEPUB", targets: ["IssaEPUB"]),
        .library(name: "IssaRender", targets: ["IssaRender"]),
        .library(name: "IssaPlayback", targets: ["IssaPlayback"]),
        .library(name: "IssaUI", targets: ["IssaUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "IssaCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Packages/IssaCore/Sources/IssaCore",
        ),
        .target(
            name: "IssaEPUB",
            dependencies: ["IssaCore"],
            path: "Packages/IssaEPUB/Sources/IssaEPUB",
        ),
        .target(
            name: "IssaRender",
            dependencies: ["IssaCore", "IssaEPUB"],
            path: "Packages/IssaRender/Sources/IssaRender",
        ),
        .target(
            name: "IssaPlayback",
            dependencies: ["IssaCore", "IssaEPUB"],
            path: "Packages/IssaPlayback/Sources/IssaPlayback",
        ),
        .target(
            name: "IssaUI",
            dependencies: ["IssaCore"],
            path: "Packages/IssaUI/Sources/IssaUI",
        ),
        .testTarget(
            name: "IssaCoreTests",
            dependencies: ["IssaCore"],
            path: "Packages/IssaCore/Tests",
            resources: [.copy("Fixtures")],
        ),
        .testTarget(
            name: "IssaEPUBTests",
            dependencies: ["IssaEPUB"],
            path: "Packages/IssaEPUB/Tests",
            resources: [.copy("Fixtures")],
        ),
        .testTarget(
            name: "IssaRenderTests",
            dependencies: ["IssaRender"],
            path: "Packages/IssaRender/Tests",
        ),
        .testTarget(
            name: "IssaPlaybackTests",
            dependencies: ["IssaPlayback"],
            path: "Packages/IssaPlayback/Tests",
        ),
    ],
)
