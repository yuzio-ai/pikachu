import Foundation
import AgentRuntimeCore
import OrchestrationCore

if CommandLine.arguments.contains("--baseline") {
    try await measureProjectionBaseline()
} else {
    let controller = SessionController()
    let runtime = FakeRuntime()
    await controller.connect(runtime)
    guard controller.connection == .connected else { throw RuntimeFailure(.connection, "Fake runtime failed to connect") }
    guard await controller.disconnect() else { throw RuntimeFailure(.connection, "Fake runtime failed to disconnect") }
    print("Runtime connection and cleanup passed.")
}
