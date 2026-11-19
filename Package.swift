// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pikachu", platforms: [.macOS("27.0")],
    products: [.executable(name: "Pikachu", targets: ["PikachuApp"]),
               .executable(name: "m0-supervisor", targets: ["M0Supervisor"]),
               .executable(name: "m1-verify", targets: ["M1Verify"]),
               .executable(name: "m2-verify", targets: ["M2Verify"]),
               .executable(name: "m3-verify", targets: ["M3Verify"])],
    targets: [
        // The validated process implementation is shared by source, not copied.
        .target(name: "CM0Process", path: "Tools/M0Validation/Sources/CM0Process"),
        .target(name: "M0Support", dependencies: ["CM0Process"], path: "Tools/M0Validation/Sources/M0Support"),
        .executableTarget(name: "M0Supervisor", dependencies: ["M0Support", "CM0Process"], path: "Tools/M0Validation/Sources/M0Supervisor"),
        .target(name: "AgentRuntimeCore", path: "Packages/AgentRuntimeCore"),
        .target(name: "PiRuntimeAdapter", dependencies: ["AgentRuntimeCore", "M0Support"], path: "Packages/PiRuntimeAdapter", resources: [.copy("Resources")]),
        .target(name: "OrchestrationCore", dependencies: ["AgentRuntimeCore"], path: "Packages/OrchestrationCore"),
        .target(name: "WorkspacePersistence", dependencies: ["OrchestrationCore"], path: "Packages/WorkspacePersistence"),
        .executableTarget(name: "PikachuApp", dependencies: ["AgentRuntimeCore", "PiRuntimeAdapter", "OrchestrationCore", "WorkspacePersistence", "M0Support"], path: "PikachuApp", exclude: ["ProviderLogos"]),
        .executableTarget(name: "M1Verify", dependencies: ["AgentRuntimeCore", "PiRuntimeAdapter", "OrchestrationCore"], path: "Tools/M1Verification", exclude: ["Fixtures"]),
        .executableTarget(name: "M2Verify", dependencies: ["AgentRuntimeCore", "PiRuntimeAdapter", "OrchestrationCore", "WorkspacePersistence"], path: "Tools/M2Verification", exclude: ["Fixtures"]),
        .executableTarget(name: "M3Verify", dependencies: ["AgentRuntimeCore", "PiRuntimeAdapter", "OrchestrationCore", "WorkspacePersistence", "M0Support"], path: "Tools/M3Verification", exclude: ["Fixtures"]),
        .testTarget(name: "PikachuCoreTests", dependencies: ["AgentRuntimeCore", "OrchestrationCore", "PiRuntimeAdapter", "WorkspacePersistence", "PikachuApp"], path: "Tests/PikachuCoreTests")
    ]
)
