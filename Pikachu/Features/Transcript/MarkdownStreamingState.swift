import Observation
import OrchestrationCore

struct MarkdownInput: Equatable, Sendable {
    let text: String
    let streaming: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.streaming == rhs.streaming && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}

@MainActor @Observable final class MarkdownStreamingState {
    struct Snapshot: Sendable {
        let source: String
        let blocks: [MarkdownBlock]
        let revision: UInt64

        func matches(_ source: String) -> Bool { self.source.utf8.elementsEqual(source.utf8) }
    }

    private(set) var snapshot: Snapshot?
    private(set) var isActive = false
    @ObservationIgnored private var pending: Job?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var revision: UInt64 = 0
    private let parse: @Sendable (String) -> [MarkdownBlock]
    private let interval: Duration

    private struct Job: Sendable {
        let input: MarkdownInput
        let revision: UInt64
    }

    init(interval: Duration = .milliseconds(33), parse: @escaping @Sendable (String) -> [MarkdownBlock] = MarkdownBlocks.parse) {
        self.interval = interval
        self.parse = parse
    }

    func submit(_ input: MarkdownInput) {
        guard input.streaming || isActive else { return }
        if !isActive { isActive = true }
        if snapshot?.matches(input.text) == true {
            // A terminal event can repeat the exact source already displayed.
            // Retain that snapshot for the completed store and stop old jobs.
            stopWorker()
            return
        }
        revision &+= 1
        pending = Job(input: input, revision: revision)
        guard worker == nil else { return }
        generation &+= 1
        let current = generation
        worker = Task { [weak self] in await self?.drain(generation: current) }
    }

    func reset() {
        stopWorker()
        snapshot = nil
        isActive = false
    }

    func releaseCompletedSnapshot(revision: UInt64) -> Bool {
        guard snapshot?.revision == revision else { return false }
        reset()
        return true
    }

    private func stopWorker() {
        generation &+= 1
        worker?.cancel()
        worker = nil
        pending = nil
    }

    private func drain(generation current: UInt64) async {
        let parse = self.parse
        while generation == current, let job = pending {
            pending = nil
            let started = ContinuousClock.now
            let parseTask = Task.detached(priority: .userInitiated) {
                Task.isCancelled ? [] : parse(job.input.text)
            }
            let blocks = await withTaskCancellationHandler {
                await parseTask.value
            } onCancel: {
                parseTask.cancel()
            }
            guard generation == current, !Task.isCancelled else { return }
            // A running reply may publish a still-useful prefix. For source
            // rewrites or a terminal event, wait for the exact newest source.
            if pending == nil || pending.map({ next in
                next.input.streaming && next.input.text.utf8.starts(with: job.input.text.utf8)
            }) == true {
                snapshot = Snapshot(source: job.input.text, blocks: blocks, revision: job.revision)
            }
            if job.input.streaming, pending?.input.streaming != false {
                try? await ContinuousClock().sleep(until: started.advanced(by: interval))
            }
        }
        if generation == current { worker = nil }
    }
}
