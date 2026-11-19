// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "M0Validation",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "m0-verify", targets: ["M0Verify"]),
               .executable(name: "m0-supervisor", targets: ["M0Supervisor"])],
    targets: [
        .target(name: "CM0Process"),
        .target(name: "M0Support", dependencies: ["CM0Process"]),
        .executableTarget(name: "M0Supervisor", dependencies: ["M0Support", "CM0Process"]),
        .executableTarget(name: "M0Verify", dependencies: ["M0Support"]),
        .testTarget(name: "M0SupportTests", dependencies: ["M0Support"])
    ]
)
