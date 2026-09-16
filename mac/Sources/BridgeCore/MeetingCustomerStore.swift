import Foundation

public struct MeetingCustomerAssociation: Codable, Equatable, Identifiable {
    public let id: String
    public var customer: String
    public let calendarIdentifier: String?
    public let eventTitle: String
    public let externalDomains: [String]

    public init(
        id: String = UUID().uuidString,
        customer: String,
        calendarIdentifier: String?,
        eventTitle: String,
        externalDomains: [String]
    ) {
        self.id = id
        self.customer = customer
        self.calendarIdentifier = calendarIdentifier
        self.eventTitle = eventTitle
        self.externalDomains = externalDomains
    }
}

public enum MeetingCustomerMatcher {
    public static func resolve(
        event: MeetingCalendarEvent,
        customers: [String],
        associations: [MeetingCustomerAssociation]
    ) -> String? {
        let learned = Set(associations.compactMap { association -> String? in
            guard associationMatches(association, event: event) else { return nil }
            return canonical(association.customer, in: customers)
        })
        if learned.count > 1 { return nil }
        if let customer = learned.first { return customer }
        guard let inferred = MeetingCalendarMatcher.suggestedCustomer(from: event.participants) else { return nil }
        return canonical(inferred, in: customers)
    }

    public static func externalDomains(in event: MeetingCalendarEvent) -> [String] {
        Array(Set(event.participants.compactMap { participant in
            guard !participant.isCurrentUser, let email = participant.email else { return nil }
            return MeetingCalendarMatcher.organizationDomain(for: email)
        })).sorted()
    }

    public static func titleKey(_ title: String) -> String {
        title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    private static func associationMatches(_ association: MeetingCustomerAssociation, event: MeetingCalendarEvent) -> Bool {
        let sameTitle = titleKey(association.eventTitle) == titleKey(event.title)
        let sameCalendar = association.calendarIdentifier == nil || association.calendarIdentifier == event.calendarIdentifier
        if sameTitle && sameCalendar { return true }
        let domains = Set(externalDomains(in: event))
        return !domains.isDisjoint(with: association.externalDomains)
    }

    private static func canonical(_ candidate: String, in customers: [String]) -> String? {
        customers.first { $0.caseInsensitiveCompare(candidate) == .orderedSame }
    }
}

public final class MeetingCustomerStore {
    public struct StoreError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private struct State: Codable {
        var customers: [String] = []
        var associations: [MeetingCustomerAssociation] = []
    }

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let dataURL: URL
    private let fixedBrainRootURL: URL?

    public init(dataURL: URL? = nil, brainRootURL: URL? = nil) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser
        self.dataURL = dataURL ?? support.appendingPathComponent("AndroidBridge/customer-automation.json")
        self.fixedBrainRootURL = brainRootURL
    }

    public func customers(meetingNames: [String]) throws -> [String] {
        try synchronized {
            let state = try load()
            return deduplicated(state.customers + brainCustomers() + meetingNames)
        }
    }

    @discardableResult
    public func addCustomer(_ name: String) throws -> String {
        try synchronized { try addCustomerUnlocked(name) }
    }

    public func associations() throws -> [MeetingCustomerAssociation] {
        try synchronized { try load().associations }
    }

    public func remember(event: MeetingCalendarEvent, customer: String) throws {
        try synchronized {
            let canonical = try addCustomerUnlocked(customer)
            var state = try load()
            let titleKey = MeetingCustomerMatcher.titleKey(event.title)
            state.associations.removeAll {
                $0.calendarIdentifier == event.calendarIdentifier && MeetingCustomerMatcher.titleKey($0.eventTitle) == titleKey
            }
            state.associations.append(MeetingCustomerAssociation(
                customer: canonical,
                calendarIdentifier: event.calendarIdentifier,
                eventTitle: String(event.title.prefix(500)),
                externalDomains: MeetingCustomerMatcher.externalDomains(in: event)
            ))
            try save(state)
        }
    }

    public func changeAssociation(id: String, customer: String) throws {
        try synchronized {
            let canonical = try addCustomerUnlocked(customer)
            var state = try load()
            guard let index = state.associations.firstIndex(where: { $0.id == id }) else {
                throw StoreError(message: "The customer match no longer exists.")
            }
            state.associations[index].customer = canonical
            try save(state)
        }
    }

    public func forgetAssociation(id: String) throws {
        try synchronized {
            var state = try load()
            state.associations.removeAll { $0.id == id }
            try save(state)
        }
    }

    private func addCustomerUnlocked(_ name: String) throws -> String {
        let clean = try validatedName(name)
        var state = try load()
        if let existing = state.customers.first(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) { return existing }
        state.customers.append(clean)
        try save(state)
        return clean
    }

    private func synchronized<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    private func load() throws -> State {
        guard fileManager.fileExists(atPath: dataURL.path) else { return State() }
        do {
            return try JSONDecoder().decode(State.self, from: Data(contentsOf: dataURL))
        } catch {
            throw StoreError(message: "Customer data could not be read. Restore or remove the customer data file, then try again.")
        }
    }

    private func save(_ state: State) throws {
        do {
            try fileManager.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: dataURL, options: .atomic)
        } catch {
            throw StoreError(message: "Customer changes could not be saved. Check folder access and try again.")
        }
    }

    private func validatedName(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 200, clean.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw StoreError(message: "Customer names must contain 1 to 200 visible characters.")
        }
        return clean
    }

    private func brainCustomers() -> [String] {
        let root = fixedBrainRootURL ?? configuredBrainRoot()
        let roots = ["work/sela/meetings", "work/meetings"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        let directories = roots.flatMap {
            (try? fileManager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        return directories.filter(\.hasDirectoryPath).compactMap { directory in
            guard let text = try? String(contentsOf: directory.appendingPathComponent("index.md"), encoding: .utf8) else { return nil }
            return text.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
        }
    }

    private func configuredBrainRoot() -> URL {
        let configured = UserDefaults.standard.string(forKey: "secondBrain.root")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = ProcessInfo.processInfo.environment["BRAIN_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configured?.isEmpty == false ? configured! : (environment?.isEmpty == false ? environment! : fileManager.homeDirectoryForCurrentUser.appendingPathComponent("second_brain").path)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func deduplicated(_ names: [String]) -> [String] {
        var byKey = [String: String]()
        for name in names {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 200 else { continue }
            byKey[clean.lowercased(), default: clean] = byKey[clean.lowercased()] ?? clean
        }
        return byKey.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
