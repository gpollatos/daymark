// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Daymark",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Daymark", path: "Sources/Daymark"),
        .testTarget(name: "DaymarkTests", dependencies: ["Daymark"], path: "Tests/DaymarkTests"),
    ]
)
