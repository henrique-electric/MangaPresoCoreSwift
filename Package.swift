// swift-tools-version: 6.0
// Declares the library product and offline test target for SwiftPM and Xcode.
import PackageDescription

let package = Package(
    name: "MangaPreso",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "MangaPresoCore", targets: ["MangaPresoCore"]),
    ],
    targets: [
        .target(name: "MangaPresoCore"),
        .testTarget(name: "MangaPresoCoreTests", dependencies: ["MangaPresoCore"]),
    ]
)
