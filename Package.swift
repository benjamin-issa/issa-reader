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
        .library(name: "IssaAsk", targets: ["IssaAsk"]),
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
        .target(
            // The on-device question pipeline: it parses chapters with the
            // renderer's own parser so the index's offsets are the reader's,
            // reads them straight out of the EPUB, and keeps its per-book
            // full-text index in SQLite. Not linked on tvOS, where
            // FoundationModels does not exist.
            name: "IssaAsk",
            dependencies: [
                "IssaCore",
                "IssaEPUB",
                "IssaRender",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/IssaAsk/Sources/IssaAsk",
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
        .testTarget(
            // IssaEPUB and IssaRender directly, because the offset tests parse
            // the fixture a second time exactly as the reader would and compare
            // — an assertion that is only worth anything if it is written
            // against the real parser rather than the index's memory of it.
            // GRDB directly for the same reason: the offset tests read the rows
            // the store actually wrote, rather than trusting an accessor the
            // store could have got wrong in the same way twice.
            name: "IssaAskTests",
            dependencies: [
                "IssaAsk",
                "IssaEPUB",
                "IssaRender",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/IssaAsk/Tests",
            resources: [.copy("Fixtures")],
        ),
    ],
)
