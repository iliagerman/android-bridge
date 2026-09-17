import Foundation
import AVFoundation
import DeviceLinkProtocol

public struct TranscriptSegment: Codable, Equatable {
    public let speaker: String
    public let startMs: Int
    public let endMs: Int
    public let text: String
}

public struct MeetingPhoto: Codable, Equatable {
    public let photoId: String
    public let capturedAtMs: Int
    public let fileName: String
}

public enum MeetingRecordingMergeError: LocalizedError, Equatable {
    case insufficientRecordings
    case invalidRecording(String)
    case exportUnavailable
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .insufficientRecordings: return "At least two recording chunks are required."
        case .invalidRecording(let name): return "The recording \(name) is unreadable."
        case .exportUnavailable: return "A merged M4A recording cannot be created on this Mac."
        case .exportFailed: return "The merged recording could not be exported."
        }
    }
}

public struct MeetingRecord: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let company: String
    public let brainPath: String?
    public let url: URL
    public let notesURL: URL?
    public let date: Date
    public let audioFiles: [URL]
    public let imageFiles: [URL]
    public let audioCount: Int
    public let photoCount: Int
    public let transcript: String
    public let summary: String
    public let questions: String
    public let notesUpdatedAt: Date?
    public let isActive: Bool
    public let endDate: Date?
    public let processingState: MeetingProcessingState
    public let calendarEvent: MeetingCalendarEvent?
}

public enum MeetingChatRole: String, Codable, Equatable {
    case user
    case assistant
}

public struct MeetingChatMessage: Codable, Equatable, Identifiable {
    public let id: String
    public let role: MeetingChatRole
    public let content: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, role: MeetingChatRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct MeetingChatSession: Codable, Equatable, Identifiable {
    public let id: String
    public let createdAt: Date
    public var messages: [MeetingChatMessage]

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), messages: [MeetingChatMessage] = []) {
        self.id = id
        self.createdAt = createdAt
        self.messages = messages
    }
}

public struct MeetingChatArchive: Codable, Equatable {
    public var activeSessionId: String?
    public var sessions: [MeetingChatSession]

    public init(activeSessionId: String? = nil, sessions: [MeetingChatSession] = []) {
        self.activeSessionId = activeSessionId
        self.sessions = sessions
    }

    public static let empty = MeetingChatArchive()
    public var activeSession: MeetingChatSession? { sessions.first { $0.id == activeSessionId } }
}

public enum MeetingChatError: LocalizedError, Equatable {
    case invalidArchive
    case unknownSession
    case persistenceFailed
    case aiUnavailable
    case emptyQuestion

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The saved meeting chat archive is invalid."
        case .unknownSession: return "The selected chat session no longer exists."
        case .persistenceFailed: return "The meeting chat could not be saved."
        case .aiUnavailable: return "The chat AI did not return an answer."
        case .emptyQuestion: return "Enter a question before sending."
        }
    }
}

/// The title and date the user picked in the merge dialog for the combined meeting.
public struct MeetingMergeOptions: Equatable {
    public let title: String
    public let date: Date

    public init(title: String, date: Date) {
        self.title = title
        self.date = date
    }
}

public final class MeetingStore {
    /// Placeholder segment text written when a chunk was saved but Whisper failed.
    static let untranscribedMarker = "[Audio chunk saved for local transcription: "
    public var rootURL: URL { root }
    public static let shared = MeetingStore()
    private let fm = FileManager.default
    private let root: URL
    private let chatFileName = "chat.json"

    public init(root: URL? = nil) {
        let configured = UserDefaults.standard.string(forKey: "meetings.root")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let root {
            self.root = root
        } else if configured?.isEmpty == false {
            self.root = URL(fileURLWithPath: configured!)
        } else {
            let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            self.root = base.appendingPathComponent("AndroidBridgeMeetings", isDirectory: true)
        }
        try? fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func meetingDir(_ meetingId: String) -> URL {
        let dir = root.appendingPathComponent(safe(meetingId), isDirectory: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("media", isDirectory: true), withIntermediateDirectories: true)
        return dir
    }

    public func markStarted(meetingId: String, startedAtMs: Int) {
        let url = meetingDir(meetingId).appendingPathComponent("startedAt.txt")
        try? String(startedAtMs).write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    public func markEnded(meetingId: String, endedAtMs: Int) -> Bool {
        write(String(endedAtMs), to: meetingDir(meetingId).appendingPathComponent("endedAt.txt"))
    }

    @discardableResult
    public func setProcessingState(meetingId: String, state: MeetingProcessingState) -> Bool {
        setProcessingState(in: meetingDir(meetingId), state: state)
    }

    @discardableResult
    public func setProcessingState(in directory: URL, state: MeetingProcessingState) -> Bool {
        write(state.rawValue, to: directory.appendingPathComponent("processingState.txt"))
    }

    @discardableResult
    public func setCalendarEvent(_ event: MeetingCalendarEvent, for meeting: MeetingRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(event) else { return false }
        do {
            try data.write(to: meeting.url.appendingPathComponent("calendar-event.json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func clearCalendarEvent(for meeting: MeetingRecord) {
        try? fm.removeItem(at: meeting.url.appendingPathComponent("calendar-event.json"))
    }

    public func hasTitleOverride(_ meeting: MeetingRecord) -> Bool {
        fm.fileExists(atPath: meeting.url.appendingPathComponent("title.txt").path)
    }

    public func setTitleOverride(_ meeting: MeetingRecord, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard write(clean, to: meeting.url.appendingPathComponent("title.txt")) else { return }
        _ = writeNotes(in: meeting.url, meetingId: clean, photos: [], generateSummary: false)
    }

    /// Clears states that cannot survive a restart. `.finalizing` means a
    /// summary run died partway; `.recording` means a recorder was killed or
    /// stalled mid-meeting — nothing is capturing audio for it any more, so
    /// leaving it marked as recording strands it with a forever-ticking clock
    /// and a Stop button that does nothing.
    public func recoverInterruptedProcessing(activeIds: Set<String> = []) {
        let stranded: Set<MeetingProcessingState> = [.finalizing, .recording]
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for dir in dirs where dir.hasDirectoryPath
            && !activeIds.contains(dir.lastPathComponent)
            && stranded.contains(processingState(in: dir)) {
            _ = write(MeetingProcessingState.needsAttention.rawValue, to: dir.appendingPathComponent("processingState.txt"))
        }
    }

    public func saveAudio(meetingId: String, sequence: Int, data: Data) -> URL {
        let file = meetingDir(meetingId).appendingPathComponent("media", isDirectory: true).appendingPathComponent(String(format: "chunk-%04d.m4a", sequence))
        try? data.write(to: file)
        return file
    }

    public func savePhoto(meetingId: String, photoId: String, data: Data) -> URL {
        let destination = meetingDir(meetingId).appendingPathComponent("media", isDirectory: true).appendingPathComponent("photo-\(safe(photoId)).jpg")
        try? data.write(to: destination)
        return destination
    }

    public func appendTranscript(meetingId: String, segment: TranscriptSegment) {
        let url = meetingDir(meetingId).appendingPathComponent("transcript.jsonl")
        if let data = try? JSONEncoder().encode(segment), let line = String(data: data, encoding: .utf8)?.appending("\n") {
            if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close() }
            else { try? Data(line.utf8).write(to: url) }
        }
    }

    public func writeNotes(meetingId: String, photos: [MeetingPhoto] = []) -> URL {
        let dir = meetingDir(meetingId)
        let title = titleOverride(in: dir) ?? (UUID(uuidString: meetingId) == nil ? meetingId : "Live Meeting")
        return writeNotes(in: dir, meetingId: title, photos: photos, generateSummary: true)
    }

    public func writeNotesIncremental(meetingId: String, newSegments: [TranscriptSegment], photos: [MeetingPhoto] = []) -> URL {
        let dir = meetingDir(meetingId)
        let title = titleOverride(in: dir) ?? (UUID(uuidString: meetingId) == nil ? meetingId : "Live Meeting")
        return writeNotesIncremental(in: dir, meetingId: title, newSegments: newSegments, photos: photos)
    }

    public func finalizeMeeting(meetingId: String, photos: [MeetingPhoto] = []) -> URL {
        let dir = meetingDir(meetingId)
        let segments = readSegments(in: dir)
        let title = titleOverride(in: dir) ?? LLMService(feature: .summarize).title(segments.map(\.text).joined(separator: "\n")) ?? "Meeting"
        let stamp = DateFormatter.meetingFolder.string(from: Date())
        let destination = root.appendingPathComponent("\(stamp) - \(safe(title))", isDirectory: true)
        if destination != dir, !fm.fileExists(atPath: destination.path) {
            try? fm.moveItem(at: dir, to: destination)
            return writeNotes(in: destination, meetingId: title, photos: photos, generateSummary: true)
        }
        return writeNotes(in: dir, meetingId: title, photos: photos, generateSummary: true)
    }

    public func retryFinalization(_ meeting: MeetingRecord) -> URL {
        if UUID(uuidString: meeting.url.lastPathComponent) != nil {
            return finalizeMeeting(meetingId: meeting.id)
        }
        return writeNotes(in: meeting.url, meetingId: meeting.title, photos: [], generateSummary: true)
    }

    private func writeNotes(in dir: URL, meetingId: String, photos: [MeetingPhoto], generateSummary: Bool) -> URL {
        let segments = readSegments(in: dir)
        let transcriptText = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted(by: { $0.startMs < $1.startMs }).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let summary = currentSummary(in: dir) ?? (generateSummary && !transcriptText.isEmpty ? LLMService(feature: .summarize).summarize(transcriptText) : nil)
        return writeNotesFile(in: dir, meetingId: meetingId, segments: segments, photos: photos, summary: summary)
    }

    private func writeNotesIncremental(in dir: URL, meetingId: String, newSegments: [TranscriptSegment], photos: [MeetingPhoto]) -> URL {
        let segments = readSegments(in: dir)
        let delta = newSegments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let previous = currentSummary(in: dir)
        let summary = delta.isEmpty ? previous : LLMService(feature: .summarize).updateSummary(previous: previous, newTranscript: delta)
        return writeNotesFile(in: dir, meetingId: meetingId, segments: segments, photos: photos, summary: summary)
    }

    private func writeNotesFile(in dir: URL, meetingId: String, segments: [TranscriptSegment], photos: [MeetingPhoto], summary: String?) -> URL {
        if let summary { try? summary.write(to: summaryURL(in: dir), atomically: true, encoding: .utf8) }
        let markdown = NotesBuilder().build(meetingId: meetingId, segments: segments, photos: photos, summary: summary)
        let fileName = "\(safe(meetingId)).md"
        let url = dir.appendingPathComponent(fileName == ".md" ? "notes.md" : fileName)
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        if url.lastPathComponent != "notes.md" { try? markdown.write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8) }
        return url
    }

    public func listMeetings(activeIds: Set<String> = []) -> [MeetingRecord] {
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return dirs.filter { $0.hasDirectoryPath }.compactMap { record(for: $0, activeIds: activeIds) }
            .sorted { $0.date > $1.date }
    }

    public func deleteMeeting(_ meeting: MeetingRecord) {
        try? fm.removeItem(at: meeting.url)
    }

    public func trashMeeting(_ meeting: MeetingRecord) {
        try? fm.trashItem(at: meeting.url, resultingItemURL: nil)
    }

    public func hasReadableMeeting(at url: URL) -> Bool {
        record(for: url, activeIds: []) != nil
    }

    public func renameMeeting(_ meeting: MeetingRecord, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        try? clean.write(to: meeting.url.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)
        let dir: URL
        if UUID(uuidString: meeting.url.lastPathComponent) == nil {
            let prefix = DateFormatter.meetingFolder.string(from: meeting.date)
            let destination = root.appendingPathComponent("\(prefix) - \(safe(clean))", isDirectory: true)
            if destination != meeting.url, !fm.fileExists(atPath: destination.path) { try? fm.moveItem(at: meeting.url, to: destination) }
            dir = fm.fileExists(atPath: destination.path) ? destination : meeting.url
        } else {
            dir = meeting.url
        }
        _ = writeNotes(in: dir, meetingId: clean, photos: [], generateSummary: false)
    }

    public func setCompany(_ meeting: MeetingRecord, to company: String) {
        let clean = company.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = meeting.url.appendingPathComponent("company.txt")
        clean.isEmpty ? try? fm.removeItem(at: url) : try? clean.write(to: url, atomically: true, encoding: .utf8)
    }

    public func setBrainPath(_ meeting: MeetingRecord, to path: String) {
        try? path.write(to: meeting.url.appendingPathComponent("brainPath.txt"), atomically: true, encoding: .utf8)
    }

    /// Re-runs Whisper over every placeholder segment (chunks recorded while
    /// transcription was failing, e.g. ffmpeg missing from PATH) and rebuilds
    /// the summary and notes from the recovered text.
    public func retranscribeMeeting(_ meeting: MeetingRecord) {
        let whisper = WhisperTranscriptionService()
        let media = meeting.url.appendingPathComponent("media", isDirectory: true)
        let marker = Self.untranscribedMarker
        let existing = readSegments(in: meeting.url)
        let audioFiles = sourceAudioFiles(in: media)
        let segments: [TranscriptSegment]
        if existing.count < audioFiles.count {
            // The transcript doesn't even mention every recorded chunk (the
            // pipeline died mid-meeting) — rebuild it fresh from all audio.
            // Appending only "unknown" files here would duplicate the chunks
            // that real segments already cover, since those don't carry names.
            segments = audioFiles.enumerated().map { index, file in
                whisper.transcribe(file: file, startMs: index * 60_000, endMs: (index + 1) * 60_000, speaker: "Speaker 1")
            }
        } else {
            segments = existing.map { segment -> TranscriptSegment in
                guard segment.text.hasPrefix(marker), segment.text.hasSuffix("]") else { return segment }
                let name = String(segment.text.dropFirst(marker.count).dropLast())
                let file = media.appendingPathComponent(name)
                guard fm.fileExists(atPath: file.path) else { return segment }
                return whisper.transcribe(file: file, startMs: segment.startMs, endMs: segment.endMs, speaker: segment.speaker)
            }
        }
        let transcriptURL = meeting.url.appendingPathComponent("transcript.jsonl")
        let body = segments.compactMap { segment -> String? in
            guard let data = try? JSONEncoder().encode(segment) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        try? (body + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        // Drop cached summaries and summarize from scratch: writeNotes' usual
        // notes.md fallback would resurrect the stale placeholder-era summary.
        if let files = try? fm.contentsOfDirectory(at: meeting.url, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("summary") && file.pathExtension == "md" {
                try? fm.removeItem(at: file)
            }
        }
        let transcriptText = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.text.hasPrefix(marker) }
            .sorted(by: { $0.startMs < $1.startMs }).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let summary = transcriptText.isEmpty ? nil : LLMService(feature: .summarize).summarize(transcriptText)
        _ = writeNotesFile(in: meeting.url, meetingId: meeting.title, segments: segments, photos: [], summary: summary)
    }

    public func regenerateSummary(_ meeting: MeetingRecord) {
        let segments = readSegments(in: meeting.url)
        let transcriptText = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted(by: { $0.startMs < $1.startMs }).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let summary = transcriptText.isEmpty ? nil : LLMService(feature: .summarize).summarize(transcriptText)
        _ = writeNotesFile(in: meeting.url, meetingId: meeting.title, segments: segments, photos: [], summary: summary)
    }

    /// A summary counts as missing when there is no summary file for the
    /// currently selected language/type — so switching the summary language or
    /// type makes backfill regenerate every meeting for the new preference.
    /// Meetings whose audio was recorded but never transcribed (placeholder
    /// segments, or no transcript at all) are re-transcribed first.
    @discardableResult
    public func backfillMissingSummaries(
        force: Bool = false,
        summarize: (String) -> String? = { LLMService(feature: .summarize).summarize($0) },
        makeTitle: (String) -> String? = { LLMService(feature: .summarize).title($0) },
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) -> (attempted: Int, completed: Int) {
        let missing = listMeetings().filter { force || readSummary(summaryURL(in: $0.url)) == nil }
        var attempted = 0
        var completed = 0
        for (index, meeting) in missing.enumerated() {
            onProgress(index + 1, missing.count)
            let segments = readSegments(in: meeting.url)
            let transcript = usableTranscript(segments)
            // Transcript with fewer entries than recorded chunks (or placeholder
            // entries) means Whisper never covered the meeting — re-transcribe.
            let sourceAudio = sourceAudioFiles(in: meeting.url.appendingPathComponent("media", isDirectory: true))
            let needsTranscription = segments.count < sourceAudio.count
                || segments.contains { $0.text.hasPrefix(Self.untranscribedMarker) }
            if needsTranscription, !sourceAudio.isEmpty {
                attempted += 1
                retranscribeMeeting(meeting)
                let succeeded = readSummary(summaryURL(in: meeting.url)) != nil
                setProcessingState(in: meeting.url, state: succeeded ? .ready : .needsAttention)
                if succeeded { completed += 1 }
            } else if !transcript.isEmpty {
                attempted += 1
                guard let summary = summarize(transcript) else {
                    setProcessingState(in: meeting.url, state: .needsAttention)
                    continue
                }
                _ = writeNotesFile(in: meeting.url, meetingId: meeting.title, segments: segments, photos: [], summary: summary)
                setProcessingState(in: meeting.url, state: .ready)
                completed += 1
            } else {
                continue
            }
        }
        // Title pass over ALL meetings (not just the ones missing a summary):
        // anything still called "Live Meeting"/"Meeting" gets a generated title.
        for meeting in listMeetings() {
            backfillTitle(meeting, makeTitle: makeTitle)
        }
        return (attempted, completed)
    }

    /// Gives generic "Live Meeting"/"Meeting" entries a real LLM-generated title.
    private func backfillTitle(_ meeting: MeetingRecord, makeTitle: (String) -> String?) {
        guard meeting.title == "Live Meeting" || meeting.title == "Meeting" else { return }
        let transcript = usableTranscript(readSegments(in: meeting.url))
        guard !transcript.isEmpty else { return }
        let title = makeTitle(transcript)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        guard let title, !title.isEmpty else { return }
        renameMeeting(meeting, to: title)
    }

    private func usableTranscript(_ segments: [TranscriptSegment]) -> String {
        segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.text.hasPrefix(Self.untranscribedMarker) }
            .sorted { $0.startMs < $1.startMs }
            .map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    private func chatNoteContext(_ meeting: MeetingRecord) -> String {
        let summary = meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = usableTranscript(readSegments(in: meeting.url))
        var sections: [String] = []
        if !summary.isEmpty { sections.append("Summary:\n\(summary)") }
        if !transcript.isEmpty { sections.append("Transcript:\n\(transcript)") }
        return sections.joined(separator: "\n\n")
    }

    public func renameSpeaker(_ meeting: MeetingRecord, from oldName: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldName.isEmpty, !clean.isEmpty else { return }
        let segments = readSegments(in: meeting.url).map { segment in
            TranscriptSegment(speaker: segment.speaker == oldName ? clean : segment.speaker, startMs: segment.startMs, endMs: segment.endMs, text: segment.text)
        }
        let transcriptURL = meeting.url.appendingPathComponent("transcript.jsonl")
        let body = segments.compactMap { segment -> String? in
            guard let data = try? JSONEncoder().encode(segment) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        try? (body + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        _ = writeNotes(in: meeting.url, meetingId: meeting.title, photos: [], generateSummary: false)
    }

    public func chatArchive(for meeting: MeetingRecord) throws -> MeetingChatArchive {
        let url = meeting.url.appendingPathComponent(chatFileName)
        guard fm.fileExists(atPath: url.path) else { return try legacyChatArchive(for: meeting) }
        do {
            return try JSONDecoder().decode(MeetingChatArchive.self, from: Data(contentsOf: url))
        } catch {
            throw MeetingChatError.invalidArchive
        }
    }

    @discardableResult
    public func startChatSession(_ meeting: MeetingRecord) throws -> MeetingChatArchive {
        var archive = try chatArchive(for: meeting)
        let session = MeetingChatSession()
        archive.sessions.append(session)
        archive.activeSessionId = session.id
        try saveChatArchive(archive, for: meeting)
        return archive
    }

    @discardableResult
    public func selectChatSession(_ meeting: MeetingRecord, sessionId: String) throws -> MeetingChatArchive {
        var archive = try chatArchive(for: meeting)
        guard archive.sessions.contains(where: { $0.id == sessionId }) else { throw MeetingChatError.unknownSession }
        archive.activeSessionId = sessionId
        try saveChatArchive(archive, for: meeting, writeMarkdown: false)
        return archive
    }

    public func answerQuestion(
        _ meeting: MeetingRecord,
        question: String,
        onUserStored: (MeetingChatArchive) -> Void = { _ in },
        responder: (String, String, String) -> String? = { question, note, conversation in
            LLMService(feature: .chat).answer(question: question, note: note, conversation: conversation)
        }
    ) throws -> MeetingChatArchive {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw MeetingChatError.emptyQuestion }
        var archive = try chatArchive(for: meeting)
        if archive.activeSession == nil {
            let session = MeetingChatSession()
            archive.sessions.append(session)
            archive.activeSessionId = session.id
        }
        guard let index = archive.sessions.firstIndex(where: { $0.id == archive.activeSessionId }) else {
            throw MeetingChatError.unknownSession
        }
        let conversation = conversationText(archive.sessions[index].messages)
        archive.sessions[index].messages.append(MeetingChatMessage(role: .user, content: clean))
        try saveChatArchive(archive, for: meeting)
        onUserStored(archive)
        let note = chatNoteContext(meeting)
        guard let answer = responder(clean, note, conversation)?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
            throw MeetingChatError.aiUnavailable
        }
        archive.sessions[index].messages.append(MeetingChatMessage(role: .assistant, content: answer))
        try saveChatArchive(archive, for: meeting)
        return archive
    }

    private func legacyChatArchive(for meeting: MeetingRecord) throws -> MeetingChatArchive {
        let url = meeting.url.appendingPathComponent("questions.md")
        guard fm.fileExists(atPath: url.path) else { return .empty }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MeetingChatError.invalidArchive
        }
        let parts = text.components(separatedBy: "## Q: ").dropFirst()
        var messages: [MeetingChatMessage] = []
        for (index, part) in parts.enumerated() {
            let pieces = part.components(separatedBy: "\n\n")
            let question = (pieces.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = pieces.dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let time = Date(timeIntervalSince1970: TimeInterval(index * 2))
            if !question.isEmpty { messages.append(MeetingChatMessage(id: "legacy-user-\(index)", role: .user, content: question, createdAt: time)) }
            if !answer.isEmpty { messages.append(MeetingChatMessage(id: "legacy-assistant-\(index)", role: .assistant, content: answer, createdAt: time.addingTimeInterval(1))) }
        }
        guard !messages.isEmpty else { return .empty }
        let session = MeetingChatSession(id: "legacy", createdAt: .distantPast, messages: messages)
        return MeetingChatArchive(activeSessionId: session.id, sessions: [session])
    }

    private func saveChatArchive(_ archive: MeetingChatArchive, for meeting: MeetingRecord, writeMarkdown: Bool = true) throws {
        do {
            let chatURL = meeting.url.appendingPathComponent(chatFileName)
            try JSONEncoder().encode(archive).write(to: chatURL, options: .atomic)
            if writeMarkdown {
                try chatMarkdown(archive).write(to: meeting.url.appendingPathComponent("questions.md"), atomically: true, encoding: .utf8)
            }
        } catch {
            throw MeetingChatError.persistenceFailed
        }
    }

    private func chatMarkdown(_ archive: MeetingChatArchive) -> String {
        archive.sessions.enumerated().map { index, session in
            let messages = session.messages.map { message in
                let heading = message.role == .user ? "You" : "Assistant"
                return "### \(heading)\n\n\(message.content)"
            }.joined(separator: "\n\n")
            return "## Chat Session \(index + 1)\n\n\(messages)"
        }.joined(separator: "\n\n") + (archive.sessions.isEmpty ? "" : "\n")
    }

    private func conversationText(_ messages: [MeetingChatMessage]) -> String {
        messages.map { "\($0.role == .user ? "You" : "Assistant"): \($0.content)" }.joined(separator: "\n\n")
    }

    public func mergeRecordings(
        _ meeting: MeetingRecord,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let sources = sourceAudioFiles(in: meeting.url.appendingPathComponent("media", isDirectory: true))
        guard sources.count >= 2 else {
            completion(.failure(MeetingRecordingMergeError.insufficientRecordings))
            return
        }
        do {
            let composition = try audioComposition(sources)
            let staged = meeting.url.appendingPathComponent(".merged-recording-\(UUID().uuidString).m4a")
            let destination = meeting.url.appendingPathComponent("media/merged-recording.m4a")
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                throw MeetingRecordingMergeError.exportUnavailable
            }
            exporter.outputURL = staged
            exporter.outputFileType = .m4a
            exporter.exportAsynchronously { [fm] in
                do {
                    guard exporter.status == .completed else {
                        throw exporter.error ?? MeetingRecordingMergeError.exportFailed
                    }
                    try Self.installMergedRecording(staged, at: destination, fileManager: fm)
                    completion(.success(destination))
                } catch {
                    try? fm.removeItem(at: staged)
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func sourceAudioFiles(in media: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)) ?? [])
            .filter {
                ["m4a", "3gp", "wav"].contains($0.pathExtension.lowercased())
                    && $0.lastPathComponent != "merged-recording.m4a"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func audioComposition(_ sources: [URL]) throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw MeetingRecordingMergeError.exportUnavailable }
        var cursor = CMTime.zero
        for source in sources {
            let asset = AVURLAsset(url: source)
            guard let track = asset.tracks(withMediaType: .audio).first else {
                throw MeetingRecordingMergeError.invalidRecording(source.lastPathComponent)
            }
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: track, at: cursor)
            cursor = CMTimeAdd(cursor, asset.duration)
        }
        return composition
    }

    private static func installMergedRecording(_ staged: URL, at destination: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    /// Combines several meetings into one folder using the title and date the user chose.
    /// `progress` reports each step so the UI can show what is happening; the AI summary at
    /// the end is the slow part and can take minutes on a local model.
    public func mergeMeetings(
        _ records: [MeetingRecord],
        options: MeetingMergeOptions,
        progress: (String) -> Void = { _ in }
    ) -> URL? {
        let title = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard records.count >= 2, !title.isEmpty else { return nil }
        let id = "\(DateFormatter.meetingFolder.string(from: options.date)) - \(safe(title))"
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let media = dir.appendingPathComponent("media", isDirectory: true)
        try? fm.createDirectory(at: media, withIntermediateDirectories: true)
        var transcript = ""
        for (index, record) in records.enumerated() {
            progress("Copying files from \(record.title) (\(index + 1)/\(records.count))…")
            let sourceMedia = record.url.appendingPathComponent("media", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(at: sourceMedia, includingPropertiesForKeys: nil)) ?? []
            for file in files { try? fm.copyItem(at: file, to: media.appendingPathComponent("\(safe(record.title))-\(file.lastPathComponent)")) }
            transcript += (try? String(contentsOf: record.url.appendingPathComponent("transcript.jsonl"), encoding: .utf8)) ?? ""
        }
        progress("Combining transcripts…")
        try? transcript.write(to: dir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
        _ = write(title, to: dir.appendingPathComponent("title.txt"))
        _ = write(String(Int(options.date.timeIntervalSince1970 * 1000)), to: dir.appendingPathComponent("startedAt.txt"))
        progress("Writing the combined summary with AI — this can take a few minutes…")
        _ = writeNotes(in: dir, meetingId: title, photos: [], generateSummary: true)
        return dir
    }

    private func record(for dir: URL, activeIds: Set<String>) -> MeetingRecord? {
        let media = dir.appendingPathComponent("media", isDirectory: true)
        let mediaFiles = (try? fm.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)) ?? []
        let notes = dir.appendingPathComponent("notes.md")
        let segments = readSegments(in: dir)
        let transcript = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { "\($0.speaker) [\($0.startMs)ms]: \($0.text)" }.joined(separator: "\n")
        let summary = currentSummary(in: dir) ?? ""
        let audioFiles = mediaFiles.filter { ["m4a", "3gp", "wav"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let imageFiles = mediaFiles.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let date = startedDate(in: dir) ?? parsedDate(from: dir.lastPathComponent) ?? ((try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        let notesUpdatedAt = (try? notes.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let title = titleOverride(in: dir) ?? displayTitle(dir.lastPathComponent)
        let savedBrainPath = brainPath(in: dir)
        let brain = savedBrainPath == nil ? inferredBrainTransfer(title: title, date: date) : nil
        if let brain { try? brain.path.write(to: dir.appendingPathComponent("brainPath.txt"), atomically: true, encoding: String.Encoding.utf8) }
        if companyOverride(in: dir) == nil, let brain { try? brain.company.write(to: dir.appendingPathComponent("company.txt"), atomically: true, encoding: String.Encoding.utf8) }
        return MeetingRecord(
            id: dir.lastPathComponent,
            title: title,
            company: companyOverride(in: dir) ?? brain?.company ?? "",
            brainPath: savedBrainPath ?? brain?.path,
            url: dir,
            notesURL: fm.fileExists(atPath: notes.path) ? notes : nil,
            date: date,
            audioFiles: audioFiles,
            imageFiles: imageFiles,
            audioCount: audioFiles.count,
            photoCount: imageFiles.count,
            transcript: transcript,
            summary: summary,
            questions: (try? String(contentsOf: dir.appendingPathComponent("questions.md"), encoding: .utf8)) ?? "",
            notesUpdatedAt: notesUpdatedAt,
            isActive: activeIds.contains(dir.lastPathComponent),
            endDate: endedDate(in: dir),
            processingState: activeIds.contains(dir.lastPathComponent) ? .recording : processingState(in: dir),
            calendarEvent: calendarEvent(in: dir)
        )
    }

    private func readSegments(in dir: URL) -> [TranscriptSegment] {
        let transcriptURL = dir.appendingPathComponent("transcript.jsonl")
        let lines = (try? String(contentsOf: transcriptURL, encoding: .utf8).split(separator: "\n").map(String.init)) ?? []
        return lines.compactMap { try? JSONDecoder().decode(TranscriptSegment.self, from: Data($0.utf8)) }
    }

    private func currentSummary(in dir: URL, allowNotesFallback: Bool = true) -> String? {
        let preferred = summaryURL(in: dir)
        if let cached = readSummary(preferred) { return cached }
        let summaries = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("summary-") && $0.pathExtension == "md" && $0 != preferred }
            .sorted { a, b in
                if a.lastPathComponent == "summary-English-Detailed.md" { return true }
                if b.lastPathComponent == "summary-English-Detailed.md" { return false }
                let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ad > bd
            }
        for url in summaries {
            if let summary = readSummary(url) { return summary }
        }
        guard allowNotesFallback else { return nil }
        let notes = dir.appendingPathComponent("notes.md")
        let text = (try? String(contentsOf: notes, encoding: .utf8)) ?? ""
        let summary = extractSummary(fromNotes: text)
        guard let summary, !summary.isEmpty, !summary.contains("Live transcript is updating") else { return nil }
        return SummaryRepair.unwrap(summary)
    }

    private func readSummary(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return SummaryRepair.unwrap(text)
    }

    private func extractSummary(fromNotes text: String) -> String? {
        let beforeTranscript = text.components(separatedBy: "## Transcript").first ?? text
        let markers = ["## Summary", "# Summary", "### Summary", "Summary"]
        for marker in markers {
            guard let range = beforeTranscript.range(of: marker) else { continue }
            return String(beforeTranscript[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func summaryURL(in dir: URL) -> URL {
        let language = UserDefaults.standard.string(forKey: "summaryLanguage") ?? "Original"
        let type = UserDefaults.standard.string(forKey: "summaryType") ?? "Detailed"
        return dir.appendingPathComponent("summary-\(safe(language))-\(safe(type)).md")
    }

    private func titleOverride(in dir: URL) -> String? {
        let raw = try? String(contentsOf: dir.appendingPathComponent("title.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }

    private func companyOverride(in dir: URL) -> String? {
        let raw = try? String(contentsOf: dir.appendingPathComponent("company.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }

    private func brainPath(in dir: URL) -> String? {
        let raw = try? String(contentsOf: dir.appendingPathComponent("brainPath.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }

    private var brainNoteStamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    private func inferredBrainTransfer(title: String, date: Date) -> (company: String, path: String)? {
        let home = fm.homeDirectoryForCurrentUser
        let configured = UserDefaults.standard.string(forKey: "secondBrain.root")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let env = ProcessInfo.processInfo.environment["BRAIN_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let brainRoot = URL(fileURLWithPath: configured?.isEmpty == false ? configured! : (env?.isEmpty == false ? env! : home.appendingPathComponent("second_brain").path))
        let meetingRoots = ["work/sela/meetings", "work/meetings"].map {
            brainRoot.appendingPathComponent($0, isDirectory: true)
        }
        let stamp = brainNoteStamp.string(from: date)
        let files = meetingRoots.flatMap {
            fm.enumerator(at: $0, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        }
        for file in files where file.pathExtension == "md" && file.lastPathComponent != "index.md" {
            let rel = String(file.path.dropFirst(brainRoot.path.count + 1))
            let parts = rel.split(separator: "/")
            guard parts.count >= 4, let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if text.contains(stamp), text.contains(title) {
                let line = text.components(separatedBy: "\n").first { $0.hasPrefix("Meeting with ") }
                let company = line.map { String(String($0.dropFirst("Meeting with ".count)).components(separatedBy: ", captured").first ?? "") }
                return (company ?? String(parts[parts.count - 2]), rel)
            }
        }
        return nil
    }

    private func startedDate(in dir: URL) -> Date? {
        dateFromMillisecondsFile(dir.appendingPathComponent("startedAt.txt"))
    }

    private func endedDate(in dir: URL) -> Date? {
        dateFromMillisecondsFile(dir.appendingPathComponent("endedAt.txt"))
    }

    private func dateFromMillisecondsFile(_ url: URL) -> Date? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), let ms = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private func processingState(in dir: URL) -> MeetingProcessingState {
        let raw = try? String(contentsOf: dir.appendingPathComponent("processingState.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.flatMap(MeetingProcessingState.init(rawValue:)) ?? .ready
    }

    private func calendarEvent(in dir: URL) -> MeetingCalendarEvent? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("calendar-event.json")) else { return nil }
        return try? JSONDecoder().decode(MeetingCalendarEvent.self, from: data)
    }

    @discardableResult
    private func write(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func parsedDate(from name: String) -> Date? {
        guard name.count >= 16 else { return nil }
        return DateFormatter.meetingFolder.date(from: String(name.prefix(16)))
    }

    private func displayTitle(_ name: String) -> String {
        if UUID(uuidString: name) != nil { return "Live Meeting" }
        guard name.count > 19, parsedDate(from: name) != nil else { return name }
        return String(name.dropFirst(19)).replacingOccurrences(of: "-", with: " ")
    }

    private func safe(_ s: String) -> String {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = String(cleaned.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == " ") ? $0 : "-" })
        return mapped.replacingOccurrences(of: "  ", with: " ").replacingOccurrences(of: " ", with: "-")
    }
}

/// Repairs summaries produced by the old `ollama run` CLI pipeline, which word-wrapped
/// piped output at terminal width (~75 cols): a word cut at the margin was erased with
/// ANSI codes and reprinted on the next line. Stripping the ANSI codes left hard line
/// breaks plus the duplicated fragment ("…a comprehens\ncomprehensive…"). This unwraps
/// those paragraphs and drops the duplicate fragments. Clean text passes through untouched.
public enum SummaryRepair {
    public static func unwrap(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard overlapPairCount(lines) >= 2 else { return text }
        var out: [String] = []
        var current: String?
        func flush() {
            if let line = current { out.append(line) }
            current = nil
        }
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                out.append("")
            } else if line.hasPrefix("#") || line.hasPrefix("|") {
                // Headings and table rows are single-line; never absorb continuations.
                flush()
                out.append(line)
            } else if startsBlock(line) {
                flush()
                current = line
            } else if let acc = current {
                current = join(acc, line)
            } else {
                current = line
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    // Runs only on documents already detected as wrap-corrupted, so a trailing word
    // that prefixes the next line's first word is treated as the cut fragment even
    // when it is a single character ("…older s" / "systems/APIs…").
    private static func join(_ acc: String, _ next: String) -> String {
        if let last = acc.split(separator: " ").last.map(String.init),
           let first = next.split(separator: " ").first.map(String.init),
           first.hasPrefix(last) {
            let trimmedAcc = String(acc.dropLast(last.count)).trimmingCharacters(in: .whitespaces)
            return trimmedAcc.isEmpty ? next : "\(trimmedAcc) \(next)"
        }
        return "\(acc) \(next)"
    }

    private static func overlapPairCount(_ lines: [String]) -> Int {
        var count = 0
        for (line, next) in zip(lines, lines.dropFirst()) {
            guard line.count >= 55,
                  let last = line.split(separator: " ").last.map(String.init),
                  let first = next.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init),
                  last.count >= 2, first.hasPrefix(last)
            else { continue }
            count += 1
        }
        return count
    }

    private static func startsBlock(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") || line.hasPrefix("|") || line.hasPrefix(">") { return true }
        if let dot = line.firstIndex(of: "."), dot != line.startIndex, line[..<dot].allSatisfy({ $0.isNumber }) { return true }
        return false
    }
}

public struct NotesBuilder {
    public init() {}
    public func build(meetingId: String, segments: [TranscriptSegment], photos: [MeetingPhoto], summary: String? = nil) -> String {
        let summary = summary ?? "Live transcript is updating. Final summary is created when the meeting stops."
        var out = "# Meeting \(meetingId)\n\n## Summary\n\n\(summary)\n\n## Transcript\n\n"
        let sortedPhotos = photos.sorted { $0.capturedAtMs < $1.capturedAtMs }
        var used = Set<String>()
        for s in segments.filter({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).sorted(by: { $0.startMs < $1.startMs }) {
            for p in sortedPhotos where !used.contains(p.photoId) && p.capturedAtMs <= s.startMs {
                out += "![Photo at \(p.capturedAtMs)ms](media/\(p.fileName))\n\n"
                used.insert(p.photoId)
            }
            out += "**\(s.speaker)** [\(s.startMs)ms]: \(s.text)\n\n"
        }
        for p in sortedPhotos where !used.contains(p.photoId) {
            out += "![Photo at \(p.capturedAtMs)ms](media/\(p.fileName))\n\n"
        }
        return out
    }
}

public enum LLMFeature: String, CaseIterable, Identifiable {
    case summarize = "Summarize"
    case chat = "Chat"
    case secondBrainSearch = "Second Brain Search"
    case secondBrainQA = "Second Brain Q&A"
    case secondBrainCRUD = "Second Brain CRUD"

    public var id: String { rawValue }
    public var key: String { rawValue.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "&", with: "And") }
}

public enum PiInvocation {
    public static func arguments(model: String, prompt: String, skillPath: String? = nil) -> [String] {
        var arguments = ["--print", "--no-session", "--no-extensions", "--no-skills"]
        if let skillPath {
            arguments += ["--tools", "bash", "--skill", skillPath]
        } else {
            arguments.append("--no-tools")
        }
        return arguments + ["--model", model, prompt]
    }
}

public enum PiModelCatalogError: LocalizedError {
    case commandFailed(String)
    case noModels

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        case .noModels: return "pi returned no available models"
        }
    }
}

public enum PiModelCatalog {
    public static func parse(_ output: String) -> [String] {
        output.components(separatedBy: .newlines).dropFirst().compactMap { line in
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard columns.count >= 2 else { return nil }
            return "\(columns[0])/\(columns[1])"
        }
    }

    public static func load(executable: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.environment = environmentWithHomebrewPath()
        process.arguments = [executable, "--list-models"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PiModelCatalogError.commandFailed(message?.isEmpty == false ? message! : "pi --list-models failed")
        }
        let models = parse(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        guard !models.isEmpty else { throw PiModelCatalogError.noModels }
        return models
    }
}

public struct LLMConfig {
    public let usePi: Bool
    public let model: String

    public static func config(for feature: LLMFeature) -> LLMConfig {
        let defaults = UserDefaults.standard
        let key = feature.key
        return LLMConfig(
            usePi: defaults.bool(forKey: "llm.\(key).usePi"),
            model: defaults.string(forKey: "llm.\(key).model") ?? "gemma4:e4b"
        )
    }
}

public struct LLMService {
    public let feature: LLMFeature
    public init(feature: LLMFeature) { self.feature = feature }

    public func summarize(_ transcript: String) -> String? {
        let language = UserDefaults.standard.string(forKey: "summaryLanguage") ?? "Original"
        let summaryType = UserDefaults.standard.string(forKey: "summaryType") ?? "Detailed"
        let languageInstruction = language == "Original"
            ? "Write the summary in the original language of the transcript. If the transcript is mixed-language, use the dominant language."
            : "Write the summary in \(language)."
        let typeInstruction = summaryType == "Short"
            ? "Write a compact executive summary with Markdown headings for Decisions, Blockers, and Action Items only. Bullet points only, max 15 words per bullet."
            : "Write a clear concise meeting summary, not a transcript rewrite. Focus on confirmed technical/business content. Ignore garbled speech, incidental navigation, UI clicking, repeated phrases, and uncertain fragments unless they affect an action item. Use these Markdown headings only: ## Summary, ## Decisions, ## Action Items, ## Open Questions/Risks. Under every heading write short '- ' bullet points only — never paragraphs. Max 18 words per bullet, at most 8 bullets under Summary and 6 under each other heading. Do not invent context. If something is unclear, put it under Open Questions/Risks instead of expanding it."
        return run("Summarize the meeting transcript so far. \(languageInstruction) \(typeInstruction) Return clean Markdown only. No code fences. No thinking.\n\nTranscript:\n\(transcript)", feature: feature)
    }

    public func updateSummary(previous: String?, newTranscript: String) -> String? {
        let language = UserDefaults.standard.string(forKey: "summaryLanguage") ?? "Original"
        let summaryType = UserDefaults.standard.string(forKey: "summaryType") ?? "Detailed"
        let languageInstruction = language == "Original"
            ? "Keep the summary in the original/dominant transcript language."
            : "Write the summary in \(language)."
        let typeInstruction = summaryType == "Short"
            ? "Keep it short with Markdown headings for Decisions, Blockers, and Action Items only. Bullet points only, max 15 words per bullet."
            : "Keep the summary clear and concise. Preserve confirmed decisions and action items, add only important new information, and remove noise/repetition. Ignore garbled speech, incidental navigation, UI clicking, and uncertain fragments unless they affect an action item. Use Markdown headings: ## Summary, ## Decisions, ## Action Items, ## Open Questions/Risks. Under every heading write short '- ' bullet points only — never paragraphs. Max 18 words per bullet, at most 8 bullets under Summary and 6 under each other heading."
        return run("Update this meeting summary incrementally. \(languageInstruction) \(typeInstruction) Return the complete updated summary as clean Markdown only. No thinking or code fences.\n\nExisting summary:\n\(previous ?? "")\n\nNew transcript chunk:\n\(newTranscript)", feature: feature)
    }

    public func title(_ transcript: String) -> String? {
        run("Create a short meaningful meeting title, 3 to 7 words. Return only the title. Do not include thinking or punctuation.\n\nTranscript:\n\(transcript)", feature: feature)
    }

    public func answer(question: String, note: String, conversation: String = "") -> String? {
        let history = conversation.trimmingCharacters(in: .whitespacesAndNewlines)
        let prior = history.isEmpty ? "" : "\n\nPrior conversation:\n\(history)\n"
        return run("This is a continued conversation about one meeting note. Use only meeting-note evidence, retain relevant context from the prior conversation, and acknowledge briefly when the meeting note does not contain an answer. Return only the answer.\(prior)\nNew user message:\n\(question)\n\nMeeting note:\n\(note)", feature: feature)
    }

    private struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
    }

    private struct GenerateResponse: Decodable {
        let response: String
    }

    // The `ollama run` CLI word-wraps piped output at terminal width, corrupting the
    // text (cut words reprinted on the next line). The HTTP API returns clean text.
    public func run(_ prompt: String, feature override: LLMFeature? = nil) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !CommandLine.arguments.contains(where: { $0.contains("xctest") }) else { return nil }
        let selectedFeature = override ?? feature
        let config = LLMConfig.config(for: selectedFeature)
        return config.usePi
            ? runPi(trimmed, model: config.model, feature: selectedFeature)
            : runOllama(trimmed, model: config.model)
    }

    private func runOllama(_ prompt: String, model: String) -> String? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = try? JSONEncoder().encode(GenerateRequest(model: model, prompt: prompt, stream: false))
        let semaphore = DispatchSemaphore(value: 0)
        var output: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let decoded = try? JSONDecoder().decode(GenerateResponse.self, from: data) { output = decoded.response }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return output.flatMap(clean)
    }

    private func runPi(_ prompt: String, model: String, feature: LLMFeature) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var environment = environmentWithHomebrewPath()
        environment["BRAIN_ROOT"] = SecondBrainStore().rootURL.path
        process.environment = environment
        let pi = UserDefaults.standard.string(forKey: "pi.executable")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let skillPath = feature.rawValue.hasPrefix("Second Brain") ? SecondBrainSkillManager.configuredURL().path : nil
        process.arguments = [pi?.isEmpty == false ? pi! : "pi"] + PiInvocation.arguments(model: model, prompt: prompt, skillPath: skillPath)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return clean(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    private func clean(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        if let range = text.range(of: "...done thinking.", options: .caseInsensitive) { text = String(text[range.upperBound...]) }
        text = text.replacingOccurrences(of: "Thinking...", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```markdown", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// GUI apps launched from Finder get a minimal PATH (/usr/bin:/bin:…), so child
/// processes can't find Homebrew tools like ffmpeg — which mlx_whisper also
/// spawns internally. Prepend the Homebrew locations explicitly.
func environmentWithHomebrewPath() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let fnm = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/fnm/aliases/default/bin").path
    env["PATH"] = "\(fnm):/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    return env
}

public final class WhisperTranscriptionService {
    public init() {}
    public func transcribe(file: URL, startMs: Int, endMs: Int, speaker: String = "Speaker 1") -> TranscriptSegment {
        let text = runWhisper(file) ?? "[Audio chunk saved for local transcription: \(file.lastPathComponent)]"
        return TranscriptSegment(speaker: speaker, startMs: startMs, endMs: endMs, text: text)
    }

    private func runWhisper(_ file: URL) -> String? {
        let supportPython = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidBridge/mlx-whisper/bin/python")
        let resourceTool = Bundle.main.resourceURL?.appendingPathComponent("Tools/mlx_whisper/bin/mlx_whisper")
        let sourceTool = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tools/mlx_whisper/bin/mlx_whisper")
        let local = [resourceTool, sourceTool].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard FileManager.default.isExecutableFile(atPath: supportPython.path) || local != nil else { return nil }
        let audioFile = convertToWavIfNeeded(file) ?? file
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("android-bridge-whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputName = audioFile.deletingPathExtension().lastPathComponent
        let outputFile = outputDir.appendingPathComponent("\(outputName).txt")
        try? FileManager.default.removeItem(at: outputFile)
        let p = Process()
        p.environment = environmentWithHomebrewPath()
        let arguments = ["--model", "mlx-community/whisper-large-v3-turbo", "--output-dir", outputDir.path, "--output-name", outputName, "--output-format", "txt", "--verbose", "False", audioFile.path]
        if FileManager.default.isExecutableFile(atPath: supportPython.path) {
            p.executableURL = supportPython
            p.arguments = ["-m", "mlx_whisper.cli"] + arguments
        } else {
            p.executableURL = local
            p.arguments = arguments
        }
        try? p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        guard let raw = try? String(contentsOf: outputFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return cleanTranscript(raw)
    }

    private func cleanTranscript(_ raw: String) -> String? {
        let words = raw.split { $0.isWhitespace || $0.isPunctuation }.map { String($0).lowercased() }
        if words.count >= 5 && Set(words).count <= 2 { return "" }

        var dedupedLines: [String] = []
        var previousLine = ""
        var lineRepeatCount = 0
        for line in raw.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !line.isEmpty {
            let normalized = normalizeForRepeat(line)
            lineRepeatCount = normalized == previousLine ? lineRepeatCount + 1 : 1
            previousLine = normalized
            if lineRepeatCount <= 1 { dedupedLines.append(line) }
        }

        var out: [String] = []
        var previous = ""
        var repeatCount = 0
        for word in dedupedLines.joined(separator: " ").split(separator: " ").map(String.init) {
            let normalized = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            repeatCount = normalized == previous ? repeatCount + 1 : 1
            previous = normalized
            if repeatCount <= 2 { out.append(word) }
        }
        let text = trimRepeatedTail(out).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func normalizeForRepeat(_ text: String) -> String {
        text.lowercased().filter { !$0.isPunctuation && !$0.isWhitespace }
    }

    private func trimRepeatedTail(_ words: [String]) -> [String] {
        guard words.count >= 12 else { return words }
        for size in 2...6 {
            var repeats = 1
            var index = words.count - size
            let phrase = words[index..<words.count].map { normalizeForRepeat($0) }
            while index >= size && words[index - size..<index].map({ normalizeForRepeat($0) }) == phrase {
                repeats += 1
                index -= size
            }
            if repeats >= 3 { return Array(words[..<(index + size)]) }
        }
        return words
    }

    private func convertToWavIfNeeded(_ file: URL) -> URL? {
        guard file.pathExtension.lowercased() != "wav" else { return file }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).wav")
        try? FileManager.default.removeItem(at: output)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.environment = environmentWithHomebrewPath()
        p.arguments = ["ffmpeg", "-y", "-i", file.path, "-ar", "16000", "-ac", "1", output.path]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? output : nil
    }
}

private extension DateFormatter {
    static let meetingFolder: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()
}
