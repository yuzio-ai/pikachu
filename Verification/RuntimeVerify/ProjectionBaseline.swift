import Foundation
import AgentRuntimeCore
import OrchestrationCore

/// Local projection baseline, deliberately separate from native display latency.
/// No history is read or restored and no model or Pi process is started.
@MainActor func measureProjectionBaseline() async throws {
    var samples: [[String: Any]] = []
    for count in [100, 5_000] {
        for round in 1...3 {
            let store = SessionController(), runtime = FakeRuntime()
            await store.connect(runtime)
            let start = ContinuousClock.now
            for i in 0..<count {
                let id = UUID()
                store.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(id)))
                store.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(id, "# Sample \(i)\n\n" + String(repeating: "baseline ", count: 100))))
            }
            let load = start.duration(to: .now)
            let streaming = UUID()
            store.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(streaming)))
            var turns: [Double] = []
            for i in 0..<100 {
                let began = ContinuousClock.now
                store.receive(.init(instanceID: runtime.instanceID, event: .textDelta(streaming, 0, "delta ")))
                store.draft = "typing \(i)"
                await Task.yield()
                turns.append(milliseconds(began.duration(to: .now)))
            }
            turns.sort()
            samples.append(["rows": count, "round": round, "projectionMilliseconds": milliseconds(load),
                            "streamAndDraftTurnP95Milliseconds": turns[94], "maxMilliseconds": turns.last!])
            _ = await store.disconnect()
        }
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let output = root.appendingPathComponent(".verification-runs/runtime-verify/baseline")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    #if DEBUG
    let configuration = "Xcode debug"
    #else
    let configuration = "Xcode release"
    #endif
    let report: [String: Any] = ["configuration": configuration, "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "processorCount": ProcessInfo.processInfo.processorCount, "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
        "method": "Direct domain event projection; 900-character completed rows; 100 delta/draft turns with Task.yield; three fresh stores per size. Excludes RPC, SwiftUI rendering, OS input and network.",
        "samples": samples]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output.appendingPathComponent("projection.json"))
    print(String(decoding: data, as: UTF8.self))
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}
