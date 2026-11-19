// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pikachu", platforms: [.macOS("27.0")],
    products: [.executable(name: "Pikachu", targets: ["Pikachu"]),
               .executable(name: "pikachu-supervisor", targets: ["PikachuSupervisor"]),
               .executable(name: "pi-compat-probe", targets: ["PiCompatProbe"]),
               .executable(name: "runtime-verify", targets: ["RuntimeVerify"]),
               .executable(name: "workspace-verify", targets: ["WorkspaceVerify"]),
               .executable(name: "interaction-verify", targets: ["InteractionVerify"])],
    targets: [
        .target(name: "CProcessInspection", path: "Modules/CProcessInspection"),
        .target(name: "ProcessSupervision", dependencies: ["CProcessInspection"], path: "Modules/ProcessSupervision"),
        .executableTarget(name: "PikachuSupervisor", dependencies: ["ProcessSupervision", "CProcessInspection"], path: "PikachuSupervisor"),
        .target(name: "AgentRuntimeCore", path: "Modules/AgentRuntimeCore"),
        .target(name: "PiRuntimeAdapter", dependencies: ["AgentRuntimeCore", "ProcessSupervision"], path: "Modules/PiRuntimeAdapter", resources: [.copy("Resources")]),
        .target(name: "OrchestrationCore", dependencies: ["AgentRuntimeCore"], path: "Modules/OrchestrationCore"),
        .target(name: "WorkspacePersistence", dependencies: ["OrchestrationCore"], path: "Modules/WorkspacePersistence"),
        .executableTarget(name: "Pikachu", dependencies: ["AgentRuntimeCore", "PiRuntimeAdapter", "OrchestrationCore", "WorkspacePersistence", "ProcessSupervision"], path: "Pikachu", exclude: ["Resources"]),
        .executableTarget(name: "PiCompatProbe", dependencies: ["ProcessSupervision"], path: "Verification/PiCompatProbe"),
        .executableTarget(name: "RuntimeVerify", dependencies: ["AgentRuntimeCore", "PiRuntimeAdapter", "OrchestrationCore"], path: "Verification/RuntimeVerify"),
        .executableTarget(name: "WorkspaceVerify", dependencies: ["AgentRuntimeCore", "PiRuntimeAdapter", "OrchestrationCore", "WorkspacePersistence"], path: "Verification/WorkspaceVerify"),
        .executableTarget(name: "InteractionVerify", dependencies: ["AgentRuntimeCore", "PiRuntimeAdapter", "OrchestrationCore", "WorkspacePersistence", "ProcessSupervision"], path: "Verification/InteractionVerify"),
        .testTarget(name: "PikachuTests", dependencies: ["AgentRuntimeCore", "OrchestrationCore", "PiRuntimeAdapter", "WorkspacePersistence", "Pikachu"], path: "Tests/PikachuTests"),
        .testTarget(name: "ProcessSupervisionTests", dependencies: ["ProcessSupervision"], path: "Tests/ProcessSupervisionTests")
    ]
)
