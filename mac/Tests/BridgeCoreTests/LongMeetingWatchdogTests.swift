import XCTest
@testable import BridgeCore

final class LongMeetingWatchdogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testStaysIdleBeforeTwoHours() {
        let watchdog = LongMeetingWatchdog(startedAt: start)
        XCTAssertEqual(watchdog.decision(now: start.addingTimeInterval(119 * 60)), .idle)
    }

    func testPromptsAtTwoHours() {
        let watchdog = LongMeetingWatchdog(startedAt: start)
        XCTAssertEqual(watchdog.decision(now: start.addingTimeInterval(2 * 60 * 60)), .prompt)
    }

    func testPromptStaysOpenBeforeTheAutoStopGrace() {
        var watchdog = LongMeetingWatchdog(startedAt: start)
        let promptedAt = start.addingTimeInterval(2 * 60 * 60)
        watchdog.markPrompted(at: promptedAt)
        XCTAssertEqual(watchdog.decision(now: promptedAt.addingTimeInterval(29 * 60)), .prompt)
    }

    func testIgnoredPromptAutoStopsAfterThirtyMinutes() {
        var watchdog = LongMeetingWatchdog(startedAt: start)
        let promptedAt = start.addingTimeInterval(2 * 60 * 60)
        watchdog.markPrompted(at: promptedAt)
        XCTAssertEqual(watchdog.decision(now: promptedAt.addingTimeInterval(30 * 60)), .autoStop)
    }

    func testAcknowledgementClosesThePromptAndRestartsTheClock() {
        var watchdog = LongMeetingWatchdog(startedAt: start)
        let promptedAt = start.addingTimeInterval(2 * 60 * 60)
        watchdog.markPrompted(at: promptedAt)
        watchdog.acknowledge(at: promptedAt.addingTimeInterval(60))

        XCTAssertEqual(watchdog.decision(now: promptedAt.addingTimeInterval(60 * 60)), .idle)
        XCTAssertEqual(watchdog.decision(now: promptedAt.addingTimeInterval(61 * 60 + 60)), .idle)
        XCTAssertEqual(watchdog.decision(now: promptedAt.addingTimeInterval(3 * 60 * 60)), .prompt)
    }

    func testMarkPromptedKeepsTheOriginalPromptTime() {
        var watchdog = LongMeetingWatchdog(startedAt: start)
        let promptedAt = start.addingTimeInterval(2 * 60 * 60)
        watchdog.markPrompted(at: promptedAt)
        watchdog.markPrompted(at: promptedAt.addingTimeInterval(20 * 60))

        XCTAssertEqual(watchdog.decision(now: promptedAt.addingTimeInterval(30 * 60)), .autoStop)
    }
}
