// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "grrclone",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RcloneRC", targets: ["RcloneRC"]),
        .library(name: "GrrCloneCore", targets: ["GrrCloneCore"]),
        .executable(name: "grrclonectl", targets: ["grrclonectl"]),
    ],
    targets: [
        .target(name: "RcloneRC"),
        .target(name: "GrrCloneCore", dependencies: ["RcloneRC"]),
        .executableTarget(name: "grrclonectl", dependencies: ["GrrCloneCore", "RcloneRC"]),
        .testTarget(name: "RcloneRCTests", dependencies: ["RcloneRC"],
                    // Real config/providers output, captured from rclone rather than
                    // written by hand — the schema is too large and too changeable to
                    // invent, and an invented fixture only proves the code agrees with
                    // the invention.
                    resources: [.copy("Fixtures/providers.json")]),
        .testTarget(name: "GrrCloneCoreTests", dependencies: ["GrrCloneCore"]),
    ]
)
