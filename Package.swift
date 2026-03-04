// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "obo-gen",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "obo-gen",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources"
        )
    ]
)
