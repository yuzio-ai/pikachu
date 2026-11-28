import Observation
import SwiftUI

/// Timing constants aligned with `design-tokens.json` and `BRAND-IMPLEMENTATION.md`.
enum BrandMotionTiming {
    static let launchDuration: TimeInterval = 0.80
    static let idlePeriod: TimeInterval = 5.0
    static let runningPeriod: TimeInterval = 1.8
    static let completionDuration: TimeInterval = 0.45
    static let failureCutoffDuration: TimeInterval = 0.22
    static let masterAspectRatio: CGFloat = 759.0 / 830.0
    static let welcomeLogoWidth: CGFloat = 104.0
}

/// Coordinates one-shot brand motion deduplication across turns and cold launch
/// so history replay, session switching, and window restoration never replay stale celebrations.
@MainActor
@Observable
final class BrandTurnMotionTracker {
    static let shared = BrandTurnMotionTracker()

    private(set) var hasPlayedColdLaunch = false
    @ObservationIgnored private var observedRunningTurns: Set<UUID> = []
    @ObservationIgnored private var dischargedTurns: Set<UUID> = []
    @ObservationIgnored private var failedCutoffTurns: Set<UUID> = []

    func consumeColdLaunch() -> Bool {
        guard !hasPlayedColdLaunch else { return false }
        hasPlayedColdLaunch = true
        return true
    }

    func markRunning(_ turnID: UUID) {
        observedRunningTurns.insert(turnID)
    }

    /// Returns true once for a turn observed transitioning live from `.running` to `.completed`.
    func consumeCompletionDischarge(for turnID: UUID) -> Bool {
        guard observedRunningTurns.contains(turnID),
              !dischargedTurns.contains(turnID) else { return false }
        dischargedTurns.insert(turnID)
        return true
    }

    /// Returns true once for a turn observed transitioning live from `.running` to `.failed`.
    func consumeFailureCutoff(for turnID: UUID) -> Bool {
        guard observedRunningTurns.contains(turnID),
              !failedCutoffTurns.contains(turnID) else { return false }
        failedCutoffTurns.insert(turnID)
        return true
    }

    func resetForTesting() {
        hasPlayedColdLaunch = false
        observedRunningTurns.removeAll()
        dischargedTurns.removeAll()
        failedCutoffTurns.removeAll()
    }
}

/// Static approved 2D master logo preserving aspect ratio without stretching or clipping.
struct BrandMark: View {
    let width: CGFloat
    var bundle: Bundle = .main

    private var height: CGFloat {
        ceil(width / BrandMotionTiming.masterAspectRatio)
    }

    var body: some View {
        Image("BrandMasterLogo", bundle: bundle)
            .resizable()
            .scaledToFit()
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

/// Four-creature brand motion component supporting Cold Launch Convergence (800ms),
/// New Session Alive (5s), Multi-Agent Running Flow (1.8s), and Completion Discharge (450ms).
/// Always rests on the approved `BrandMasterLogo` when static, paused, or under Reduce Motion.
struct BrandMotionView: View {
    enum Mode: Equatable {
        case staticMaster
        case convergence(startedAt: Date)
        case alive(isPaused: Bool)
        case flow(isActive: Bool)
        case discharge(startedAt: Date)
    }

    let mode: Mode
    let width: CGFloat
    var bundle: Bundle = .main

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    private var height: CGFloat {
        ceil(width / BrandMotionTiming.masterAspectRatio)
    }

    private var isAnimating: Bool {
        guard !reduceMotion, appearsActive else { return false }
        switch mode {
        case .staticMaster: return false
        case .convergence: return true
        case .alive(let isPaused): return !isPaused
        case .flow(let isActive): return isActive
        case .discharge: return true
        }
    }

    var body: some View {
        Group {
            if !isAnimating {
                BrandMark(width: width, bundle: bundle)
            } else {
                switch mode {
                case .staticMaster:
                    BrandMark(width: width, bundle: bundle)
                case .convergence(let startedAt):
                    convergenceContent(startedAt: startedAt)
                case .alive:
                    aliveContent
                case .flow:
                    flowContent
                case .discharge(let startedAt):
                    dischargeContent(startedAt: startedAt)
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    // MARK: - 1. Cold Launch Convergence (800ms single-shot)

    private func convergenceContent(startedAt: Date) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            if elapsed >= BrandMotionTiming.launchDuration {
                BrandMark(width: width, bundle: bundle)
            } else {
                let scaleUnit = width / 180.0
                let masterCrossfade = clamp((elapsed - 0.68) / 0.12)
                let layersOpacity = 1.0 - masterCrossfade
                let energyOpacity = clamp((elapsed - 0.56) / 0.22)

                ZStack {
                    ZStack {
                        layerImage("BrandLayerEnergyTrail")
                            .opacity(energyOpacity)
                        layerImage("BrandLayerEnergyRays")
                            .opacity(energyOpacity)
                        convergingLayer("BrandLayerAgentBottom", elapsed: elapsed, delay: 0.03,
                                        offset: CGSize(width: -55 * scaleUnit, height: 100 * scaleUnit),
                                        angle: 9)
                        convergingLayer("BrandLayerAgentLeft", elapsed: elapsed, delay: 0.11,
                                        offset: CGSize(width: -115 * scaleUnit, height: 30 * scaleUnit),
                                        angle: -10)
                        convergingLayer("BrandLayerAgentMain", elapsed: elapsed, delay: 0.06,
                                        offset: CGSize(width: 135 * scaleUnit, height: 15 * scaleUnit),
                                        angle: -8)
                        convergingLayer("BrandLayerAgentTop", elapsed: elapsed, delay: 0.0,
                                        offset: CGSize(width: 90 * scaleUnit, height: -100 * scaleUnit),
                                        angle: 13)
                    }
                    .opacity(layersOpacity)

                    if masterCrossfade > 0 {
                        BrandMark(width: width, bundle: bundle)
                            .opacity(masterCrossfade)
                    }
                }
            }
        }
    }

    private func convergingLayer(
        _ name: String,
        elapsed: TimeInterval,
        delay: TimeInterval,
        offset: CGSize,
        angle: Double
    ) -> some View {
        let duration: TimeInterval = 0.62
        let t = clamp((elapsed - delay) / duration)
        // Ease-out with subtle 1.8% overshoot near t=0.88 settling cleanly to 1.0
        let eased = 1.0 - pow(1.0 - t, 3.0)
        let opacity = clamp(t / 0.25)
        let scale: Double = if t < 0.88 {
            0.86 + (1.018 - 0.86) * eased
        } else {
            1.018 - 0.018 * ((t - 0.88) / 0.12)
        }
        return layerImage(name)
            .opacity(opacity)
            .scaleEffect(scale)
            .rotationEffect(.degrees(angle * (1.0 - eased)))
            .offset(x: offset.width * (1.0 - eased), y: offset.height * (1.0 - eased))
    }

    // MARK: - 2. New Session Alive (5s low-frequency loop)

    private var aliveContent: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let period = BrandMotionTiming.idlePeriod
            let phase = (now.truncatingRemainder(dividingBy: period)) / period
            let wave = 0.5 - 0.5 * cos(2 * .pi * phase) // 0 -> 1 -> 0 smooth
            let floatY = -2.0 * wave

            let topWave = 0.5 - 0.5 * cos(2 * .pi * phase)
            let leftWave = 0.5 - 0.5 * cos(2 * .pi * ((phase + 1.5 / period).truncatingRemainder(dividingBy: 1)))
            let bottomWave = 0.5 - 0.5 * cos(2 * .pi * ((phase + 2.8 / period).truncatingRemainder(dividingBy: 1)))

            ZStack {
                layerImage("BrandLayerEnergyTrail")
                layerImage("BrandLayerEnergyRays")
                    .opacity(1.0 - 0.52 * wave)
                layerImage("BrandLayerAgentBottom")
                    .opacity(1.0 - 0.12 * bottomWave)
                layerImage("BrandLayerAgentLeft")
                    .opacity(1.0 - 0.12 * leftWave)
                layerImage("BrandLayerAgentMain")
                layerImage("BrandLayerAgentTop")
                    .opacity(1.0 - 0.12 * topWave)
            }
            .offset(y: floatY)
        }
    }

    // MARK: - 3. Multi-Agent Running Flow (1.8s staggered loop)

    private func flowEnergyPulse(now: TimeInterval, delay: TimeInterval) -> (opacity: Double, brightness: Double) {
        let period = BrandMotionTiming.runningPeriod
        let p = ((now - delay).truncatingRemainder(dividingBy: period) + period)
            .truncatingRemainder(dividingBy: period) / period
        let w = 0.5 - 0.5 * cos(2 * .pi * p)
        return (opacity: 1.0 - 0.36 * w, brightness: 0.08 * w)
    }

    private var flowContent: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let period = BrandMotionTiming.runningPeriod
            let top = flowEnergyPulse(now: now, delay: 0.0)
            let main = flowEnergyPulse(now: now, delay: 0.35)
            let left = flowEnergyPulse(now: now, delay: 0.70)
            let bottom = flowEnergyPulse(now: now, delay: 1.05)
            let raysWave = 0.5 - 0.5 * cos(2 * .pi * (now.truncatingRemainder(dividingBy: period) / period))

            ZStack {
                layerImage("BrandLayerEnergyTrail")
                    .opacity(0.72)
                layerImage("BrandLayerEnergyRays")
                    .opacity(1.0 - 0.50 * raysWave)
                layerImage("BrandLayerAgentBottom")
                    .opacity(bottom.opacity)
                    .brightness(bottom.brightness)
                layerImage("BrandLayerAgentLeft")
                    .opacity(left.opacity)
                    .brightness(left.brightness)
                layerImage("BrandLayerAgentMain")
                    .opacity(main.opacity)
                    .brightness(main.brightness)
                layerImage("BrandLayerAgentTop")
                    .opacity(top.opacity)
                    .brightness(top.brightness)
            }
        }
    }

    // MARK: - 4. Completion Discharge (450ms single-shot)

    private func dischargeContent(startedAt: Date) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let t = clamp(elapsed / BrandMotionTiming.completionDuration)
            let scale: Double
            let bright: Double
            if t >= 1.0 {
                scale = 1.0
                bright = 0.0
            } else if t < 0.20 {
                let u = t / 0.20
                scale = 1.0 - 0.08 * u
                bright = 0.0
            } else if t < 0.50 {
                let u = (t - 0.20) / 0.30
                scale = 0.92 + (1.16 - 0.92) * u
                bright = 0.13 * u
            } else {
                let u = (t - 0.50) / 0.50
                let ease = 1.0 - pow(1.0 - u, 2.0)
                scale = 1.16 - 0.16 * ease
                bright = 0.13 * (1.0 - ease)
            }
            return BrandMark(width: width, bundle: bundle)
                .scaleEffect(scale)
                .brightness(bright)
        }
    }

    private func layerImage(_ name: String) -> some View {
        Image(name, bundle: bundle)
            .resizable()
            .scaledToFit()
            .frame(width: width, height: height)
    }

    private func clamp(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

/// Compact 16–20pt brand state icon used in turn headers and compact status rows.
/// Isolates per-frame animation state inside a leaf view so parent transcript rows never re-layout.
struct BrandStateIconView: View {
    let state: BrandPresentationState
    let turnID: UUID?
    var size: CGFloat = 16
    var isMuted = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var dischargeStart: Date?
    @State private var failureCutoffStart: Date?

    private var tint: Color {
        isMuted ? ZivviTheme.secondaryText : ZivviTheme.iconYellow
    }

    var body: some View {
        ZStack {
            if state.isActivelyFlowing {
                singleAgentFlowView
            } else if state == .completed, let dischargeStart, !reduceMotion {
                dischargeGlyphView(startedAt: dischargeStart)
            } else if state == .failed, let failureCutoffStart, !reduceMotion {
                failureCutoffGlyphView(startedAt: failureCutoffStart)
            } else {
                LightningBrandIconView(state.brandIcon, size: size, tint: tint)
            }
        }
        .frame(width: size, height: size)
        .onAppear { syncLifecycle(for: state) }
        .onChange(of: state) { _, newState in syncLifecycle(for: newState) }
        .accessibilityHidden(true)
    }

    private func syncLifecycle(for currentState: BrandPresentationState) {
        guard let turnID else { return }
        let tracker = BrandTurnMotionTracker.shared
        switch currentState {
        case .starting, .running:
            tracker.markRunning(turnID)
            dischargeStart = nil
            failureCutoffStart = nil
        case .completed:
            failureCutoffStart = nil
            if !reduceMotion, tracker.consumeCompletionDischarge(for: turnID) {
                dischargeStart = .now
            }
        case .failed:
            dischargeStart = nil
            if !reduceMotion, tracker.consumeFailureCutoff(for: turnID) {
                failureCutoffStart = .now
            }
        default:
            dischargeStart = nil
            failureCutoffStart = nil
        }
    }

    private func flowWave(at date: Date, animate: Bool) -> Double {
        guard animate else { return 0 }
        let p = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: BrandMotionTiming.runningPeriod) / BrandMotionTiming.runningPeriod
        return 0.5 - 0.5 * cos(2 * .pi * p)
    }

    private var singleAgentFlowView: some View {
        let animate = !reduceMotion && appearsActive
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { timeline in
            let wave = flowWave(at: timeline.date, animate: animate)
            LightningBrandIconView(state.brandIcon, size: size, tint: tint)
                .opacity(1.0 - 0.34 * wave)
                .scaleEffect(1.0 + 0.04 * wave)
        }
    }

    private func dischargeGlyphView(startedAt: Date) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let t = min(1.0, elapsed / BrandMotionTiming.completionDuration)
            let scale: Double = if t >= 1.0 {
                1.0
            } else if t < 0.22 {
                1.0 - 0.08 * (t / 0.22)
            } else if t < 0.52 {
                0.92 + 0.26 * ((t - 0.22) / 0.30)
            } else {
                1.18 - 0.18 * (1.0 - pow(1.0 - (t - 0.52) / 0.48, 2.0))
            }
            let bright: Double = (t >= 0.22 && t < 1.0) ? 0.14 * sin(.pi * (t - 0.22) / 0.78) : 0
            LightningBrandIconView(.complete, size: size, tint: tint)
                .scaleEffect(scale)
                .brightness(bright)
        }
    }

    private func failureCutoffGlyphView(startedAt: Date) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let t = min(1.0, elapsed / BrandMotionTiming.failureCutoffDuration)
            // Brief energy interruption dip (<=220ms) then settles statically with zero jitter.
            let opacity: Double = t >= 1.0 ? 1.0 : (1.0 - 0.55 * sin(.pi * t))
            LightningBrandIconView(.error, size: size, tint: tint)
                .opacity(opacity)
        }
    }
}
