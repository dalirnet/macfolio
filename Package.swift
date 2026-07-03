// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Macfolio",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Macfolio",
            targets: ["Macfolio"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Macfolio",
            path: "Sources"
        )
    ]
)
