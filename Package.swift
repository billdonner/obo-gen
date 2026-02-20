// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "obo-gen",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "obo-gen",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            path: "Sources"
        )
    ]
)
