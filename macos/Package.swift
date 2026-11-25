// swift-tools-version:5.9
import PackageDescription

// MunaCore: what has no screen (data files, LocalSend, groups); it builds and is tested on Linux too.
// Muna: the app (AppKit + SwiftUI), only on macOS.
var targets: [Target] = [
    .target(name: "MunaCore"),
    .testTarget(name: "MunaCoreTests", dependencies: ["MunaCore"]),
]
var products: [Product] = [.library(name: "MunaCore", targets: ["MunaCore"])]
#if os(macOS)
targets.append(.executableTarget(name: "Muna", dependencies: ["MunaCore"]))
products.append(.executable(name: "Muna", targets: ["Muna"]))
#endif

let package = Package(
    name: "Muna",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
