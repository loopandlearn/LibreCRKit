// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LibreCRKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LibreCRKit", targets: ["LibreCRKit"]),
    ],
    targets: [
        .target(
            name: "LibreCRKit",
            path: "Sources/LibreCRKit",
            resources: [
                .copy("Resources/RuntimeTables"),
            ]
        ),
        .testTarget(
            name: "LibreCRKitTests",
            dependencies: ["LibreCRKit"],
            path: "Tests/LibreCRKitTests"
        ),
    ]
)
