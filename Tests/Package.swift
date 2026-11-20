// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AgenticBenchmarksTests",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "t_agentic_bench",
            targets: ["AgenticBenchmarksCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Agentic.git", branch: "master"),
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "AgenticBenchmarksCLI",
            dependencies: [
                .product(name: "AgenticBenchmarks", package: "AgenticBenchmarks"),
                .product(name: "Agentic", package: "Agentic"),
                .product(name: "AgenticContextWindow", package: "Agentic"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets {
    switch target.type {
    case .regular, .executable, .test, .macro:
        var settings = target.swiftSettings ?? []

        settings.append(
            .treatAllWarnings(as: .error)
        )

        settings.append(
            .unsafeFlags(
                [
                    "-continue-building-after-errors"
                ]
            )
        )

        target.swiftSettings = settings

    case .plugin, .system, .binary:
        break

    @unknown default:
        break
    }
}
