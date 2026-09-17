import Foundation

/// Decides when a still-running recording should ask the user whether the
/// meeting is really still going, and when an ignored prompt should end it.
///
/// A recorder has no idea a meeting is over: left alone it keeps writing chunks
/// until someone presses Stop. After `promptAfter` the user is asked to
/// acknowledge, and an acknowledgement buys another `promptAfter`. If nobody
/// answers within `autoStopAfterPrompt` — laptop closed, user gone home — the
/// meeting is stopped and saved instead of running overnight.
public struct LongMeetingWatchdog: Equatable {
    public enum Decision: Equatable {
        /// Nothing to do yet.
        case idle
        /// Show (or keep showing) the "still recording?" prompt.
        case prompt
        /// The prompt went unanswered for too long — stop and save the meeting.
        case autoStop
    }

    public static let promptAfter: TimeInterval = 2 * 60 * 60
    public static let autoStopAfterPrompt: TimeInterval = 30 * 60

    public let startedAt: Date
    /// When the user last confirmed the meeting is still going.
    public var acknowledgedAt: Date?
    /// When the currently open prompt was raised, or nil when none is open.
    public var promptedAt: Date?

    public init(startedAt: Date, acknowledgedAt: Date? = nil, promptedAt: Date? = nil) {
        self.startedAt = startedAt
        self.acknowledgedAt = acknowledgedAt
        self.promptedAt = promptedAt
    }

    public func decision(now: Date) -> Decision {
        if let promptedAt {
            return now.timeIntervalSince(promptedAt) >= Self.autoStopAfterPrompt ? .autoStop : .prompt
        }
        let since = acknowledgedAt ?? startedAt
        return now.timeIntervalSince(since) >= Self.promptAfter ? .prompt : .idle
    }

    /// The user confirmed the meeting is still going: close the prompt and
    /// restart the two-hour clock.
    public mutating func acknowledge(at now: Date) {
        acknowledgedAt = now
        promptedAt = nil
    }

    public mutating func markPrompted(at now: Date) {
        if promptedAt == nil { promptedAt = now }
    }
}
