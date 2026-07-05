// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Attache",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Attache", targets: ["AttacheApp"]),
        .library(name: "AttacheCore", targets: ["AttacheCore"])
    ],
    targets: [
        .target(
            name: "AttacheCore",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AttacheApp",
            dependencies: ["AttacheCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "AttacheUISmoke",
            dependencies: []
        ),
        .testTarget(
            name: "AttacheCoreTests",
            dependencies: ["AttacheCore"]
        ),
        .testTarget(
            name: "AttacheAppTests",
            dependencies: ["AttacheApp"]
        )
    ]
)
