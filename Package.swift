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
        .testTarget(name: "RcloneRCTests", dependencies: ["RcloneRC"]),
        .testTarget(name: "GrrCloneCoreTests", dependencies: ["GrrCloneCore"]),
    ]
)
