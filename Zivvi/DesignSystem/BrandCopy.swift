import Foundation

/// Presentation-layer brand vocabulary (Z-onomatopoeia) derived strictly from real runtime states.
/// Never enters prompts, drafts, copied text, runtime protocols, or persisted session history.
enum BrandCopy {
    static let welcome = "Ready to Zip?"
    static let userMessage = "Zip!"
    static let agentStarted = "Zap!"
    static let agentRunning = "Zap…"
    static let subagentCompleted = "Zing!"
    static let completed = "Zzzap!"
    static let failed = "Zzzzt…"
    static let signature = "Zip. Zap. Zing."
    static let slogan = "Many minds. One spark."
}

/// Authoritative presentation-layer brand state derived from real session/turn runtime events.
enum BrandPresentationState: Equatable, Sendable {
    case idle
    case starting
    case running
    case subagentCompleted
    case completed
    case failed
    case awaitingApproval
    case awaitingInput
    case paused
    case stopped
    case queued
    case steering
    case uncertain
    case historicalOutcomeMissing

    /// Fixed cross-language brand cue when applicable; nil for functional/system states
    /// that must show explicit localized semantics without false running or completion cues.
    var brandCue: String? {
        switch self {
        case .starting: BrandCopy.agentStarted
        case .running: BrandCopy.agentRunning
        case .subagentCompleted: BrandCopy.subagentCompleted
        case .completed: BrandCopy.completed
        case .failed: BrandCopy.failed
        case .idle, .awaitingApproval, .awaitingInput, .paused, .stopped,
             .queued, .steering, .uncertain, .historicalOutcomeMissing:
            nil
        }
    }

    var brandIcon: LightningBrandIcon {
        switch self {
        case .idle: .agent
        case .starting, .running: .active
        case .subagentCompleted, .completed: .complete
        case .failed: .error
        case .awaitingApproval: .approval
        case .awaitingInput: .agent
        case .paused, .stopped: .pause
        case .queued: .queue
        case .steering: .steer
        case .uncertain, .historicalOutcomeMissing: .agent
        }
    }

    var isActivelyFlowing: Bool {
        self == .starting || self == .running
    }
}
