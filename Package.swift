// swift-tools-version:5.10
// Swift 5 language mode (the default for tools-version 5.10), built with the Swift 6 toolchain.
import PackageDescription

let package = Package(
    name: "Wickbar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Wickbar", targets: ["Wickbar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Pure logic: config model, output buffer / ANSI stripping, JSON, MCP dispatch, HTTP parsing.
        // No AppKit / SwiftUI so it is unit-testable.
        .target(
            name: "WickbarCore",
            path: "Sources/WickbarCore"
        ),
        .executableTarget(
            name: "Wickbar",
            dependencies: [
                "WickbarCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Wickbar"
        ),
        .testTarget(
            name: "WickbarTests",
            dependencies: ["WickbarCore"],
            path: "Tests/WickbarTests"
        ),
    ]
)
