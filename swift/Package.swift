// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AlocirCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AlocirCore", targets: ["AlocirCore"]),
        .executable(name: "alocir-scan", targets: ["alocir-scan"]),
    ],
    targets: [
        .target(name: "AlocirCore"),
        .executableTarget(name: "alocir-scan", dependencies: ["AlocirCore"]),
        .testTarget(name: "AlocirCoreTests", dependencies: ["AlocirCore"]),
    ],
    swiftLanguageModes: [.v6]
)
