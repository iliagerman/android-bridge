import XCTest
import SwiftCheck
import Foundation
import AVFoundation
@testable import BridgeCore
import DeviceLinkProtocol

final class SecondBrainStoreRefreshTests: XCTestCase {
    func testConfiguredRootChangesWithoutRecreatingStore() {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let second = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { UserDefaults.standard.removeObject(forKey: "secondBrain.root") }
        UserDefaults.standard.set(first.path, forKey: "secondBrain.root")
        let store = SecondBrainStore()

        UserDefaults.standard.set(second.path, forKey: "secondBrain.root")

        XCTAssertEqual(store.rootURL.standardizedFileURL, second.standardizedFileURL)
    }

    func testRevisionChangesWhenMarkdownTreeChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: "secondBrain.root")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.set(root.path, forKey: "secondBrain.root")
        let store = SecondBrainStore()
        let initial = store.revision()

        try "# New note".write(to: root.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)

        XCTAssertNotEqual(store.revision(), initial)
    }
}

final class MessageRouterTests: XCTestCase {
    func testRoutesValidMessage() {
        let router = MessageRouter()
        var got: Message?
        router.register(MessageTypes.clipUpdate) { got = $0 }
        XCTAssertTrue(router.route(Message(id: "1", type: MessageTypes.clipUpdate)))
        XCTAssertNotNil(got)
    }
    func testDropsUnrouted() {
        XCTAssertFalse(MessageRouter().route(Message(id: "1", type: MessageTypes.smsReceived)))
    }
    func testDropsInvalid() {
        let router = MessageRouter()
        router.register(MessageTypes.clipUpdate) { _ in }
        XCTAssertFalse(router.route(Message(id: "1", type: MessageTypes.clipUpdate, protocolVersion: 2)))
    }
}

final class PluginRegistryTests: XCTestCase {
    func testDefaultsEnabled() {
        let r = PluginRegistry()
        XCTAssertTrue(FeatureId.allCases.allSatisfy { r.isEnabled($0) })
    }
    func testToggle() {
        let r = PluginRegistry()
        r.disable(.sms); XCTAssertFalse(r.isEnabled(.sms))
        r.enable(.sms); XCTAssertTrue(r.isEnabled(.sms))
    }
}

final class PairingTests: XCTestCase {
    func testQrRoundTripAndPin() throws {
        let a = PairingManager(store: InMemorySecureStore())
        let b = PairingManager(store: InMemorySecureStore())
        let idA = a.generateIdentity("galaxy")
        let peer = try b.consumePairingQr(a.createPairingQr(idA, host: "192.168.1.5", port: 5599))
        XCTAssertEqual(peer.deviceId, idA.deviceId)
        XCTAssertTrue(b.isPinned(peer.fingerprint))
        XCTAssertEqual(b.listPaired().count, 1)
    }
    func testTamperRejected() {
        let a = PairingManager(store: InMemorySecureStore())
        let b = PairingManager(store: InMemorySecureStore())
        let idA = a.generateIdentity("galaxy")
        let qr = a.createPairingQr(idA, host: "h", port: 1)
            .replacingOccurrences(of: a.fingerprint(of: idA.publicKeyB64), with: "00:11:22")
        XCTAssertThrowsError(try b.consumePairingQr(qr))
    }
}

final class FeatureTests: XCTestCase {
    func testClipboardDefaultManual() {
        let p = ClipboardSyncPolicy()
        XCTAssertFalse(p.shouldSend(userInitiated: false))
        XCTAssertTrue(p.shouldSend(userInitiated: true))
    }
    func testMappersValid() {
        let msgs = [
            Mappers.notification(pkg: "com.x", title: "t", text: "b", postedAt: 1),
            Mappers.smsReceived(threadId: 1, address: "+1", body: "hi", receivedAt: 2),
            Mappers.incomingCall(number: "+1", contactName: "Al"),
            Mappers.callAction("answer"),
            Mappers.clipboard("copied"),
            Message(id: "m", type: MessageTypes.meetingStart, payload: ["meetingId": .string("m1"), "startedAt": .int(1)]),
        ]
        XCTAssertTrue(msgs.allSatisfy { validate($0) == nil })
    }
    /// call.action "dial" must round-trip through the codec with the number intact,
    /// so the phone can place the call the Mac requested.
    func testCallDialRoundTripsWithNumber() throws {
        let m = Mappers.callAction("dial", number: "+15550100")
        let decoded = try MessageCodec.decode(try MessageCodec.encode(m))
        XCTAssertEqual(decoded.type, MessageTypes.callAction)
        XCTAssertEqual(decoded.payload["action"], .string("dial"))
        XCTAssertEqual(decoded.payload["number"], .string("+15550100"))
        XCTAssertNil(validate(decoded))
    }
}

// Property test (PBT-03): stream chunk/reassemble round-trip.
struct Blob: Arbitrary {
    let data: Data
    static var arbitrary: Gen<Blob> {
        Gen<Int>.choose((0, 3000)).flatMap { n in
            UInt8.arbitrary.proliferate(withSize: n).map { Blob(data: Data($0)) }
        }
    }
}

struct CustomerScenario: Arbitrary {
    let seed: Int
    let customer: String
    let eventTitle: String
    let domain: String

    static var arbitrary: Gen<CustomerScenario> {
        Int.arbitrary.map { value in
            let token = String(value.magnitude % 10_000)
            return CustomerScenario(seed: value, customer: "Customer \(token)", eventTitle: "Weekly \(token)", domain: "customer\(token).example")
        }
    }

    static func shrink(_ value: CustomerScenario) -> [CustomerScenario] {
        Int.shrink(value.seed).map { seed in
            let token = String(seed.magnitude % 10_000)
            return CustomerScenario(seed: seed, customer: "Customer \(token)", eventTitle: "Weekly \(token)", domain: "customer\(token).example")
        }
    }
}

struct CalendarIntervals: Arbitrary {
    let values: [Int]

    static var arbitrary: Gen<CalendarIntervals> {
        [Int].arbitrary.map(CalendarIntervals.init)
    }

    static func shrink(_ value: CalendarIntervals) -> [CalendarIntervals] {
        [Int].shrink(value.values).map(CalendarIntervals.init)
    }
}

final class MeetingCaptureTests: XCTestCase {
    func testNotesPlacesPhotoBeforeNearestLaterSegment() {
        let segments = [TranscriptSegment(speaker: "Speaker 1", startMs: 1000, endMs: 2000, text: "hello")]
        let photos = [MeetingPhoto(photoId: "p1", capturedAtMs: 500, fileName: "photo-p1.jpg")]
        let md = NotesBuilder().build(meetingId: "m1", segments: segments, photos: photos)
        XCTAssertTrue(md.contains("![Photo at 500ms](media/photo-p1.jpg)"))
        XCTAssertTrue(md.contains("**Speaker 1** [1000ms]: hello"))
    }

    func testBackfillGeneratesOnlyMissingSummary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        store.appendTranscript(meetingId: "missing", segment: TranscriptSegment(speaker: "A", startMs: 0, endMs: 1, text: "Needs summary"))
        store.appendTranscript(meetingId: "existing", segment: TranscriptSegment(speaker: "B", startMs: 0, endMs: 1, text: "Keep summary"))
        let existingSummary = store.meetingDir("existing").appendingPathComponent("summary-Original-Detailed.md")
        try "existing summary".write(to: existingSummary, atomically: true, encoding: .utf8)
        _ = store.backfillMissingSummaries { _ in "generated" }
        _ = store.backfillMissingSummaries { _ in "replacement" }

        let meetings = Dictionary(uniqueKeysWithValues: store.listMeetings().map { ($0.id, $0) })
        XCTAssertEqual(meetings["missing"]?.summary, "generated")
        XCTAssertEqual(try String(contentsOf: existingSummary, encoding: .utf8), "existing summary")
    }

    func testBackfillMarksMissingSummaryAsNeedsAttention() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        store.appendTranscript(meetingId: "failed", segment: TranscriptSegment(speaker: "A", startMs: 0, endMs: 1, text: "Provider quota failed"))

        let result = store.backfillMissingSummaries(summarize: { _ in nil }, makeTitle: { _ in nil })

        XCTAssertEqual(result.attempted, 1)
        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(store.listMeetings().first?.processingState, .needsAttention)
    }

    func testBackfillRegeneratesWhenOnlyAnotherLanguageSummaryExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        store.appendTranscript(meetingId: "translated", segment: TranscriptSegment(speaker: "A", startMs: 0, endMs: 1, text: "Some talk"))
        let otherLanguage = store.meetingDir("translated").appendingPathComponent("summary-English-Short.md")
        try "old english short".write(to: otherLanguage, atomically: true, encoding: .utf8)

        let result = store.backfillMissingSummaries { _ in "fresh preferred" }

        XCTAssertEqual(result.completed, 1)
        let preferred = store.meetingDir("translated").appendingPathComponent("summary-Original-Detailed.md")
        XCTAssertEqual(try String(contentsOf: preferred, encoding: .utf8), "fresh preferred")
    }

    func testBackfillGivesGenericMeetingsARealTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let uuidId = UUID().uuidString  // UUID folder names display as "Live Meeting"
        store.appendTranscript(meetingId: uuidId, segment: TranscriptSegment(speaker: "A", startMs: 0, endMs: 1, text: "Planning the pilot"))

        _ = store.backfillMissingSummaries(summarize: { _ in "sum" }, makeTitle: { _ in " \"Pilot Planning\" " })

        let titles = store.listMeetings().map(\.title)
        XCTAssertEqual(titles, ["Pilot Planning"])
    }

    func testMergesAudioChunksIntoOneM4AWithoutDeletingSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let media = root.appendingPathComponent("meeting/media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let first = media.appendingPathComponent("001.wav")
        let second = media.appendingPathComponent("002.wav")
        try writeSilentWav(first)
        try writeSilentWav(second)
        store.appendTranscript(meetingId: "meeting", segment: TranscriptSegment(speaker: "A", startMs: 0, endMs: 100, text: "first"))
        store.appendTranscript(meetingId: "meeting", segment: TranscriptSegment(speaker: "B", startMs: 100, endMs: 200, text: "second"))
        let meeting = try XCTUnwrap(store.listMeetings().first)
        let completed = expectation(description: "recordings merged")
        var mergedURL: URL?
        var mergeError: Error?

        store.mergeRecordings(meeting) { result in
            switch result {
            case .success(let url): mergedURL = url
            case .failure(let error): mergeError = error
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)

        XCTAssertNil(mergeError)
        XCTAssertEqual(mergedURL?.lastPathComponent, "merged-recording.m4a")
        XCTAssertGreaterThan((try mergedURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))

        let refreshed = try XCTUnwrap(store.listMeetings().first)
        XCTAssertEqual(refreshed.audioFiles.count, 3)
        let replaced = expectation(description: "merged output replaced")
        store.mergeRecordings(refreshed) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            replaced.fulfill()
        }
        wait(for: [replaced], timeout: 5)
        XCTAssertEqual(store.listMeetings().first?.audioFiles.count, 3)

        let backfill = store.backfillMissingSummaries(force: true, summarize: { _ in "summary" }, makeTitle: { _ in nil })
        XCTAssertEqual(backfill.completed, 1)
        XCTAssertTrue(store.listMeetings().first?.transcript.contains("first") == true)
    }

    func testRecordingMergeRequiresTwoSourceChunks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let media = root.appendingPathComponent("meeting/media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try writeSilentWav(media.appendingPathComponent("only.wav"))
        let meeting = try XCTUnwrap(store.listMeetings().first)

        store.mergeRecordings(meeting) { result in
            guard case .failure(let error) = result else {
                XCTFail("Expected merge to fail")
                return
            }
            XCTAssertEqual(error as? MeetingRecordingMergeError, .insufficientRecordings)
        }
    }

    func testCompanyNameIsCaseInsensitiveAgainstExistingCluster() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: "secondBrain.root")
        }
        UserDefaults.standard.set(root.path, forKey: "secondBrain.root")
        let cluster = root.appendingPathComponent("work/sela/meetings/acme-corp")
        try FileManager.default.createDirectory(at: cluster, withIntermediateDirectories: true)
        try "# Acme Corp\n\nMeetings with Acme Corp.".write(to: cluster.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)

        let exporter = SecondBrainExporter()
        XCTAssertEqual(exporter.canonicalClientName("ACME corp"), "Acme Corp")
        XCTAssertEqual(exporter.canonicalClientName("acme-CORP"), "Acme Corp")
        XCTAssertEqual(exporter.canonicalClientName("New Client"), "New Client")
    }

    func testMergesMeetingsUsingChosenTitleAndDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        try writeMergeSource(root, name: "2026-01-05 09-00 - Kickoff", text: "first")
        try writeMergeSource(root, name: "2026-02-11 14-30 - Follow Up", text: "second")
        let records = store.listMeetings()
        XCTAssertEqual(records.count, 2)

        let chosen = Date(timeIntervalSince1970: 1_767_600_000)
        var steps: [String] = []
        let merged = try XCTUnwrap(store.mergeMeetings(
            records,
            options: MeetingMergeOptions(title: "Chosen Title", date: chosen),
            progress: { steps.append($0) }
        ))

        XCTAssertTrue(merged.lastPathComponent.hasSuffix(" - Chosen-Title"), merged.lastPathComponent)
        XCTAssertFalse(steps.isEmpty)
        let mergedRecord = try XCTUnwrap(store.listMeetings().first { $0.url.lastPathComponent == merged.lastPathComponent })
        XCTAssertEqual(mergedRecord.title, "Chosen Title")
        XCTAssertEqual(mergedRecord.date.timeIntervalSince1970, chosen.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(mergedRecord.transcript.contains("first"))
        XCTAssertTrue(mergedRecord.transcript.contains("second"))
        XCTAssertEqual(mergedRecord.audioCount, 2)
    }

    func testMeetingMergeRejectsEmptyTitleAndSingleMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        try writeMergeSource(root, name: "2026-01-05 09-00 - Kickoff", text: "first")
        try writeMergeSource(root, name: "2026-02-11 14-30 - Follow Up", text: "second")
        let records = store.listMeetings()

        XCTAssertNil(store.mergeMeetings(records, options: MeetingMergeOptions(title: "   ", date: Date())))
        XCTAssertNil(store.mergeMeetings(Array(records.prefix(1)), options: MeetingMergeOptions(title: "Solo", date: Date())))
    }

    func testMeetingChatPersistsSessionsAndUsesOnlyActiveConversationContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        store.appendTranscript(meetingId: "meeting", segment: TranscriptSegment(speaker: "A", startMs: 0, endMs: 1, text: "Transcript evidence"))
        try "## Summary\n\nSummary evidence\n\n## Transcript\n\n".write(to: store.meetingDir("meeting").appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let meeting = try XCTUnwrap(store.listMeetings().first)
        var userWasStored = false

        _ = try store.answerQuestion(meeting, question: "First question", onUserStored: { pending in
            let messages = pending.activeSession?.messages ?? []
            userWasStored = messages.count == 1 && messages[0].role == .user && messages[0].content == "First question"
        }, responder: { _, _, conversation in
            XCTAssertTrue(conversation.isEmpty)
            return "First answer"
        })
        XCTAssertTrue(userWasStored)

        _ = try store.answerQuestion(meeting, question: "Follow up", responder: { _, note, conversation in
            XCTAssertTrue(note.contains("Summary:\nSummary evidence"))
            XCTAssertTrue(note.contains("Transcript:\nA: Transcript evidence"))
            XCTAssertTrue(conversation.contains("You: First question"))
            XCTAssertTrue(conversation.contains("Assistant: First answer"))
            return "Second answer"
        })
        let secondSession = try store.startChatSession(meeting)
        XCTAssertEqual(secondSession.sessions.count, 2)
        _ = try store.answerQuestion(meeting, question: "Clean question", responder: { _, _, conversation in
            XCTAssertTrue(conversation.isEmpty)
            return "Clean answer"
        })

        let archive = try MeetingStore(root: root).chatArchive(for: meeting)
        XCTAssertEqual(archive.sessions.count, 2)
        XCTAssertEqual(archive.activeSession?.messages.map(\.content), ["Clean question", "Clean answer"])
        XCTAssertEqual(archive.sessions[0].messages.map(\.content), ["First question", "First answer", "Follow up", "Second answer"])
        XCTAssertEqual(archive.sessions[0].messages.map(\.role), [.user, .assistant, .user, .assistant])
        let markdown = try String(contentsOf: meeting.url.appendingPathComponent("questions.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Chat Session 1"))
        XCTAssertTrue(markdown.contains("### You\n\nFirst question"))
        XCTAssertTrue(markdown.contains("### Assistant\n\nClean answer"))
    }

    func testMeetingChatKeepsUserMessageWhenAIAnswerFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        store.appendTranscript(meetingId: "meeting", segment: TranscriptSegment(speaker: "A", startMs: 0, endMs: 1, text: "Transcript"))
        let meeting = try XCTUnwrap(store.listMeetings().first)

        XCTAssertThrowsError(try store.answerQuestion(meeting, question: "Submitted question", responder: { _, _, _ in nil })) {
            XCTAssertEqual($0 as? MeetingChatError, .aiUnavailable)
        }

        let archive = try MeetingStore(root: root).chatArchive(for: meeting)
        XCTAssertEqual(archive.activeSession?.messages.map(\.role), [.user])
        XCTAssertEqual(archive.activeSession?.messages.map(\.content), ["Submitted question"])
    }

    func testMeetingChatRejectsUnreadableLegacyArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        store.appendTranscript(meetingId: "meeting", segment: TranscriptSegment(speaker: "A", startMs: 0, endMs: 1, text: "Transcript"))
        let meeting = try XCTUnwrap(store.listMeetings().first)
        try FileManager.default.createDirectory(
            at: meeting.url.appendingPathComponent("questions.md", isDirectory: true),
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try store.chatArchive(for: meeting)) {
            XCTAssertEqual($0 as? MeetingChatError, .invalidArchive)
        }
    }

    func testMeetingChatImportsLegacyQuestionsWithoutLosingHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        store.appendTranscript(meetingId: "meeting", segment: TranscriptSegment(speaker: "A", startMs: 0, endMs: 1, text: "Transcript"))
        let meeting = try XCTUnwrap(store.listMeetings().first)
        let legacy = "## Q: What happened?\n\nThe launch was approved.\n\n## Q: Who owns it?\n\nJordan owns it.\n"
        try legacy.write(to: meeting.url.appendingPathComponent("questions.md"), atomically: true, encoding: .utf8)

        let imported = try store.chatArchive(for: meeting)
        XCTAssertEqual(imported.sessions.count, 1)
        XCTAssertEqual(imported.activeSession?.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(imported.activeSession?.messages.map(\.content), ["What happened?", "The launch was approved.", "Who owns it?", "Jordan owns it."])

        _ = try store.startChatSession(meeting)
        let reloaded = try MeetingStore(root: root).chatArchive(for: meeting)
        XCTAssertEqual(reloaded.sessions.count, 2)
        XCTAssertEqual(reloaded.sessions[0].messages, imported.sessions[0].messages)
        let markdown = try String(contentsOf: meeting.url.appendingPathComponent("questions.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("What happened?"))
        XCTAssertTrue(markdown.contains("Jordan owns it."))
    }
}

private func writeSilentWav(_ url: URL) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
    buffer.frameLength = 800
    try file.write(from: buffer)
}

final class PiInvocationTests: XCTestCase {
    func testPrintArgumentsDisableExtensionsAndTools() {
        let arguments = PiInvocation.arguments(model: "zai/glm-5.2", prompt: "hello")
        XCTAssertTrue(arguments.contains("--no-extensions"))
        XCTAssertTrue(arguments.contains("--no-tools"))
        XCTAssertFalse(arguments.contains("--skill"))
    }

    func testSecondBrainArgumentsLoadOnlySkillAndBash() {
        let arguments = PiInvocation.arguments(model: "zai/glm-5.2", prompt: "search", skillPath: "/tmp/second-brain")
        XCTAssertTrue(arguments.contains("--no-extensions"))
        XCTAssertTrue(arguments.contains("--no-skills"))
        XCTAssertTrue(arguments.contains("--skill"))
        XCTAssertTrue(arguments.contains("/tmp/second-brain"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--tools")! + 1], "bash")
        XCTAssertFalse(arguments.contains("--no-tools"))
    }
}

final class PiModelCatalogTests: XCTestCase {
    func testParsesProviderAndModelFromPiListModels() {
        let output = """
        provider      model                context  max-out  thinking  images
        openai-codex  gpt-5.4              272K     128K     yes       yes
        huggingface   openai/gpt-oss-120b  131.1K   32.8K    yes       no
        """
        XCTAssertEqual(PiModelCatalog.parse(output), ["openai-codex/gpt-5.4", "huggingface/openai/gpt-oss-120b"])
    }
}

final class SummaryRepairTests: XCTestCase {
    func testUnwrapsOllamaTerminalWrappedSummary() {
        // Real artifact shape: `ollama run` wrapped piped output at ~75 cols and
        // reprinted the cut word on the next line (ANSI erase codes already stripped).
        let corrupted = """
        # Incremental Meeting Summary

        ## Context
        The meeting appears to be an advanced technical review and development plan
        planning session focused on migrating complex AI functionality from older s
        systems/APIs to a new, stabilized production environment. Key concerns revo
        revolve around API reliability, response formatting consistency across mult
        multiple Large Language Models (LLMs), performance tuning, and ensuring dat
        data integrity during the transition.

        ## Topics Discussed
        *   **Response Formatting Layer:** The discussion heavily focused on the di
        difficulty of maintaining consistent output formatting from AI responses. A
        """
        let repaired = SummaryRepair.unwrap(corrupted)
        XCTAssertTrue(repaired.contains("development planning session"))
        XCTAssertFalse(repaired.contains("plan\nplanning"))
        XCTAssertTrue(repaired.contains("from older systems/APIs"))
        XCTAssertTrue(repaired.contains("concerns revolve around"))
        XCTAssertTrue(repaired.contains("across multiple Large Language Models"))
        XCTAssertTrue(repaired.contains("ensuring data integrity"))
        XCTAssertTrue(repaired.contains("focused on the difficulty of maintaining"))
        // Structure survives: headings stay on their own lines, bullets keep markers.
        XCTAssertTrue(repaired.contains("\n## Context\n"))
        XCTAssertTrue(repaired.contains("\n*   **Response Formatting Layer:**"))
    }

    func testUnwrapDropsFullWordReprintedAtWrap() {
        let corrupted = """
        comprehensive educational management system designed for students, covering
        covering both general education pathways and specialized programs. The disc
        discussion involves multiple stakeholder perspectives, including those relat
        related to individual schools and regional authorities.
        """
        let repaired = SummaryRepair.unwrap(corrupted)
        XCTAssertTrue(repaired.contains("students, covering both"))
        XCTAssertFalse(repaired.contains("covering covering"))
        XCTAssertTrue(repaired.contains("The discussion involves"))
        XCTAssertTrue(repaired.contains("those related to individual schools"))
    }

    func testCleanSummaryPassesThroughUntouched() {
        let clean = """
        # Meeting Summary

        A normal paragraph that was generated by the HTTP API and has no artificial wrapping at all, no matter how long the line gets.

        - First action item
        - Second action item
        """
        XCTAssertEqual(SummaryRepair.unwrap(clean), clean)
    }
}

final class SetupCatalogTests: XCTestCase {
    func testCatalogContainsEverySupportedDependencyOnce() {
        let support = URL(fileURLWithPath: "/tmp/android-bridge-setup")
        let requirements = URL(fileURLWithPath: "/tmp/requirements.txt")
        let dependencies = SetupCatalog.dependencies(applicationSupport: support, requirements: requirements)
        XCTAssertEqual(Set(dependencies.map(\.id)), Set(SetupDependencyID.allCases))
        XCTAssertEqual(dependencies.count, SetupDependencyID.allCases.count)
    }

    func testWhisperInstallUsesApplicationSupportAndBundledRequirements() {
        let support = URL(fileURLWithPath: "/tmp/android-bridge-setup")
        let requirements = URL(fileURLWithPath: "/Applications/AndroidBridge.app/requirements.txt")
        let whisper = SetupCatalog.dependencies(applicationSupport: support, requirements: requirements)
            .first { $0.id == .whisper }
        XCTAssertTrue(whisper?.installArguments.joined(separator: " ").contains(support.path) == true)
        XCTAssertTrue(whisper?.installArguments.joined(separator: " ").contains(requirements.path) == true)
    }

    func testEveryInstallCommandIsFixedAndNonempty() {
        let dependencies = SetupCatalog.dependencies(applicationSupport: URL(fileURLWithPath: "/tmp/support"), requirements: URL(fileURLWithPath: "/tmp/requirements"))
        XCTAssertTrue(dependencies.allSatisfy { $0.installProgram.hasPrefix("/") && !$0.installArguments.isEmpty })
    }

    func testDetectorRecognizesBundledWhisperEnvironment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let python = root.appendingPathComponent("Tools/mlx_whisper/.venv/bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: python.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let detector = SetupDetector(applicationSupport: root.appendingPathComponent("support"), bundledWhisperPython: python)
        XCTAssertEqual(detector.state(for: .whisper), .installed(python.path))
    }
}

final class MeetingCustomerAutomationTests: XCTestCase {
    func testCatalogDeduplicatesMeetingsBrainAndCreatedCustomers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = root.appendingPathComponent("customer-automation.json")
        let brain = root.appendingPathComponent("brain")
        defer { try? FileManager.default.removeItem(at: root) }
        let acme = brain.appendingPathComponent("work/sela/meetings/acme")
        try FileManager.default.createDirectory(at: acme, withIntermediateDirectories: true)
        try "# Acme".write(to: acme.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        let store = MeetingCustomerStore(dataURL: data, brainRootURL: brain)

        XCTAssertEqual(try store.addCustomer("  Beta Ltd  "), "Beta Ltd")
        XCTAssertEqual(try store.customers(meetingNames: ["ACME", "Gamma"]), ["Acme", "Beta Ltd", "Gamma"])
        XCTAssertEqual(try store.customers(meetingNames: ["beta ltd"]), ["Acme", "Beta Ltd"])
    }

    func testLearnedAssociationPersistsAndResolvesFutureEvent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = root.appendingPathComponent("customer-automation.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingCustomerStore(dataURL: data, brainRootURL: root.appendingPathComponent("brain"))
        let first = event(title: "Acme weekly", domains: ["acme.example"])
        try store.remember(event: first, customer: "Acme")
        let reloaded = MeetingCustomerStore(dataURL: data, brainRootURL: root.appendingPathComponent("brain"))
        let future = event(id: "future", title: "Acme Weekly", domains: ["acme.example"])

        XCTAssertEqual(
            MeetingCustomerMatcher.resolve(event: future, customers: ["Acme"], associations: try reloaded.associations()),
            "Acme"
        )
    }

    func testConflictingLearnedSignalsNeverAutoSelect() {
        let event = event(title: "Weekly sync", domains: ["shared.example"])
        let associations = [
            MeetingCustomerAssociation(customer: "Acme", calendarIdentifier: "work", eventTitle: "Weekly sync", externalDomains: ["shared.example"]),
            MeetingCustomerAssociation(customer: "Beta", calendarIdentifier: "other", eventTitle: "Another", externalDomains: ["shared.example"]),
        ]

        XCTAssertNil(MeetingCustomerMatcher.resolve(event: event, customers: ["Acme", "Beta"], associations: associations))
    }

    func testAssociationCanBeChangedAndForgotten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = root.appendingPathComponent("customer-automation.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingCustomerStore(dataURL: data, brainRootURL: root.appendingPathComponent("brain"))
        let calendarEvent = event(title: "Review", domains: ["review.example"])
        try store.remember(event: calendarEvent, customer: "Acme")
        let association = try XCTUnwrap(store.associations().first)

        try store.changeAssociation(id: association.id, customer: "Beta")
        XCTAssertEqual(try store.associations().first?.customer, "Beta")
        try store.forgetAssociation(id: association.id)
        XCTAssertTrue(try store.associations().isEmpty)
    }

    func testAssociationJSONRoundTripProperty() {
        property("PBT-02: learned customer associations survive persistence") <- forAll { (scenario: CustomerScenario) in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let data = root.appendingPathComponent("customer-automation.json")
            let event = self.event(title: scenario.eventTitle, domains: [scenario.domain])
            do {
                try MeetingCustomerStore(dataURL: data, brainRootURL: root).remember(event: event, customer: scenario.customer)
                let reloaded = MeetingCustomerStore(dataURL: data, brainRootURL: root)
                return MeetingCustomerMatcher.resolve(
                    event: event,
                    customers: [scenario.customer],
                    associations: try reloaded.associations()
                ) == scenario.customer
            } catch {
                return false
            }
        }
    }

    func testOldCalendarSnapshotWithoutCalendarIdentityStillDecodes() throws {
        let json = Data(#"{"id":"old","title":"Old event","start":0,"end":60,"calendarTitle":"Work","participants":[]}"#.utf8)
        let event = try JSONDecoder().decode(MeetingCalendarEvent.self, from: json)

        XCTAssertEqual(event.id, "old")
        XCTAssertNil(event.calendarIdentifier)
        XCTAssertNil(event.calendarSource)
    }

    private func event(id: String = "event", title: String, domains: [String]) -> MeetingCalendarEvent {
        MeetingCalendarEvent(
            id: id,
            title: title,
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200),
            calendarTitle: "Work",
            calendarIdentifier: "work",
            calendarSource: "Google",
            organizer: nil,
            participants: domains.map { MeetingCalendarParticipant(name: "Guest", email: "guest@\($0)", isCurrentUser: false) },
            meetingURL: nil,
            location: nil
        )
    }
}

final class MeetingCalendarTests: XCTestCase {
    private let meetingStart = Date(timeIntervalSince1970: 100)
    private let meetingEnd = Date(timeIntervalSince1970: 200)

    func testReturnsOnlyOverlappingEventsInDeterministicOrder() {
        let events = [
            event("late", start: 180, end: 240),
            event("before", start: 20, end: 100),
            event("closest", start: 110, end: 150),
            event("after", start: 200, end: 260),
        ]

        let matches = MeetingCalendarMatcher.overlapping(events, meetingStart: meetingStart, meetingEnd: meetingEnd)

        XCTAssertEqual(matches.map(\.id), ["closest", "late"])
    }

    func testToleranceIncludesOneNearBoundaryEventAndOrdersByActualOverlap() {
        let events = [
            event("near", start: 205, end: 240),
            event("full", start: 90, end: 210),
        ]

        let matches = MeetingCalendarMatcher.overlapping(events, meetingStart: meetingStart, meetingEnd: meetingEnd, tolerance: 15)

        XCTAssertEqual(matches.map(\.id), ["full", "near"])
    }

    func testSuggestsOneExternalCompanyAndRejectsAmbiguity() {
        let participants = [
            MeetingCalendarParticipant(name: "Me", email: "me@sela.co", isCurrentUser: true),
            MeetingCalendarParticipant(name: "A", email: "a@acme-corp.com", isCurrentUser: false),
            MeetingCalendarParticipant(name: "B", email: "b@acme-corp.com", isCurrentUser: false),
        ]
        XCTAssertEqual(MeetingCalendarMatcher.suggestedCustomer(from: participants), "Acme Corp")

        let ambiguous = participants + [MeetingCalendarParticipant(name: "C", email: "c@other.io", isCurrentUser: false)]
        XCTAssertNil(MeetingCalendarMatcher.suggestedCustomer(from: ambiguous))
    }

    func testIgnoresGenericEmailProviders() {
        let participants = [
            MeetingCalendarParticipant(name: "A", email: "a@gmail.com", isCurrentUser: false),
            MeetingCalendarParticipant(name: "B", email: "b@outlook.com", isCurrentUser: false),
        ]
        XCTAssertNil(MeetingCalendarMatcher.suggestedCustomer(from: participants))
    }

    func testPersistsStateAndRecoversInterruptedFinalization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        store.markStarted(meetingId: "m1", startedAtMs: 100_000)
        store.markEnded(meetingId: "m1", endedAtMs: 200_000)
        store.setProcessingState(meetingId: "m1", state: .finalizing)
        let original = try XCTUnwrap(store.listMeetings().first)
        let selectedEvent = event("selected", start: 110, end: 150)
        XCTAssertTrue(store.setCalendarEvent(selectedEvent, for: original))
        XCTAssertEqual(store.listMeetings().first?.processingState, .finalizing)
        XCTAssertEqual(store.listMeetings().first?.endDate, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.listMeetings().first?.calendarEvent, selectedEvent)

        store.recoverInterruptedProcessing()

        XCTAssertEqual(store.listMeetings().first?.processingState, .needsAttention)
    }

    func testOverlapMatchingInvariant() {
        property("PBT-03: calendar matches always overlap and ignore input order") <- forAll { (input: CalendarIntervals) in
            let events = input.values.enumerated().map { index, value in
                let start = Double(value % 300)
                let duration = Double(abs(value % 60) + 1)
                return self.event("e-\(index)", start: start, end: start + duration)
            }
            let tolerance: TimeInterval = 15
            let forward = MeetingCalendarMatcher.overlapping(events, meetingStart: self.meetingStart, meetingEnd: self.meetingEnd, tolerance: tolerance)
            let reverse = MeetingCalendarMatcher.overlapping(events.reversed(), meetingStart: self.meetingStart, meetingEnd: self.meetingEnd, tolerance: tolerance)
            return forward == reverse && forward.allSatisfy {
                $0.start < self.meetingEnd.addingTimeInterval(tolerance) && $0.end > self.meetingStart.addingTimeInterval(-tolerance)
            }
        }
    }

    private func event(_ id: String, start: TimeInterval, end: TimeInterval) -> MeetingCalendarEvent {
        MeetingCalendarEvent(
            id: id,
            title: id,
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end),
            calendarTitle: "Work",
            organizer: nil,
            participants: [],
            meetingURL: nil,
            location: nil
        )
    }
}

final class StreamPropertyTests: XCTestCase {
    func testChunkReassembleRoundTrip() {
        property("PBT-03: chunk then reassemble round-trips") <- forAll { (blob: Blob) in
            let frames = StreamChunker.chunk(streamId: 42, data: blob.data, chunkSize: 256)
            let reasm = StreamReassembler(streamId: 42)
            for f in frames { if !reasm.accept(f) { return false } }
            return reasm.complete && reasm.result() == blob.data
        }
    }
}

private func writeMergeSource(_ root: URL, name: String, text: String) throws {
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("media", isDirectory: true), withIntermediateDirectories: true)
    let segment = TranscriptSegment(speaker: "A", startMs: 0, endMs: 100, text: text)
    let line = String(decoding: try JSONEncoder().encode(segment), as: UTF8.self) + "\n"
    try line.write(to: dir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
    try writeSilentWav(dir.appendingPathComponent("media/chunk.wav"))
}
