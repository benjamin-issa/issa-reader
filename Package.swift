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
            // IssaUI owns the reading themes and type ramp; the renderer applies them.
            dependencies: ["IssaCore", "IssaEPUB", "IssaUI"],
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
            resources: [.process("Resources")],
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
            // IssaUI for the bundled-face catalogue: the faces it advertises
            // and the trait resolution IssaRender does have to agree, and that
            // agreement is only testable where both are in scope.
            dependencies: ["IssaRender", "IssaEPUB", "IssaUI"],
            path: "Packages/IssaRender/Tests",
            resources: [.copy("Fixtures")],
        ),
        .testTarget(
            name: "IssaPlaybackTests",
            dependencies: ["IssaPlayback", "IssaEPUB"],
            path: "Packages/IssaPlayback/Tests",
            resources: [.copy("Fixtures")],
        ),
        .testTarget(
            name: "IssaUITests",
            dependencies: ["IssaUI"],
            path: "Packages/IssaUI/Tests",
        ),
    ],
)
