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
        let stableSource: String
        let blocks: [MarkdownBlock]
        let skeletonKind: ProgressiveMarkdownSkeletonKind?
        let revision: UInt64

        func matches(_ source: String) -> Bool { self.source.utf8.elementsEqual(source.utf8) }
    }

    private(set) var snapshot: Snapshot?
    private(set) var isActive = false
    /// Delayed skeleton visibility (300 ms grace period) avoids flashing on short outputs.
    private(set) var showsSkeleton = false
    @ObservationIgnored private var pending: Job?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var skeletonRevealTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var revision: UInt64 = 0
    private let parse: @Sendable (String) -> [MarkdownBlock]
    private let interval: Duration
    private let skeletonDelay: Duration

    private struct Job: Sendable {
        let input: MarkdownInput
        let revision: UInt64
    }

    init(
        interval: Duration = .milliseconds(140),
        skeletonDelay: Duration = .milliseconds(300),
        parse: @escaping @Sendable (String) -> [MarkdownBlock] = MarkdownBlocks.parse
    ) {
        self.interval = interval
        self.skeletonDelay = skeletonDelay
        self.parse = parse
    }

    func submit(_ input: MarkdownInput) {
        guard input.streaming || isActive else { return }
        if !isActive { isActive = true }
        if !input.streaming {
            // Stream ended, cancelled, or errored: clear skeleton immediately and converge on full source.
            cancelSkeletonReveal()
            showsSkeleton = false
        }
        if snapshot?.matches(input.text) == true && (input.streaming || snapshot?.skeletonKind == nil) {
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
        cancelSkeletonReveal()
        showsSkeleton = false
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

    private func cancelSkeletonReveal() {
        skeletonRevealTask?.cancel()
        skeletonRevealTask = nil
    }

    private func updateSkeletonVisibility(hasUnstableTail: Bool, streaming: Bool) {
        guard streaming && hasUnstableTail else {
            cancelSkeletonReveal()
            showsSkeleton = false
            return
        }
        if showsSkeleton || skeletonRevealTask != nil { return }
        let delay = skeletonDelay
        if delay <= .zero {
            showsSkeleton = true
            return
        }
        skeletonRevealTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: delay)
            } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.skeletonRevealTask = nil
            if self.snapshot?.skeletonKind != nil {
                self.showsSkeleton = true
            }
        }
    }

    private func drain(generation current: UInt64) async {
        let parse = self.parse
        while generation == current, let job = pending {
            pending = nil
            let started = ContinuousClock.now
            let parseTask = Task.detached(priority: .userInitiated) { () -> (ProgressiveMarkdownSplit, [MarkdownBlock]) in
                if Task.isCancelled {
                    return (ProgressiveMarkdownSplit(stableSource: "", unstableTail: "", skeletonKind: nil), [])
                }
                let split = ProgressiveMarkdownSplitter.split(job.input.text, isStreaming: job.input.streaming)
                let blocks = split.stableSource.isEmpty ? [] : parse(split.stableSource)
                return (split, blocks)
            }
            let (split, blocks) = await withTaskCancellationHandler {
                await parseTask.value
            } onCancel: {
                parseTask.cancel()
            }
            guard generation == current, !Task.isCancelled else { return }
            if pending == nil || pending.map({ next in
                next.input.streaming && next.input.text.utf8.starts(with: job.input.text.utf8)
            }) == true {
                snapshot = Snapshot(
                    source: job.input.text,
                    stableSource: split.stableSource,
                    blocks: blocks,
                    skeletonKind: job.input.streaming ? split.skeletonKind : nil,
                    revision: job.revision
                )
                updateSkeletonVisibility(hasUnstableTail: split.skeletonKind != nil, streaming: job.input.streaming)
            }
            if job.input.streaming, pending?.input.streaming != false {
                try? await ContinuousClock().sleep(until: started.advanced(by: interval))
            }
        }
        if generation == current { worker = nil }
    }
}
