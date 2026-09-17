import Foundation
import AVFoundation

public final class MacMeetingRecorder: NSObject, AVAudioRecorderDelegate {
    public static let shared = MacMeetingRecorder()
    private var recorder: AVAudioRecorder?
    @available(macOS 13.0, *) private var systemRecorder: SystemAudioRecorder?
    private var systemFile: URL?
    private var timer: Timer?
    private var meetingId = ""
    private var sequence = 0
    private var chunkStarted = Date()
    private let store = MeetingStore.shared
    private let whisper = WhisperTranscriptionService()
    // Serial: chunk transcriptions and the final finalizeMeeting must run in order.
    private let transcriptionQueue = DispatchQueue(label: "com.androidbridge.meeting-transcription", qos: .userInitiated)
    private let finalizationQueue = DispatchQueue(label: "com.androidbridge.meeting-finalization", qos: .userInitiated)
    public var onUpdate: (() -> Void)?
    /// Called with the finalized notes URL once stop() has flushed every chunk.
    public var onFinished: ((URL) -> Void)?
    /// Called with the meeting id the moment recording ends, however it ends —
    /// the Stop button, the auto-meeting watcher, or the recorder giving up on
    /// its own. Without this the app keeps showing "Recording" forever after a
    /// self-stop, and the Stop button becomes a no-op.
    public var onStopped: ((String) -> Void)?

    /// How long one audio chunk runs before it is rotated and transcribed.
    static let chunkSeconds: TimeInterval = 30
    /// How often the watchdog checks that the chunk chain is still alive.
    static let watchdogSeconds: TimeInterval = 5

    public var isRecording: Bool { recorder != nil }

    public func start() -> String? {
        if !meetingId.isEmpty { return meetingId }
        meetingId = UUID().uuidString
        sequence = 0
        _ = store.meetingDir(meetingId)
        if startChunk() {
            startWatchdog()
            return meetingId
        }
        meetingId = ""
        return nil
    }

    /// One repeating timer supervises the whole meeting.
    ///
    /// Chunk rotation used to be a chain of one-shot timers, each armed only by
    /// the previous one's callback: a single missed fire — a system sleep, App
    /// Nap suspending the run loop, an AVAudioRecorder interruption — broke the
    /// chain permanently and the meeting recorded nothing further while still
    /// reporting itself as active. A repeating timer in `.common` mode re-fires
    /// regardless, and it also notices a recorder that died mid-chunk.
    private func startWatchdog() {
        let install = {
            self.timer?.invalidate()
            let timer = Timer(timeInterval: Self.watchdogSeconds, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if Thread.isMainThread { install() } else { DispatchQueue.main.async(execute: install) }
    }

    private func tick() {
        guard !meetingId.isEmpty else { return }
        guard let recorder else {
            // No live recorder but the meeting never ended: the chain broke.
            rotateChunk()
            return
        }
        let expired = Date().timeIntervalSince(chunkStarted) >= Self.chunkSeconds
        // `isRecording` goes false when the OS interrupts capture (sleep, the
        // input device disappearing, another app seizing the mic).
        if expired || !recorder.isRecording { rotateChunk() }
    }

    @discardableResult
    public func stop() -> String? {
        guard !meetingId.isEmpty else { return nil }
        timer?.invalidate()
        timer = nil
        let id = meetingId
        meetingId = ""
        finishChunk(of: id)
        onStopped?(id)
        // Finalize on the same serial queue so it runs only after every pending
        // chunk transcription: finalizeMeeting renames the meeting folder, and a
        // transcript appended afterwards under the old id would recreate a ghost
        // directory and lose the last chunk's text.
        transcriptionQueue.async {
            self.finalizationQueue.async {
                let notes = self.store.finalizeMeeting(meetingId: id)
                self.onUpdate?()
                self.onFinished?(notes)
            }
        }
        return id
    }

    private func startChunk() -> Bool {
        chunkStarted = Date()
        let media = store.meetingDir(meetingId).appendingPathComponent("media", isDirectory: true)
        let file = media.appendingPathComponent(String(format: "you-chunk-%04d.m4a", sequence))
        systemFile = media.appendingPathComponent(String(format: "remote-chunk-%04d.m4a", sequence))
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64_000,
        ]
        guard let recorder = try? AVAudioRecorder(url: file, settings: settings), recorder.record() else { return false }
        self.recorder = recorder
        recorder.delegate = self
        if #available(macOS 13.0, *), let systemFile {
            let systemRecorder = SystemAudioRecorder()
            self.systemRecorder = systemRecorder
            systemRecorder.start(to: systemFile)
        }
        return true
    }

    private func rotateChunk() {
        finishChunk(of: meetingId)
        sequence += 1
        // A failed restart is usually transient (the mic is momentarily busy).
        // Leave the meeting open so the next watchdog tick retries instead of
        // silently ending a meeting the user still thinks is running.
        _ = startChunk()
    }

    private func finishChunk(of id: String) {
        guard let recorder else { return }
        let micFile = recorder.url
        let remoteFile = systemFile
        recorder.stop()
        if #available(macOS 13.0, *) { systemRecorder?.stop(); systemRecorder = nil }
        self.recorder = nil
        self.systemFile = nil
        let startMs = Int(chunkStarted.timeIntervalSince1970 * 1000)
        let endMs = Int(Date().timeIntervalSince1970 * 1000)
        transcriptionQueue.async {
            var newSegments = [TranscriptSegment]()
            let you = self.whisper.transcribe(file: micFile, startMs: startMs, endMs: endMs, speaker: "You")
            self.store.appendTranscript(meetingId: id, segment: you)
            newSegments.append(you)
            if let remoteFile, FileManager.default.fileExists(atPath: remoteFile.path) {
                Thread.sleep(forTimeInterval: 1)
                let remote = self.whisper.transcribe(file: remoteFile, startMs: startMs, endMs: endMs, speaker: "Remote")
                self.store.appendTranscript(meetingId: id, segment: remote)
                newSegments.append(remote)
            }
            _ = self.store.writeNotesIncremental(meetingId: id, newSegments: newSegments)
            self.onUpdate?()
        }
    }
}
