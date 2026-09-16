import Foundation
import EventKit

public enum MeetingProcessingState: String, Codable, CaseIterable {
    case recording
    case finalizing
    case ready
    case needsAttention
}

public struct MeetingCalendarParticipant: Codable, Equatable {
    public let name: String
    public let email: String?
    public let isCurrentUser: Bool

    public init(name: String, email: String?, isCurrentUser: Bool) {
        self.name = name
        self.email = email
        self.isCurrentUser = isCurrentUser
    }
}

public struct MeetingCalendarDescriptor: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let source: String

    public init(id: String, title: String, source: String) {
        self.id = id
        self.title = title
        self.source = source
    }
}

public struct MeetingCalendarEvent: Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let calendarTitle: String
    public let calendarIdentifier: String?
    public let calendarSource: String?
    public let organizer: String?
    public let participants: [MeetingCalendarParticipant]
    public let meetingURL: String?
    public let location: String?

    public init(id: String, title: String, start: Date, end: Date, calendarTitle: String, calendarIdentifier: String? = nil, calendarSource: String? = nil, organizer: String?, participants: [MeetingCalendarParticipant], meetingURL: String?, location: String?) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendarTitle = calendarTitle
        self.calendarIdentifier = calendarIdentifier
        self.calendarSource = calendarSource
        self.organizer = organizer
        self.participants = participants
        self.meetingURL = meetingURL
        self.location = location
    }
}

public enum MeetingCalendarMatcher {
    private static let genericDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "yahoo.com", "icloud.com", "me.com", "aol.com", "proton.me", "protonmail.com",
    ]

    public static func overlapping<S: Sequence>(_ events: S, meetingStart: Date, meetingEnd: Date, tolerance: TimeInterval = 0) -> [MeetingCalendarEvent] where S.Element == MeetingCalendarEvent {
        let paddedStart = meetingStart.addingTimeInterval(-tolerance)
        let paddedEnd = meetingEnd.addingTimeInterval(tolerance)
        return events.filter { $0.start < paddedEnd && $0.end > paddedStart }.sorted {
            let leftOverlap = overlapDuration($0, meetingStart: meetingStart, meetingEnd: meetingEnd)
            let rightOverlap = overlapDuration($1, meetingStart: meetingStart, meetingEnd: meetingEnd)
            if leftOverlap != rightOverlap { return leftOverlap > rightOverlap }
            let left = abs($0.start.timeIntervalSince(meetingStart))
            let right = abs($1.start.timeIntervalSince(meetingStart))
            if left != right { return left < right }
            if $0.title != $1.title { return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private static func overlapDuration(_ event: MeetingCalendarEvent, meetingStart: Date, meetingEnd: Date) -> TimeInterval {
        max(0, min(event.end, meetingEnd).timeIntervalSince(max(event.start, meetingStart)))
    }

    public static func suggestedCustomer(from participants: [MeetingCalendarParticipant]) -> String? {
        let labels = Set(participants.compactMap { participant -> String? in
            guard !participant.isCurrentUser, let email = participant.email else { return nil }
            return companyLabel(for: email)
        })
        return labels.count == 1 ? labels.first : nil
    }

    public static func companyLabel(for email: String) -> String? {
        guard let domain = organizationDomain(for: email) else { return nil }
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let countrySuffixes = ["co.uk", "com.au", "co.il", "co.jp"]
        let suffix = labels.suffix(2).joined(separator: ".")
        let companyIndex = countrySuffixes.contains(suffix) && labels.count >= 3 ? labels.count - 3 : labels.count - 2
        let name = labels[companyIndex].replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return name.isEmpty ? nil : name.capitalized
    }

    public static func organizationDomain(for email: String) -> String? {
        let parts = email.lowercased().split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let domain = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return domain.contains(".") && !genericDomains.contains(domain) ? domain : nil
    }
}

public enum CalendarAuthorizationState: Equatable {
    case notDetermined
    case granted
    case denied
}

public enum MeetingCalendarError: LocalizedError {
    case accessDenied
    case accessFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied: return "Calendar access is off. Enable it in System Settings → Privacy & Security → Calendars."
        case .accessFailed(let detail): return "Calendar access failed: \(detail)"
        }
    }
}

public final class MeetingCalendarService {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func authorizationState() -> CalendarAuthorizationState {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess, .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
        return status == .authorized ? .granted : (status == .notDetermined ? .notDetermined : .denied)
    }

    public func calendars(completion: @escaping (Result<[MeetingCalendarDescriptor], Error>) -> Void) {
        requestAccess { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success:
                let calendars = self.store.calendars(for: .event).map {
                    MeetingCalendarDescriptor(id: $0.calendarIdentifier, title: self.bounded($0.title), source: self.bounded($0.source.title))
                }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                completion(.success(calendars))
            }
        }
    }

    public func events(overlapping start: Date, end: Date, calendarIdentifier: String? = nil, tolerance: TimeInterval = 0, completion: @escaping (Result<[MeetingCalendarEvent], Error>) -> Void) {
        fetch(start: start.addingTimeInterval(-tolerance), end: end.addingTimeInterval(tolerance), calendarIdentifier: calendarIdentifier) { result in
            completion(result.map { MeetingCalendarMatcher.overlapping($0, meetingStart: start, meetingEnd: end, tolerance: tolerance) })
        }
    }

    /// Every event inside the window, in calendar order, so the user can browse a day instead of relying on an overlap match.
    public func events(from start: Date, to end: Date, calendarIdentifier: String? = nil, completion: @escaping (Result<[MeetingCalendarEvent], Error>) -> Void) {
        fetch(start: start, end: end, calendarIdentifier: calendarIdentifier) { result in
            completion(result.map { events in
                events.sorted {
                    if $0.start != $1.start { return $0.start < $1.start }
                    if $0.title != $1.title { return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    return $0.id < $1.id
                }
            })
        }
    }

    private func fetch(start: Date, end: Date, calendarIdentifier: String?, completion: @escaping (Result<[MeetingCalendarEvent], Error>) -> Void) {
        requestAccess { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success:
                let calendars: [EKCalendar]?
                if let calendarIdentifier {
                    guard let calendar = self.store.calendar(withIdentifier: calendarIdentifier) else {
                        completion(.success([]))
                        return
                    }
                    calendars = [calendar]
                } else {
                    calendars = nil
                }
                let predicate = self.store.predicateForEvents(withStart: start, end: end, calendars: calendars)
                completion(.success(self.store.events(matching: predicate).map(self.snapshot)))
            }
        }
    }

    public func requestAccess(completion: @escaping (Result<Void, Error>) -> Void) {
        switch authorizationState() {
        case .granted: completion(.success(()))
        case .denied: completion(.failure(MeetingCalendarError.accessDenied))
        case .notDetermined:
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { granted, error in self.finishAccess(granted: granted, error: error, completion: completion) }
            } else {
                store.requestAccess(to: .event) { granted, error in self.finishAccess(granted: granted, error: error, completion: completion) }
            }
        }
    }

    private func finishAccess(granted: Bool, error: Error?, completion: @escaping (Result<Void, Error>) -> Void) {
        if granted { completion(.success(())); return }
        if let error { completion(.failure(MeetingCalendarError.accessFailed(error.localizedDescription))); return }
        completion(.failure(MeetingCalendarError.accessDenied))
    }

    private func snapshot(_ event: EKEvent) -> MeetingCalendarEvent {
        let participants = (event.attendees ?? []).prefix(100).map { attendee in
            MeetingCalendarParticipant(name: bounded(attendee.name ?? ""), email: email(from: attendee.url), isCurrentUser: attendee.isCurrentUser)
        }
        let organizer = event.organizer.flatMap { bounded($0.name ?? email(from: $0.url) ?? "") }
        return MeetingCalendarEvent(
            id: bounded(event.calendarItemIdentifier, limit: 300),
            title: bounded(event.title ?? "Calendar Event"),
            start: event.startDate,
            end: event.endDate,
            calendarTitle: bounded(event.calendar.title),
            calendarIdentifier: bounded(event.calendar.calendarIdentifier, limit: 300),
            calendarSource: bounded(event.calendar.source.title),
            organizer: organizer?.isEmpty == false ? organizer : nil,
            participants: participants,
            meetingURL: event.url.map { bounded($0.absoluteString, limit: 2_000) },
            location: event.location.map { bounded($0) }
        )
    }

    private func email(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let raw = String(url.absoluteString.dropFirst("mailto:".count))
        let value = raw.removingPercentEncoding?.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func bounded(_ value: String, limit: Int = 500) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}
