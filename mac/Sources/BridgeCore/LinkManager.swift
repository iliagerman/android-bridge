import Foundation
import Network
import AppKit
import Combine
import CoreAudio
import UserNotifications
import DeviceLinkProtocol
import Crypto
import Security
import AVFoundation

/// A peer discovered on the LAN (Bonjour), with its advertised fingerprint.
public struct NearbyPeer: Identifiable, Equatable {
    public let id: String            // fingerprint
    public let name: String
    public let endpoint: NWEndpoint
    public let fingerprint: String
}

public struct ReceivedFile: Identifiable, Equatable {
    public let id = UUID()
    public let name: String
    public let url: URL
    public let receivedAt: Date
}

public struct MeetingCalendarReview: Equatable {
    public let meeting: MeetingRecord
    public let events: [MeetingCalendarEvent]

    public init(meeting: MeetingRecord, events: [MeetingCalendarEvent]) {
        self.meeting = meeting
        self.events = events
    }
}

/// TLS server over Bonjour. Android connects as a pinned TLS client, so clipboard/files/call metadata
/// are encrypted on the LAN. This is server-authenticated TLS; full client-certificate mTLS is future hardening.
public final class LinkManager: ObservableObject {
    @Published public private(set) var status: ConnectionState = .disconnected
    @Published public private(set) var relayEnabled = false
    @Published public private(set) var relayEnrolled = false
    @Published public private(set) var relayEndpoint = ""
    @Published public private(set) var relayWorkspaceId = ""
    @Published public private(set) var relayInvitation: String?
    @Published public private(set) var relayInvitationExpiresAt: String?
    @Published public private(set) var relayStatus = "Disabled"
    @Published public private(set) var nearby: [NearbyPeer] = []
    @Published public private(set) var pairedFingerprints: Set<String> = []
    @Published public private(set) var lastClipboard: String?
    @Published public private(set) var clipboardAutoSync = UserDefaults.standard.bool(forKey: "clipboard.autoSync")
    @Published public private(set) var events: [String] = []
    @Published public private(set) var screenImage: NSImage?
    @Published public private(set) var screenSharing = false
    private var captureActive = false
    private var captureGeneration = 0
    private var warnedScreenCapture = false
    @Published public private(set) var receivedFiles: [ReceivedFile] = []
    @Published public private(set) var meetings: [MeetingRecord] = []
    @Published public private(set) var meetingChats: [String: MeetingChatArchive] = [:]
    @Published public private(set) var meetingChatBusyIds: Set<String> = []
    @Published public private(set) var meetingChatErrors: [String: String] = [:]
    @Published public private(set) var regeneratingSummaryIds: Set<String> = []
    @Published public private(set) var mergeStatus: String?
    @Published public private(set) var summaryBackfillStatus: String?
    @Published public private(set) var summaryBackfillRunning = false
    @Published public private(set) var brainTransferIds: Set<String> = []
    @Published public private(set) var brainNodes: [BrainNode] = []
    @Published public private(set) var brainEdges: [BrainEdge] = []
    @Published public private(set) var selectedBrainPath = "index.md"
    @Published public private(set) var selectedBrainContent = ""
    @Published public private(set) var brainSearchResults: [BrainSearchResult] = []
    @Published public private(set) var brainChat = ""
    @Published public private(set) var brainStatus = "Not refreshed"
    @Published public private(set) var macMeetingActive = false
    @Published public private(set) var phoneMeetingActive = false
    @Published public private(set) var calendarCandidates: [String: [MeetingCalendarEvent]] = [:]
    @Published public private(set) var calendarMessages: [String: String] = [:]
    @Published public private(set) var calendarBrowseDay: [String: Date] = [:]
    @Published public private(set) var calendarAccessMessage = "Calendar access has not been checked."
    @Published public private(set) var availableCalendars: [MeetingCalendarDescriptor] = []
    @Published public private(set) var mainCalendarIdentifier = UserDefaults.standard.string(forKey: "meeting.mainCalendarIdentifier") ?? ""
    @Published public private(set) var customers: [String] = []
    @Published public private(set) var customerAssociations: [MeetingCustomerAssociation] = []
    @Published public private(set) var customerPromptMeetingId: String?
    @Published public private(set) var customerStatus = "Customer catalog not loaded."
    private var pendingCustomerEvents: [String: MeetingCalendarEvent] = [:]
    private var zoomAutoMeetingActive = false
    private var autoMeetingMissingSince: Date?
    /// Meeting id currently asking the user "are you still in this meeting?".
    @Published public private(set) var longRunningMeetingId: String?
    /// How long the meeting in `longRunningMeetingId` has been recording.
    @Published public private(set) var longRunningMeetingElapsed: TimeInterval = 0
    private var longMeetingWatchdogs: [String: LongMeetingWatchdog] = [:]
    private let brainStore = SecondBrainStore()
    private let customerStore = MeetingCustomerStore()
    private let meetingContentMirror = MeetingContentMirror()

    /// Broadcast for inbound events so the app can show a banner (reliable without notification entitlements).
    public let notificationSubject = PassthroughSubject<(title: String, body: String, userInfo: [AnyHashable: Any]), Never>()
    /// Ringing on the phone — the app shows an interactive Answer/Decline panel.
    public let incomingCallSubject = PassthroughSubject<(number: String, name: String), Never>()
    /// Call lifecycle transition ("active"/"ended") — the app swaps to an in-call panel or dismisses.
    public let callStateSubject = PassthroughSubject<(state: String, number: String, name: String), Never>()
    /// A finalized recording awaiting explicit calendar assignment.
    public let calendarReviewSubject = PassthroughSubject<MeetingCalendarReview, Never>()
    /// The call currently on screen — set on ring (incoming) and on dial (outgoing); the source of
    /// truth for the in-call panel, since OFFHOOK/IDLE transitions carry no reliable number.
    private var currentCallNumber = ""
    private var currentCallName = ""

    private var lastPeer: NearbyPeer?
    private var incomingFile: (name: String, data: Data)?
    private var meetingPhotos: [String: [MeetingPhoto]] = [:]
    private var meetingStartTimes: [String: Int] = [:]
    private var activeMeetingIds: Set<String> = []
    private var macStartedMeetingId: String?
    private let meetingStore = MeetingStore.shared
    private let whisper = WhisperTranscriptionService()
    private let calendarService = MeetingCalendarService()
    private let macRecorder = MacMeetingRecorder.shared
    private let meetingProcessingQueue = DispatchQueue(label: "com.androidbridge.meeting.processing")
    private let meetingFinalizationQueue = DispatchQueue(label: "com.androidbridge.meeting.finalization")
    private let meetingChatQueue = DispatchQueue(label: "com.androidbridge.meeting-chat", qos: .userInitiated)
    private let meetingContentMirrorQueue = DispatchQueue(label: "com.androidbridge.meeting-content-mirror", qos: .utility)
    private let brainRefreshQueue = DispatchQueue(label: "com.androidbridge.second-brain.refresh")
    private var meetingContentMirrorGeneration = 0
    private var lastBrainRevision = ""
    private var lastPasteboardChange = 0

    public let deviceName: String
    public let fingerprint: String
    public var brainStorePath: String { brainStore.rootURL.path }
    private let identity: SelfSignedIdentity

    public static let shared = LinkManager(deviceName: Host.current().localizedName ?? "Mac")
    private var started = false

    private func refreshMeetings() {
        let records = meetingStore.listMeetings(activeIds: activeMeetingIds)
        scheduleMeetingContentMirror(records)
        do {
            let catalog = try customerStore.customers(meetingNames: records.map(\.company))
            let associations = try customerStore.associations()
            DispatchQueue.main.async {
                self.meetings = records
                self.customers = catalog
                self.customerAssociations = associations
                self.customerStatus = "\(catalog.count) customers • \(associations.count) learned matches"
            }
        } catch {
            DispatchQueue.main.async {
                self.meetings = records
                self.customers = []
                self.customerAssociations = []
                self.customerStatus = error.localizedDescription
            }
        }
    }

    private func scheduleMeetingContentMirror(_ records: [MeetingRecord]) {
        guard !CommandLine.arguments.contains(where: { $0.contains("xctest") }) else { return }
        meetingContentMirrorQueue.async {
            self.meetingContentMirrorGeneration += 1
            let generation = self.meetingContentMirrorGeneration
            self.meetingContentMirrorQueue.asyncAfter(deadline: .now() + 0.4) {
                guard generation == self.meetingContentMirrorGeneration else { return }
                do {
                    try self.meetingContentMirror.sync(records)
                    self.dbg("MEETING_CONTENT mirrored=\(records.count)")
                } catch {
                    self.dbg("MEETING_CONTENT failed=\(error.localizedDescription)")
                }
            }
        }
    }

    private func pushEvent(_ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        DispatchQueue.main.async { self.events = Array((["\(stamp)  \(text)"] + self.events).prefix(100)) }
    }

    private func dbg(_ s: String) {
        let line = "[\(Int(Date().timeIntervalSince1970))] LINK \(s)\n"
        let url = URL(fileURLWithPath: "/tmp/androidbridge-diag.txt")
        if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close() }
        else { try? line.data(using: .utf8)!.write(to: url) }
    }

    public func requestNotificationAuthorization() {
    }

    private func postNotification(title: String, body: String, userInfo: [String: String] = [:]) {
        notificationSubject.send((title: title, body: body, userInfo: userInfo))
    }

    private let serviceType = "_androidbridge._tcp"
    private let queue = DispatchQueue(label: "com.androidbridge.link")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var directReceiver = BoundedControlReceiver()
    private var relayReceiver = BoundedControlReceiver()
    private let relaySettingsStore = RelaySettingsStore()
    private let relayEnrollmentClient = RelayEnrollmentClient()
    private let relayTransport = URLSessionRelayTransport()
    private let relayPolicy = DirectFirstRelayPolicy()
    private var relaySettings = RelaySettings(enabled: false, endpoint: "", workspaceId: "", deviceId: "")
    private var replaySession: RelayReplaySession?
    private var brainSync: SecondBrainDeltaSynchronizer?
    private var relayConnected = false
    private var relayFallbackWorkItem: DispatchWorkItem?
    private var sleeping = false

    private let pairedKey = "com.androidbridge.paired"

    public init(deviceName: String) {
        self.deviceName = deviceName
        self.identity = Self.loadOrCreateIdentity(deviceName: deviceName)
        self.fingerprint = identity.fingerprint
        // Restore known (paired) devices so we auto-reconnect without re-pairing.
        self.pairedFingerprints = Set(UserDefaults.standard.stringArray(forKey: pairedKey) ?? [])
        loadRelaySettings()
        relayTransport.onState = { [weak self] state, generation in self?.handleRelayState(state, generation: generation) }
        relayTransport.onFrame = { [weak self] data, generation in self?.handleRelayFrame(data, generation: generation) }
        cleanReceivedFiles()
        meetingStore.recoverInterruptedProcessing(activeIds: activeMeetingIds)
        macRecorder.onUpdate = { [weak self] in self?.refreshMeetings() }
        macRecorder.onFinished = { [weak self] notes in self?.completeFinalization(notesURL: notes, sourceMeetingId: nil) }
        macRecorder.onStopped = { [weak self] id in
            DispatchQueue.main.async { self?.finishMacMeeting(id) }
        }
        refreshMeetings()
        // Initial state: register the installed app for Calendar access and
        // generate summaries that are still missing.
        if !CommandLine.arguments.contains(where: { $0.contains("xctest") }) {
            requestCalendarAccess()
            refreshCalendars()
            backfillMissingSummaries()
        }
    }

    private func rememberPaired(_ fp: String) {
        if pairedFingerprints.contains(fp) { return }
        DispatchQueue.main.async {
            self.pairedFingerprints.insert(fp)
            UserDefaults.standard.set(Array(self.pairedFingerprints), forKey: self.pairedKey)
        }
    }

    public func start() {
        if started { return }
        started = true
        requestNotificationAuthorization()
        startClipboardWatch()
        startAutoMeetingWatch()
        setPhoneFeaturesEnabled(UserDefaults.standard.string(forKey: "setup.mode") != "macOnly")
    }

    public func setPhoneFeaturesEnabled(_ enabled: Bool) {
        queue.async {
            if enabled {
                self.browser?.cancel()
                self.startBrowser()
                self.setStatus(.discovering)
                self.scheduleRelayFallback()
                return
            }
            self.relayFallbackWorkItem?.cancel()
            self.relayPolicy.suspend()
            self.relayTransport.disconnect()
            self.relayConnected = false
            self.connection?.cancel()
            self.browser?.cancel()
            DispatchQueue.main.async { self.nearby = [] }
            self.setStatus(.disconnected)
            self.setRelayStatus("Disabled in Mac-only mode")
        }
    }

    /// Observe the pasteboard for the opt-in Auto Sync mode. Manual Push Clipboard remains available.
    private func startClipboardWatch() {
        DispatchQueue.main.async {
            self.lastPasteboardChange = NSPasteboard.general.changeCount
            Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.pollPasteboard() }
        }
    }

    private func startAutoMeetingWatch() {
        DispatchQueue.main.async {
            self.dbg("AUTO_MEETING watcher started")
            Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.pollVideoMeeting() }
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.pollLongRunningMeetings() }
        }
    }

    /// Asks the user to confirm a meeting that has been recording for hours,
    /// and ends it if nobody answers. See `LongMeetingWatchdog`.
    private func pollLongRunningMeetings() {
        let now = Date()
        longMeetingWatchdogs = longMeetingWatchdogs.filter { activeMeetingIds.contains($0.key) }
        for id in activeMeetingIds where longMeetingWatchdogs[id] == nil {
            let startedMs = meetingStartTimes[id] ?? Int(now.timeIntervalSince1970 * 1000)
            longMeetingWatchdogs[id] = LongMeetingWatchdog(startedAt: Date(timeIntervalSince1970: Double(startedMs) / 1000))
        }

        for (id, watchdog) in longMeetingWatchdogs {
            switch watchdog.decision(now: now) {
            case .idle:
                if longRunningMeetingId == id { clearLongMeetingPrompt() }
            case .prompt:
                longMeetingWatchdogs[id]?.markPrompted(at: now)
                let elapsed = now.timeIntervalSince(watchdog.startedAt)
                DispatchQueue.main.async {
                    self.longRunningMeetingId = id
                    self.longRunningMeetingElapsed = elapsed
                }
            case .autoStop:
                pushEvent("⏱️ Recording ran \(Int(now.timeIntervalSince(watchdog.startedAt) / 3600))h with no confirmation — stopping and saving")
                stopLongRunningMeeting(id)
            }
        }
    }

    /// The user confirmed the meeting is still going: keep recording and ask
    /// again in another two hours.
    public func acknowledgeLongRunningMeeting() {
        guard let id = longRunningMeetingId else { return }
        longMeetingWatchdogs[id]?.acknowledge(at: Date())
        clearLongMeetingPrompt()
        pushEvent("🎙️ Meeting confirmed still running")
    }

    /// The user answered "no, it's over" — or nobody answered at all.
    public func stopLongRunningMeeting(_ meetingId: String? = nil) {
        guard let id = meetingId ?? longRunningMeetingId else { return }
        clearLongMeetingWatchdog(id)
        if macMeetingActive && macRecorder.isRecording { stopMeetingOnMac() }
        else if macStartedMeetingId == id { stopMeetingOnPhone() }
        else { beginPhoneMeetingFinalization(meetingId: id, endedAtMs: Int(Date().timeIntervalSince1970 * 1000)) }
    }

    private func clearLongMeetingWatchdog(_ meetingId: String) {
        longMeetingWatchdogs.removeValue(forKey: meetingId)
        if longRunningMeetingId == meetingId { clearLongMeetingPrompt() }
    }

    private func clearLongMeetingPrompt() {
        DispatchQueue.main.async {
            self.longRunningMeetingId = nil
            self.longRunningMeetingElapsed = 0
        }
    }

    private func pollVideoMeeting() {
        guard let app = Self.activeMeetingApp() else {
            guard zoomAutoMeetingActive else { return }
            if autoMeetingMissingSince == nil {
                autoMeetingMissingSince = Date()
                dbg("AUTO_MEETING signal missing; waiting")
            } else if Date().timeIntervalSince(autoMeetingMissingSince!) >= 60 {
                dbg("AUTO_MEETING ended")
                zoomAutoMeetingActive = false
                autoMeetingMissingSince = nil
                if macMeetingActive { stopMeetingOnMac() }
            }
            return
        }
        autoMeetingMissingSince = nil
        if !macMeetingActive {
            dbg("AUTO_MEETING detected app=\(app)")
            zoomAutoMeetingActive = true
            startMeetingOnMac()
            pushEvent("🎙️ Auto-recording \(app) meeting")
        }
    }

    private static func activeMeetingApp() -> String? {
        // Primary signal: some other process is holding a live microphone — that IS
        // an ongoing conversation, and it needs no Screen Recording permission.
        if #available(macOS 14.4, *), let app = conversationAppUsingMicrophone() { return app }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let title = (window[kCGWindowName as String] as? String ?? "").lowercased()
            if owner.contains("zoom"), title.contains("meeting") || title.contains("webinar") || title.contains("פגישה") { return "Zoom" }
            if owner.contains("msteams") || owner.contains("microsoft teams") || owner == "teams",
               isMeetingTitle(title) { return "Teams" }
            if owner.contains("google chrome") || owner.contains("safari") || owner.contains("arc") || owner.contains("brave") || owner.contains("firefox") {
                // Google Meet tab titles use an en dash: "Meet – abc-defg-hij".
                if title.contains("meet.google.com") || title.contains("google meet") || title.contains("meet -") || title.contains("meet –") { return "Google Meet" }
            }
        }
        return nil
    }

    /// Names the conversation app currently capturing the microphone, if any.
    /// CoreAudio (macOS 14.4+) lists every audio client process with a live input,
    /// so a Teams/Zoom/browser call is detected the moment audio flows and ends
    /// when the app releases the mic — our own recorder is excluded by pid.
    @available(macOS 14.4, *)
    private static func conversationAppUsingMicrophone() -> String? {
        let apps: [(needle: String, name: String)] = [
            ("zoom", "Zoom"), ("teams", "Teams"), ("whatsapp", "WhatsApp"),
            ("facetime", "FaceTime"), ("telegram", "Telegram"), ("slack", "Slack"),
            ("discord", "Discord"),
            ("chrome", "Browser call"), ("safari", "Browser call"), ("firefox", "Browser call"),
            ("thebrowser", "Browser call"), ("brave", "Browser call"),
        ]
        for bundleId in processesWithLiveMicrophone() {
            if let match = apps.first(where: { bundleId.contains($0.needle) }) { return match.name }
        }
        return nil
    }

    /// Bundle ids (lowercased) of other processes currently recording from any input device.
    @available(macOS 14.4, *)
    private static func processesWithLiveMicrophone() -> [String] {
        func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
        var listAddress = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &objects) == noErr else { return [] }

        let ownPid = ProcessInfo.processInfo.processIdentifier
        var result: [String] = []
        for object in objects {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = address(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != ownPid else { continue }
            var bundle: CFString = "" as CFString
            var bundleSize = UInt32(MemoryLayout<CFString>.size)
            var bundleAddress = address(kAudioProcessPropertyBundleID)
            guard AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr else { continue }
            result.append((bundle as String).lowercased())
        }
        return result
    }

    private static func isMeetingTitle(_ title: String) -> Bool {
        let t = title.lowercased()
        // Hebrew UI titles say פגישה (meeting) / שיחה (call) instead of the English words.
        return t.contains("meeting") || t.contains("call") || t.contains("פגישה") || t.contains("שיחה") || t.contains("meet.google.com") || t.contains("google meet")
    }

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pb.changeCount
        guard connection != nil || relayConnected else { return }
        if let text = pb.string(forType: .string), !text.isEmpty { sendClipboard(text, userInitiated: false) }
    }

    public func stop() {
        queue.async {
            self.started = false
            self.relayFallbackWorkItem?.cancel()
            self.relayPolicy.suspend()
            self.relayTransport.disconnect()
            self.connection?.cancel()
            self.listener?.cancel()
            self.browser?.cancel()
        }
    }

    public func prepareForSleep() {
        queue.async {
            self.sleeping = true
            self.relayFallbackWorkItem?.cancel()
            self.relayPolicy.suspend()
            self.relayTransport.disconnect()
            self.relayConnected = false
            self.connection?.cancel()
            self.setRelayStatus(self.relayEnabled ? "Sleeping" : "Disabled")
        }
    }

    public func resumeAfterWake() {
        queue.async {
            guard self.started else { return }
            self.sleeping = false
            guard UserDefaults.standard.string(forKey: "setup.mode") != "macOnly" else { return }
            self.browser?.cancel()
            self.startBrowser()
            self.setStatus(.discovering)
            self.scheduleReconnect()
            self.scheduleRelayFallback()
        }
    }

    public func pair(_ peer: NearbyPeer) {
        rememberPaired(peer.fingerprint) // persists so we never re-pair
        connect(peer) // demo: the Mac always dials; the phone accepts
    }

    public func connect(_ peer: NearbyPeer) {
        if connection != nil { dbg("connect skipped (busy) → \(peer.name)"); return }
        dbg("dialing \(peer.name) endpoint=\(peer.endpoint)")
        lastPeer = peer
        rememberPaired(peer.fingerprint)
        setStatus(.connecting)
        adopt(NWConnection(to: peer.endpoint, using: tlsParameters(pinnedFingerprint: peer.fingerprint)), initiator: true)
    }

    private func scheduleReconnect() {
        guard UserDefaults.standard.string(forKey: "setup.mode") != "macOnly" else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self,
                  UserDefaults.standard.string(forKey: "setup.mode") != "macOnly",
                  self.connection == nil,
                  let p = self.lastPeer else { return }
            // The phone's port changes across app restarts — prefer the freshest
            // discovered endpoint over the cached one, or dialing hangs forever.
            let fresh = self.nearby.first { $0.fingerprint == p.fingerprint } ?? p
            self.connect(fresh)
        }
    }

    private func startHeartbeat(_ conn: NWConnection) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.connection === conn else { return }
            self.send(Message(id: UUID().uuidString, type: MessageTypes.linkHeartbeat))
            self.startHeartbeat(conn)
        }
    }

    public func setClipboardAutoSync(_ enabled: Bool) {
        clipboardAutoSync = enabled
        UserDefaults.standard.set(enabled, forKey: "clipboard.autoSync")
    }

    public func setRelayEnabled(_ enabled: Bool) {
        queue.async {
            guard !enabled || self.relaySettings.isEnrolled else {
                self.setRelayStatus(RelayError.notEnrolled.localizedDescription)
                return
            }
            self.relaySettings.enabled = enabled
            do {
                try self.relaySettingsStore.save(self.relaySettings)
                DispatchQueue.main.async { self.relayEnabled = enabled }
                if enabled { self.scheduleRelayFallback() }
                else { self.disableRelay() }
            } catch {
                self.setRelayStatus(error.localizedDescription)
            }
        }
    }

    public func saveRelayEndpoint(_ endpointText: String, workspaceId: String) {
        do {
            _ = try RelayEndpoint(try relayURL(endpointText))
        } catch {
            setRelayStatus(error.localizedDescription)
            return
        }
        queue.async {
            let enrollmentChanged = self.relaySettings.endpoint != endpointText || self.relaySettings.workspaceId != workspaceId
            self.relaySettings.endpoint = endpointText
            self.relaySettings.workspaceId = workspaceId
            if enrollmentChanged {
                self.relaySettings.credential = nil
                self.relaySettings.enabled = false
            }
            self.persistRelaySettings()
        }
    }

    public func createRelayPhoneInvitation() {
        let endpoint: RelayEndpoint
        let credential: RelayCredential
        do {
            endpoint = try RelayEndpoint(try relayURL(relaySettings.endpoint))
            guard let secret = relaySettings.credential else { throw RelayError.notEnrolled }
            credential = RelayCredential(deviceId: relaySettings.deviceId, credential: secret)
        } catch {
            setRelayStatus(error.localizedDescription)
            return
        }
        setRelayStatus("Creating phone invitation…")
        Task {
            do {
                let invitation = try await relayEnrollmentClient.createPhoneInvitation(endpoint: endpoint, credential: credential)
                publishRelayInvitation(invitation)
            } catch {
                setRelayStatus(error.localizedDescription)
            }
        }
    }

    public func enrollRelay(endpoint endpointText: String, workspaceId: String, setupCode: String) {
        let endpoint: RelayEndpoint
        do {
            endpoint = try RelayEndpoint(try relayURL(endpointText))
            guard !workspaceId.isEmpty, !setupCode.isEmpty else { throw RelayError.invalidResponse }
        } catch {
            setRelayStatus(error.localizedDescription)
            return
        }
        setRelayStatus("Enrolling…")
        Task {
            do {
                let credential = try await relayEnrollmentClient.enrollSetup(
                    endpoint: endpoint,
                    workspaceId: workspaceId,
                    deviceId: relaySettings.deviceId,
                    setupCode: setupCode
                )
                enqueueRelayEnrollment(credential, endpointText: endpointText, workspaceId: workspaceId)
            } catch {
                setRelayStatus(error.localizedDescription)
            }
        }
    }

    public func sendClipboard(_ text: String, userInitiated: Bool = true) {
        let policy = ClipboardSyncPolicy(clipboardAutoSync ? .auto : .manual)
        guard policy.shouldSend(userInitiated: userInitiated) else { return }
        guard !text.isEmpty else { pushEvent("📋 Clipboard is empty"); return }
        guard text.utf8.count <= 900_000 else { pushEvent("⚠️ Clipboard text is too large; send it as a file"); return }
        send(Mappers.clipboard(text))
        pushEvent("📋 Sent clipboard")
    }
    public func requestPhoneScreen() { send(Mappers.screenRequest()); pushEvent("🖥️ Requested phone screen") }
    public func tapPhone(x: Double, y: Double, w: Double, h: Double) { send(Mappers.inputTap(x: x, y: y, w: w, h: h)) }
    public func swipePhone(x1: Double, y1: Double, x2: Double, y2: Double, w: Double, h: Double) { send(Mappers.inputSwipe(x1: x1, y1: y1, x2: x2, y2: y2, w: w, h: h)) }

    // MARK: - Calls (control the phone's telephony from the Mac; audio stays on the phone)

    public func answerCall() { send(Mappers.callAction("answer")); pushEvent("📞 Answered on phone") }
    public func hangupCall() { send(Mappers.callAction("decline")); pushEvent("📞 Hung up") }
    public func dial(_ number: String) {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        currentCallNumber = trimmed
        currentCallName = trimmed
        send(Mappers.callAction("dial", number: trimmed))
        pushEvent("📞 Calling \(trimmed)…")
    }

    // Per-feature test senders — exercise the whole protocol end-to-end over the link.
    public func sendTestNotification() { send(Mappers.notification(pkg: "com.demo.app", title: "Test notification", text: "Hello from \(deviceName)", postedAt: 0)) }
    public func sendTestSms() { send(Mappers.smsReceived(threadId: 1, address: "+1 555 0100", body: "Test SMS from \(deviceName)", receivedAt: 0)) }
    public func sendTestCall() { send(Mappers.incomingCall(number: "+1 555 0199", contactName: "Test Caller")) }
    public func sendTestFile() {
        send(Message(id: UUID().uuidString, type: MessageTypes.fileOffer,
                     payload: ["name": .string("demo.txt"), "size": .int(1024), "transferId": .string("t1"), "streamId": .int(1)]))
    }
    public func sendTestScreen() {
        send(Message(id: UUID().uuidString, type: MessageTypes.screenStart,
                     payload: ["streamId": .int(1), "codec": .string("h264"), "maxBitrate": .int(8_000_000)]))
    }

    // MARK: - Relay

    private func loadRelaySettings() {
        let generatedId = UserDefaults.standard.string(forKey: "relay.deviceId") ?? "mac-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(generatedId, forKey: "relay.deviceId")
        do {
            relaySettings = try relaySettingsStore.load()
                ?? RelaySettings(enabled: false, endpoint: "", workspaceId: "", deviceId: generatedId)
            relayEnabled = relaySettings.enabled
            relayEnrolled = relaySettings.isEnrolled
            relayEndpoint = relaySettings.endpoint
            relayWorkspaceId = relaySettings.workspaceId
            relayStatus = relaySettings.enabled ? "Waiting for direct connection" : "Disabled"
            let replaySession = try RelayReplaySession.applicationSupport(
                actorId: "mac",
                legacyActorId: relaySettings.deviceId
            )
            replaySession.setMessageHandler { [weak self] message in self?.route(message) }
            self.replaySession = replaySession
            brainSync = try SecondBrainDeltaSynchronizer.applicationSupport(store: brainStore, replaySession: replaySession)
        } catch {
            relaySettings = RelaySettings(enabled: false, endpoint: "", workspaceId: "", deviceId: generatedId)
            relayStatus = error.localizedDescription
            LinkLogger.securityEvent("relay_settings_load_failed", ["reason": String(describing: error)])
        }
    }

    private func publishRelayInvitation(_ invitation: RelayInvitation) {
        DispatchQueue.main.async {
            self.relayInvitation = invitation.invitation
            self.relayInvitationExpiresAt = invitation.expiresAt
            self.relayStatus = "Phone invitation ready"
        }
    }

    private func enqueueRelayEnrollment(_ credential: RelayCredential, endpointText: String, workspaceId: String) {
        queue.async { self.finishRelayEnrollment(credential, endpointText: endpointText, workspaceId: workspaceId) }
    }

    private func finishRelayEnrollment(_ credential: RelayCredential, endpointText: String, workspaceId: String) {
        guard credential.deviceId == relaySettings.deviceId else {
            setRelayStatus(RelayError.invalidResponse.localizedDescription)
            return
        }
        relaySettings.endpoint = endpointText
        relaySettings.workspaceId = workspaceId
        relaySettings.credential = credential.credential
        persistRelaySettings()
        setRelayStatus("Enrolled. Relay remains off until enabled.")
    }

    private func persistRelaySettings() {
        do {
            try relaySettingsStore.save(relaySettings)
            DispatchQueue.main.async {
                self.relayEnabled = self.relaySettings.enabled
                self.relayEnrolled = self.relaySettings.isEnrolled
                self.relayEndpoint = self.relaySettings.endpoint
                self.relayWorkspaceId = self.relaySettings.workspaceId
            }
        } catch {
            setRelayStatus(error.localizedDescription)
        }
    }

    private func disableRelay() {
        relayFallbackWorkItem?.cancel()
        relayPolicy.suspend()
        relayTransport.disconnect()
        relayConnected = false
        setRelayStatus("Disabled")
    }

    private func scheduleRelayFallback() {
        queue.async {
            self.relayFallbackWorkItem?.cancel()
            guard UserDefaults.standard.string(forKey: "setup.mode") != "macOnly" else { return }
            let enabled = self.relaySettings.enabled && self.relaySettings.isEnrolled && !self.sleeping
            let plan = self.relayPolicy.begin(relayEnabled: enabled)
            guard let delay = plan.fallbackDelay else { return }
            if self.connection != nil {
                self.relayPolicy.directConnected()
                self.setRelayStatus("Direct connection active")
                return
            }
            self.setRelayStatus("Waiting for direct connection")
            let work = DispatchWorkItem { [weak self] in self?.connectRelay(generation: plan.generation) }
            self.relayFallbackWorkItem = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func connectRelay(generation: UInt64) {
        guard relayPolicy.isCurrent(generation), !sleeping,
              let credentialText = relaySettings.credential else { return }
        if let direct = connection {
            guard status != .connected else { return }
            connection = nil
            direct.cancel()
        }
        setStatus(.connecting)
        do {
            let endpoint = try RelayEndpoint(try relayURL(relaySettings.endpoint))
            relayReceiver = BoundedControlReceiver()
            relayTransport.connect(
                endpoint: endpoint,
                credential: RelayCredential(deviceId: relaySettings.deviceId, credential: credentialText),
                generation: generation
            )
        } catch {
            setRelayStatus(error.localizedDescription)
        }
    }

    private func handleRelayState(_ state: RelayTransportState, generation: UInt64) {
        queue.async {
            guard self.relayPolicy.isCurrent(generation), self.connection == nil else { return }
            switch state {
            case .connecting:
                self.setRelayStatus("Connecting through relay…")
            case .connected:
                self.relayConnected = true
                self.setRelayStatus("Connected through relay")
                self.setStatus(.connected)
                self.sendRelaySessionFrames()
            case .waitingForPeer:
                self.relayConnected = true
                self.setRelayStatus("Relay connected; waiting for phone")
                self.setStatus(.disconnected)
            case .disconnected:
                self.relayConnected = false
                self.setStatus(.disconnected)
                self.setRelayStatus("Relay disconnected")
                self.retryRelay(generation: generation)
            case .failed(let message):
                self.relayConnected = false
                self.setStatus(.disconnected)
                self.setRelayStatus("Relay error: \(message)")
                self.retryRelay(generation: generation)
            }
        }
    }

    private func retryRelay(generation: UInt64) {
        queue.asyncAfter(deadline: .now() + 2) {
            guard self.relayPolicy.isCurrent(generation), self.connection == nil, !self.sleeping else { return }
            self.scheduleRelayFallback()
        }
    }

    private func sendRelaySessionFrames() {
        guard let replaySession else {
            setRelayStatus("Relay replay journal unavailable")
            relayTransport.disconnect()
            return
        }
        do {
            _ = try brainSync?.scan()
            for frame in try replaySession.sessionFrames() { try relayTransport.send(frame) }
        } catch {
            setRelayStatus(error.localizedDescription)
            relayTransport.disconnect()
        }
    }

    private func handleRelayFrame(_ data: Data, generation: UInt64) {
        queue.async {
            guard self.relayPolicy.isCurrent(generation), self.relayConnected, self.connection == nil,
                  let replaySession = self.replaySession else { return }
            do {
                self.setRelayStatus("Connected through relay")
                self.setStatus(.connected)
                for message in try self.relayReceiver.ingest(data) {
                    let result = try replaySession.handle(message)
                    for delivered in result.messages { self.route(delivered) }
                    for frame in result.outboundFrames { try self.relayTransport.send(frame) }
                    if !result.appliedOperations.isEmpty { self.refreshBrain() }
                }
            } catch {
                LinkLogger.securityEvent("relay_receive_rejected", ["reason": String(describing: error)])
                self.setRelayStatus(error.localizedDescription)
                self.relayTransport.disconnect()
            }
        }
    }

    private func relayURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RelayError.invalidEndpoint
        }
        return url
    }

    private func setRelayStatus(_ text: String) {
        DispatchQueue.main.async { self.relayStatus = text }
    }

    // MARK: - Networking

    private static func loadOrCreateIdentity(deviceName: String) -> SelfSignedIdentity {
        try! SelfSignedIdentity.generate(commonName: deviceName)
    }

    private func tlsParameters(pinnedFingerprint: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let cert = SecTrustGetCertificateAtIndex(secTrust, 0) else { complete(false); return }
            let der = SecCertificateCopyData(cert) as Data
            let fp = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined(separator: ":")
            complete(fp == pinnedFingerprint)
        }, queue)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.handleResults(results) }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var peers: [NearbyPeer] = []
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint, name != "AndroidBridge-\(deviceName)" else { continue }
            guard case let .bonjour(txt) = r.metadata else { continue }
            let fp = txtValue(txt, "fp") ?? ""
            if fp.isEmpty || fp == fingerprint { continue }
            peers.append(NearbyPeer(id: fp, name: txtValue(txt, "name") ?? name, endpoint: r.endpoint, fingerprint: fp))
        }
        dbg("browse results: \(peers.map { "\($0.name)@\($0.endpoint)" }.joined(separator: " | "))")
        DispatchQueue.main.async {
            self.nearby = peers
            // Auto-connect to a known device — or, if none are known yet, to the first discovered peer
            // (trust-on-first-discovery) and remember it. After that we only reconnect to known devices,
            // so the user never has to pair manually.
            if self.connection == nil,
               let p = peers.first(where: { self.pairedFingerprints.contains($0.fingerprint) })
                    ?? (self.pairedFingerprints.isEmpty ? peers.first : nil) {
                self.connect(p)
            }
        }
    }

    private func adopt(_ conn: NWConnection, initiator: Bool) {
        if connection != nil { conn.cancel(); return } // first-wins: keep the existing connection
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.dbg("conn state=\(state) initiator=\(initiator)")
            switch state {
            case .ready:
                self.directReceiver = BoundedControlReceiver()
                self.relayFallbackWorkItem?.cancel()
                self.relayPolicy.directConnected()
                self.relayTransport.disconnect()
                self.relayConnected = false
                self.setRelayStatus(self.relayEnabled ? "Direct connection active" : "Disabled")
                self.setStatus(.connected)
                if initiator { self.send(Message(id: UUID().uuidString, type: MessageTypes.linkHello)) }
                self.receive(on: conn)
                self.startHeartbeat(conn)
            case .failed, .cancelled:
                if self.connection === conn {
                    self.connection = nil
                    DispatchQueue.main.async { self.screenImage = nil }
                    self.setStatus(.disconnected)
                    if !self.sleeping {
                        self.scheduleReconnect()
                        self.scheduleRelayFallback()
                    }
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        // A dial to a stale endpoint can hang in .preparing indefinitely — cancel after 6s
        // so the reconnect loop retries with a freshly discovered endpoint.
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.connection === conn, self.status != .connected else { return }
            conn.cancel()
        }
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.directReceiver.ingest(data) { self.route(message) }
                } catch {
                    LinkLogger.securityEvent("direct_receive_rejected", ["reason": String(describing: error)])
                    conn.cancel()
                    return
                }
            }
            if error != nil || isComplete {
                // A graceful peer close (FIN) never fires .failed — cancel explicitly
                // or we're left with a zombie "connected" state that blocks reconnects.
                self.dbg("rx ended err=\(error.map { "\($0)" } ?? "nil") complete=\(isComplete) → cancel")
                conn.cancel()
                return
            }
            self.receive(on: conn)
        }
    }

    private func route(_ message: Message) {
        func f(_ key: String) -> String {
            switch message.payload[key] {
            case .string(let v)?: return v
            case .int(let n)?: return String(n)
            default: return ""
            }
        }
        switch message.type {
        case MessageTypes.clipUpdate:
            let text = f("text")
            DispatchQueue.main.async {
                self.lastClipboard = text
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                self.lastPasteboardChange = pb.changeCount
            }
            pushEvent("📋 Clipboard received")
        case MessageTypes.notifPosted:
            pushEvent("🔔 \(f("title")): \(f("text"))")
            postNotification(title: f("title"), body: f("text"))
        case MessageTypes.smsReceived:
            pushEvent("✉️ SMS \(f("address")): \(f("body"))")
            postNotification(title: "SMS from \(f("address"))", body: f("body"))
        case MessageTypes.callIncoming:
            let who = f("contactName").isEmpty ? f("number") : f("contactName")
            pushEvent("📞 Incoming call: \(who)")
            let number = f("number")
            currentCallNumber = number
            currentCallName = who
            // No toast here: the interactive call panel below IS the incoming-call UI, and it
            // replaces itself. Android fires the RINGING broadcast twice (first without the
            // number, second with it) — a toast would stack into a duplicate; the panel doesn't.
            DispatchQueue.main.async { self.incomingCallSubject.send((number: number, name: who)) }
        case MessageTypes.callState:
            // Trust our own tracked call for the number/name (OFFHOOK/IDLE carry none reliably);
            // fall back to whatever the phone sent if we have nothing.
            let state = f("state")
            if currentCallNumber.isEmpty && !f("number").isEmpty {
                currentCallNumber = f("number")
                currentCallName = f("contactName").isEmpty ? f("number") : f("contactName")
            }
            let number = currentCallNumber, name = currentCallName
            pushEvent("📞 Call \(state): \(name.isEmpty ? "unknown" : name)")
            if state == "ended" { currentCallNumber = ""; currentCallName = "" }
            DispatchQueue.main.async { self.callStateSubject.send((state: state, number: number, name: name)) }
        case MessageTypes.fileOffer:
            incomingFile = (f("name"), Data())
            pushEvent("📎 Receiving \(f("name"))…")
        case MessageTypes.fileChunk:
            if var inf = incomingFile, let d = Data(base64Encoded: f("data")) {
                inf.data.append(d)
                incomingFile = inf
                if f("last") == "true" {
                    let file = saveIncomingFile(name: inf.name, data: inf.data)
                    DispatchQueue.main.async { self.receivedFiles.insert(file, at: 0) }
                    pushEvent("📎 Received \(inf.name)")
                    postNotification(title: "File received", body: "Click to open \(inf.name)", userInfo: ["action": "openFile", "path": file.url.path])
                    incomingFile = nil
                }
            }
        case MessageTypes.screenFrame:
            if let data = Data(base64Encoded: f("data")), let img = NSImage(data: data) {
                DispatchQueue.main.async { self.screenImage = img }
            }
        case MessageTypes.meetingStart:
            let meetingId = f("meetingId")
            let startedAt = Int(f("startedAt")) ?? Int(Date().timeIntervalSince1970 * 1000)
            meetingStartTimes[meetingId] = startedAt
            activeMeetingIds.insert(meetingId)
            meetingStore.markStarted(meetingId: meetingId, startedAtMs: startedAt)
            meetingStore.setProcessingState(meetingId: meetingId, state: .recording)
            refreshMeetings()
            pushEvent("🎙️ Meeting started")
            send(Message(id: UUID().uuidString, type: MessageTypes.meetingProcessingStatus, payload: ["meetingId": .string(meetingId), "state": .string("receiving")]))
        case MessageTypes.meetingStop:
            beginPhoneMeetingFinalization(meetingId: f("meetingId"), endedAtMs: Int(f("endedAt")) ?? Int(Date().timeIntervalSince1970 * 1000))
        case MessageTypes.meetingAudioChunkOffer:
            let meetingId = f("meetingId")
            if !meetingId.isEmpty && !activeMeetingIds.contains(meetingId) {
                let startedAt = Int(f("startedAtMs")) ?? Int(Date().timeIntervalSince1970 * 1000)
                meetingStartTimes[meetingId] = startedAt
                activeMeetingIds.insert(meetingId)
                meetingStore.markStarted(meetingId: meetingId, startedAtMs: startedAt)
                meetingStore.setProcessingState(meetingId: meetingId, state: .recording)
                refreshMeetings()
                pushEvent("🎙️ Meeting detected from audio chunk")
            }
            handleMeetingAudioChunk(message, f)
        case MessageTypes.meetingPhotoOffer:
            handleMeetingPhoto(message, f)
        case MessageTypes.inputTap:
            performMacTap(x: Double(f("x")) ?? 0, y: Double(f("y")) ?? 0, w: Double(f("w")) ?? 1, h: Double(f("h")) ?? 1)
        case MessageTypes.inputSwipe:
            performMacSwipe(x1: Double(f("x1")) ?? 0, y1: Double(f("y1")) ?? 0, x2: Double(f("x2")) ?? 0, y2: Double(f("y2")) ?? 0, w: Double(f("w")) ?? 1, h: Double(f("h")) ?? 1)
        case MessageTypes.screenStart: pushEvent("🖥️ Screen mirror requested (stream \(f("streamId")))")
        default: break
        }
    }

    private func beginPhoneMeetingFinalization(meetingId: String, endedAtMs: Int) {
        guard !meetingId.isEmpty else { return }
        meetingStore.markEnded(meetingId: meetingId, endedAtMs: endedAtMs)
        meetingStore.setProcessingState(meetingId: meetingId, state: .finalizing)
        meetingStartTimes.removeValue(forKey: meetingId)
        activeMeetingIds.remove(meetingId)
        clearLongMeetingWatchdog(meetingId)
        DispatchQueue.main.async { self.phoneMeetingActive = false }
        refreshMeetings()
        pushEvent("📝 Recording stopped — finalizing in background")
        meetingProcessingQueue.async {
            self.meetingFinalizationQueue.async {
                let notes = self.meetingStore.finalizeMeeting(meetingId: meetingId, photos: self.meetingPhotos[meetingId] ?? [])
                self.completeFinalization(notesURL: notes, sourceMeetingId: meetingId)
            }
        }
    }

    private func completeFinalization(notesURL: URL, sourceMeetingId: String?) {
        let directory = notesURL.deletingLastPathComponent()
        guard let meeting = meetingStore.listMeetings().first(where: { $0.url.standardizedFileURL == directory.standardizedFileURL }) else { return }
        let state = processingOutcome(for: meeting)
        meetingStore.setProcessingState(in: directory, state: state)
        refreshMeetings()
        pushEvent(state == .ready ? "📝 Meeting notes ready" : "⚠️ Transcript saved; summary needs attention")
        if let sourceMeetingId {
            send(Message(id: UUID().uuidString, type: MessageTypes.meetingNotesReady, payload: ["meetingId": .string(sourceMeetingId), "path": .string(notesURL.path)]))
            meetingPhotos.removeValue(forKey: sourceMeetingId)
        }
        enrichMeetingFromCalendar(meeting)
    }

    private func handleMeetingAudioChunk(_ message: Message, _ f: (String) -> String) {
        let meetingId = f("meetingId")
        let sequence = Int(f("sequence")) ?? 0
        guard let data = Data(base64Encoded: f("data")), !meetingId.isEmpty else { return }
        let file = meetingStore.saveAudio(meetingId: meetingId, sequence: sequence, data: data)
        let checksum = f("checksum")
        let base = meetingStartTimes[meetingId] ?? (Int(f("startedAtMs")) ?? 0)
        let startMs = max(0, (Int(f("startedAtMs")) ?? base) - base)
        let endMs = max(startMs, (Int(f("endedAtMs")) ?? base) - base)
        send(Message(id: UUID().uuidString, type: MessageTypes.meetingAudioChunkReceived, payload: ["meetingId": .string(meetingId), "sequence": .int(sequence), "checksum": .string(checksum)]))
        pushEvent("🎙️ Meeting chunk \(sequence) received; transcribing…")
        meetingProcessingQueue.async {
            let segment = self.whisper.transcribe(file: file, startMs: startMs, endMs: endMs)
            self.meetingStore.appendTranscript(meetingId: meetingId, segment: segment)
            _ = self.meetingStore.writeNotesIncremental(meetingId: meetingId, newSegments: [segment], photos: self.meetingPhotos[meetingId] ?? [])
            self.refreshMeetings()
            self.pushEvent("📝 Summary updated from chunk \(sequence)")
        }
    }

    private func handleMeetingPhoto(_ message: Message, _ f: (String) -> String) {
        let meetingId = f("meetingId")
        let photoId = f("photoId")
        guard let data = Data(base64Encoded: f("data")), !meetingId.isEmpty, !photoId.isEmpty else { return }
        let url = meetingStore.savePhoto(meetingId: meetingId, photoId: photoId, data: data)
        let base = meetingStartTimes[meetingId] ?? (Int(f("capturedAtMs")) ?? 0)
        let capturedAtMs = max(0, (Int(f("capturedAtMs")) ?? base) - base)
        let photo = MeetingPhoto(photoId: photoId, capturedAtMs: capturedAtMs, fileName: url.lastPathComponent)
        meetingPhotos[meetingId, default: []].append(photo)
        meetingProcessingQueue.async {
            _ = self.meetingStore.writeNotes(meetingId: meetingId, photos: self.meetingPhotos[meetingId] ?? [])
            self.refreshMeetings()
        }
        send(Message(id: UUID().uuidString, type: MessageTypes.meetingPhotoReceived, payload: ["meetingId": .string(meetingId), "photoId": .string(photoId), "checksum": .string(f("checksum"))]))
        pushEvent("📷 Meeting photo received")
    }

    private func receivedFilesDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AndroidBridge/Received", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanReceivedFiles() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let dir = receivedFilesDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func saveIncomingFile(name: String, data: Data) -> ReceivedFile {
        cleanReceivedFiles()
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        let base = receivedFilesDirectory().appendingPathComponent(safeName)
        let url = uniqueURL(base)
        try? data.write(to: url)
        return ReceivedFile(name: url.lastPathComponent, url: url, receivedAt: Date())
    }

    private func uniqueURL(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for i in 2...999 {
            var candidate = dir.appendingPathComponent("\(stem) \(i)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
    }

    public func copyReceivedFile(_ file: ReceivedFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([file.url as NSURL])
        pushEvent("📋 Copied \(file.name)")
    }

    public func startMeetingOnMac() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startAuthorizedMacRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted { self.startAuthorizedMacRecording() }
                else { self.pushEvent("⚠️ Microphone access is required — enable it in System Settings → Privacy & Security → Microphone") }
            }
        default:
            pushEvent("⚠️ Microphone access is required — enable it in System Settings → Privacy & Security → Microphone")
        }
    }

    private func startAuthorizedMacRecording() {
        guard let id = macRecorder.start() else {
            pushEvent("⚠️ Mac recording failed to start")
            return
        }
        let startedAt = Int(Date().timeIntervalSince1970 * 1000)
        meetingStartTimes[id] = startedAt
        meetingStore.markStarted(meetingId: id, startedAtMs: startedAt)
        meetingStore.setProcessingState(meetingId: id, state: .recording)
        activeMeetingIds.insert(id)
        DispatchQueue.main.async { self.macMeetingActive = true }
        refreshMeetings()
        pushEvent("🎙️ Mac recording started")
    }

    public func stopMeetingOnMac() {
        // The recorder's `onStopped` callback does the bookkeeping, so this is
        // also correct when the recorder already stopped itself.
        _ = macRecorder.stop()
    }

    /// Clears every trace of an active Mac meeting. Safe to call twice.
    private func finishMacMeeting(_ meetingId: String) {
        guard activeMeetingIds.contains(meetingId) || macMeetingActive else { return }
        let endedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        meetingStore.markEnded(meetingId: meetingId, endedAtMs: endedAtMs)
        meetingStore.setProcessingState(meetingId: meetingId, state: .finalizing)
        activeMeetingIds.remove(meetingId)
        meetingStartTimes.removeValue(forKey: meetingId)
        clearLongMeetingWatchdog(meetingId)
        zoomAutoMeetingActive = false
        autoMeetingMissingSince = nil
        DispatchQueue.main.async { self.macMeetingActive = false }
        refreshMeetings()
        pushEvent("📝 Mac recording stopped — finalizing in background")
    }

    public func startMeetingOnPhone(title: String = "") {
        let meetingId = UUID().uuidString
        macStartedMeetingId = meetingId
        let startedAt = Int(Date().timeIntervalSince1970 * 1000)
        meetingStartTimes[meetingId] = startedAt
        activeMeetingIds.insert(meetingId)
        meetingStore.markStarted(meetingId: meetingId, startedAtMs: startedAt)
        meetingStore.setProcessingState(meetingId: meetingId, state: .recording)
        DispatchQueue.main.async { self.phoneMeetingActive = true }
        refreshMeetings()
        send(Message(id: UUID().uuidString, type: MessageTypes.meetingStart, payload: ["meetingId": .string(meetingId), "title": .string(title), "startedAt": .int(meetingStartTimes[meetingId] ?? 0)]))
        pushEvent("🎙️ Started phone recording from Mac")
    }

    public func stopMeetingOnPhone() {
        guard let meetingId = macStartedMeetingId else { return }
        send(Message(id: UUID().uuidString, type: MessageTypes.meetingStop, payload: ["meetingId": .string(meetingId), "endedAt": .int(Int(Date().timeIntervalSince1970 * 1000))]))
        macStartedMeetingId = nil
        DispatchQueue.main.async { self.phoneMeetingActive = false }
        pushEvent("🎙️ Stop requested from Mac")
    }

    public func openMeetingsFolder() {
        refreshMeetings()
        NSWorkspace.shared.open(meetingStore.rootURL)
    }

    public func openMeeting(_ meeting: MeetingRecord) {
        NSWorkspace.shared.open(meeting.url)
    }

    public func openMeetingNotes(_ meeting: MeetingRecord) {
        if let notes = meeting.notesURL { NSWorkspace.shared.open(notes) }
        else { NSWorkspace.shared.open(meeting.url) }
    }

    public func deleteMeeting(_ meeting: MeetingRecord) {
        if let path = meeting.brainPath { try? brainStore.deleteNote(path: path) }
        meetingStore.deleteMeeting(meeting)
        refreshMeetings()
        refreshBrain()
    }

    public func renameMeeting(_ meeting: MeetingRecord, to newName: String) {
        meetingStore.renameMeeting(meeting, to: newName)
        refreshMeetings()
    }

    public func changeMeetingCompany(_ meeting: MeetingRecord, to company: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let clean = company.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                self.meetingStore.setCompany(meeting, to: "")
                self.refreshMeetings()
                return
            }
            do {
                let client = try self.canonicalCustomer(clean)
                if let oldPath = meeting.brainPath {
                    let path = try SecondBrainExporter().transfer(meeting: meeting, client: client)
                    self.meetingStore.setCompany(meeting, to: client)
                    self.meetingStore.setBrainPath(meeting, to: path)
                    if oldPath != path { try? self.brainStore.deleteNote(path: oldPath) }
                    self.pushEvent("🧠 Updated transferred meeting customer")
                } else {
                    self.meetingStore.setCompany(meeting, to: client)
                }
                self.refreshMeetings()
            } catch {
                DispatchQueue.main.async { self.customerStatus = error.localizedDescription }
            }
        }
    }

    private func canonicalCustomer(_ name: String) throws -> String {
        let stored = try customerStore.addCustomer(name)
        return SecondBrainExporter().canonicalClientName(stored)
    }

    public func mergeMeetingRecordings(_ meeting: MeetingRecord) {
        pushEvent("🎧 Merging recording chunks…")
        meetingStore.mergeRecordings(meeting) { result in
            switch result {
            case .success(let url):
                self.refreshMeetings()
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                self.pushEvent("🎧 Created one merged recording")
            case .failure(let error):
                self.pushEvent("⚠️ Recording merge failed: \(error.localizedDescription)")
            }
        }
    }

    /// Recover a meeting whose chunks were saved but never transcribed.
    public func retranscribeMeeting(_ meeting: MeetingRecord) {
        DispatchQueue.main.async { self.regeneratingSummaryIds.insert(meeting.id) }
        DispatchQueue.global(qos: .userInitiated).async {
            self.meetingStore.retranscribeMeeting(meeting)
            self.refreshMeetings()
            DispatchQueue.main.async { self.regeneratingSummaryIds.remove(meeting.id) }
            self.pushEvent("📝 Re-transcribed \"\(meeting.title)\"")
        }
    }

    public func regenerateMeetingSummary(_ meeting: MeetingRecord) {
        DispatchQueue.main.async { self.regeneratingSummaryIds.insert(meeting.id) }
        meetingStore.setProcessingState(in: meeting.url, state: .finalizing)
        DispatchQueue.global(qos: .userInitiated).async {
            self.meetingStore.regenerateSummary(meeting)
            let refreshed = self.meetingStore.listMeetings().first { $0.url.standardizedFileURL == meeting.url.standardizedFileURL }
            let state = refreshed.map(self.processingOutcome) ?? .needsAttention
            self.meetingStore.setProcessingState(in: meeting.url, state: state)
            self.refreshMeetings()
            self.pushEvent(state == .ready ? "📝 Summary regenerated" : "⚠️ Summary generation failed; check the Summarize model")
            DispatchQueue.main.async { self.regeneratingSummaryIds.remove(meeting.id) }
        }
    }

    private func processingOutcome(for meeting: MeetingRecord) -> MeetingProcessingState {
        let hasRecordedContent = !meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !meeting.audioFiles.isEmpty
        return hasRecordedContent && meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .needsAttention : .ready
    }

    public func backfillMissingSummaries(force: Bool = false) {
        guard !summaryBackfillRunning else {
            summaryBackfillStatus = "A backfill run is already in progress — wait for it to finish."
            return
        }
        summaryBackfillRunning = true
        summaryBackfillStatus = "Checking for missing summaries…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.meetingStore.backfillMissingSummaries(force: force, onProgress: { index, total in
                DispatchQueue.main.async { self.summaryBackfillStatus = "Processing meeting \(index) of \(total) (transcribing if needed)…" }
            })
            self.refreshMeetings()
            DispatchQueue.main.async {
                self.summaryBackfillRunning = false
                if result.attempted == 0 {
                    self.summaryBackfillStatus = "All meetings already have a summary."
                } else if result.completed < result.attempted {
                    self.summaryBackfillStatus = "Generated \(result.completed) of \(result.attempted) summaries. Check the selected provider and model."
                } else {
                    self.summaryBackfillStatus = result.completed == 1 ? "Generated 1 missing summary." : "Generated \(result.completed) missing summaries."
                }
            }
        }
    }

    public func renameSpeaker(_ meeting: MeetingRecord, from oldName: String, to newName: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.meetingStore.renameSpeaker(meeting, from: oldName, to: newName)
            self.refreshMeetings()
        }
    }

    public func shareMeeting(_ meeting: MeetingRecord) {
        let item = meeting.notesURL ?? meeting.url
        DispatchQueue.main.async {
            guard let view = NSApp.keyWindow?.contentView else { return }
            NSSharingServicePicker(items: [item]).show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

    public func refreshBrain(loadMap: Bool = false, refreshSelectedContent: Bool = true) {
        let path = selectedBrainPath
        let existingEdges = brainEdges
        brainRefreshQueue.async {
            self.loadBrain(path: path, loadMap: loadMap, existingEdges: existingEdges, refreshSelectedContent: refreshSelectedContent)
        }
    }

    public func refreshBrainIfChanged(loadMap: Bool = false, refreshSelectedContent: Bool = true) {
        let path = selectedBrainPath
        let existingEdges = brainEdges
        brainRefreshQueue.async {
            guard self.brainStore.revision() != self.lastBrainRevision else { return }
            self.loadBrain(path: path, loadMap: loadMap, existingEdges: existingEdges, refreshSelectedContent: refreshSelectedContent)
        }
    }

    private func loadBrain(path: String, loadMap: Bool, existingEdges: [BrainEdge], refreshSelectedContent: Bool) {
        do {
            let frames = try brainSync?.scan() ?? []
            sendBrainSyncFrames(frames)
            let nodes = try brainStore.tree()
            let edges = loadMap ? brainStore.edges() : existingEdges
            let content = refreshSelectedContent ? try brainStore.show(path) : nil
            let status = "\(nodes.filter { !$0.isDirectory }.count) notes • refreshed \(Date().formatted(date: .omitted, time: .shortened))"
            lastBrainRevision = brainStore.revision()
            DispatchQueue.main.async {
                self.brainNodes = nodes
                self.brainEdges = edges
                if let content { self.selectedBrainContent = content }
                self.brainStatus = status
            }
        } catch {
            brainFailure("Refresh", error)
        }
    }

    private func sendBrainSyncFrames(_ frames: [Data]) {
        guard !frames.isEmpty else { return }
        queue.async {
            guard self.relayConnected, self.connection == nil else { return }
            do {
                for frame in frames { try self.relayTransport.send(frame) }
            } catch {
                self.setRelayStatus(error.localizedDescription)
                self.relayTransport.disconnect()
            }
        }
    }

    private func brainFailure(_ action: String, _ error: Error) {
        let message = "\(action) failed. Check the Second Brain root and try again."
        DispatchQueue.main.async { self.brainStatus = message }
        pushEvent("🧠 \(message)")
        dbg("SECOND_BRAIN action=\(action) error=\(String(describing: type(of: error)))")
    }

    public func loadBrainMap() {
        DispatchQueue.global(qos: .utility).async {
            let edges = self.brainStore.edges()
            DispatchQueue.main.async { self.brainEdges = edges }
        }
    }

    public func openSecondBrainFolder() { NSWorkspace.shared.open(brainStore.rootURL) }

    public func selectBrainNode(_ path: String) {
        selectedBrainPath = path
        DispatchQueue.global(qos: .utility).async {
            do {
                let content = try self.brainStore.show(path)
                DispatchQueue.main.async { self.selectedBrainContent = content }
            } catch { self.brainFailure("Read", error) }
        }
    }

    public func searchBrain(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let results = try self.brainStore.search(clean)
                DispatchQueue.main.async { self.brainSearchResults = results }
            } catch { self.brainFailure("Search", error) }
        }
    }

    public func clearBrainSearch() {
        DispatchQueue.main.async { self.brainSearchResults = [] }
    }

    public func saveBrainNode(_ content: String, completion: ((Bool) -> Void)? = nil) {
        let path = selectedBrainPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.brainStore.save(path: path, content: content)
                self.refreshBrain()
                self.pushEvent("🧠 Saved \(path)")
                DispatchQueue.main.async { completion?(true) }
            } catch {
                self.brainFailure("Save", error)
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    public func addBrainNote(cluster: String, title: String, body: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.brainStore.addNote(cluster: cluster, title: title, summary: title, tags: "android-bridge", body: body)
                self.refreshBrain()
            } catch { self.brainFailure("Add note", error) }
        }
    }

    public func deleteSelectedBrainNote() {
        let path = selectedBrainPath
        guard path.hasSuffix(".md"), !path.hasSuffix("index.md") else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.brainStore.deleteNote(path: path)
                DispatchQueue.main.async { self.selectedBrainPath = "index.md" }
                self.refreshBrain()
            } catch { self.brainFailure("Delete", error) }
        }
    }

    public func askBrain(_ question: String) {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let path = selectedBrainPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let answer = try self.brainStore.answer(path: path, question: clean)
                let entry = "## Q: \(clean)\n\n\(answer)\n\n"
                DispatchQueue.main.async { self.brainChat = entry + self.brainChat }
            } catch { self.brainFailure("Chat", error) }
        }
    }

    public func transferToSecondBrain(_ meeting: MeetingRecord, client: String) {
        DispatchQueue.main.async { self.brainTransferIds.insert(meeting.id) }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let client = try self.canonicalCustomer(client)
                let path = try SecondBrainExporter().transfer(meeting: meeting, client: client)
                self.meetingStore.setCompany(meeting, to: client)
                self.meetingStore.setBrainPath(meeting, to: path)
                self.refreshMeetings()
                self.pushEvent("🧠 Transferred meeting to Second Brain")
            } catch {
                self.brainFailure("Meeting transfer", error)
            }
            DispatchQueue.main.async { self.brainTransferIds.remove(meeting.id) }
        }
    }

    public func requestCalendarAccess() {
        DispatchQueue.main.async { self.calendarAccessMessage = "Requesting Calendar access…" }
        calendarService.requestAccess { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.calendarAccessMessage = "Calendar access is on."
                    self.refreshCalendars()
                case .failure(let error): self.calendarAccessMessage = error.localizedDescription
                }
            }
        }
    }

    public func refreshCalendars() {
        calendarService.calendars { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let calendars): self.availableCalendars = calendars
                case .failure(let error): self.calendarAccessMessage = error.localizedDescription
                }
            }
        }
    }

    public func setMainCalendarIdentifier(_ identifier: String) {
        mainCalendarIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: "meeting.mainCalendarIdentifier")
    }

    public func enrichMeetingFromCalendar(_ meeting: MeetingRecord) {
        DispatchQueue.main.async { self.calendarMessages[meeting.id] = "Checking Calendar…" }
        let end = meeting.endDate ?? meeting.date.addingTimeInterval(60 * 60)
        if mainCalendarIdentifier.isEmpty {
            fetchCalendarEvents(meeting: meeting, end: end, calendarIdentifier: nil, fallback: false)
        } else {
            fetchCalendarEvents(meeting: meeting, end: end, calendarIdentifier: mainCalendarIdentifier, fallback: true)
        }
    }

    private func fetchCalendarEvents(meeting: MeetingRecord, end: Date, calendarIdentifier: String?, fallback: Bool) {
        calendarService.events(overlapping: meeting.date, end: end, calendarIdentifier: calendarIdentifier, tolerance: 15 * 60) { result in
            switch result {
            case .failure(let error): self.calendarFailure(error, meetingId: meeting.id)
            case .success(let events):
                if events.isEmpty, fallback {
                    self.fetchCalendarEvents(meeting: meeting, end: end, calendarIdentifier: nil, fallback: false)
                } else {
                    DispatchQueue.main.async { self.calendarAccessMessage = "Calendar access is on." }
                    self.handleCalendarMatches(events, for: meeting)
                }
            }
        }
    }

    private func calendarFailure(_ error: Error, meetingId: String) {
        DispatchQueue.main.async {
            self.calendarAccessMessage = error.localizedDescription
            self.calendarMessages[meetingId] = error.localizedDescription
        }
    }

    private func unassignedEvents(_ events: [MeetingCalendarEvent], excluding meeting: MeetingRecord) -> [MeetingCalendarEvent] {
        let assignedEvents = Set(meetingStore.listMeetings().filter { $0.id != meeting.id }.compactMap { record in
            record.calendarEvent.map { "\($0.id)|\($0.start.timeIntervalSince1970)" }
        })
        return events.filter { !assignedEvents.contains("\($0.id)|\($0.start.timeIntervalSince1970)") }
    }

    /// Lists every calendar event on one day so an older recording can be matched by hand.
    public func browseCalendarEvents(for meeting: MeetingRecord, day: Date) {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let label = dayStart.formatted(date: .abbreviated, time: .omitted)
        DispatchQueue.main.async {
            self.calendarBrowseDay[meeting.id] = dayStart
            self.calendarMessages[meeting.id] = "Loading \(label)…"
        }
        let identifier = mainCalendarIdentifier.isEmpty ? nil : mainCalendarIdentifier
        calendarService.events(from: dayStart, to: dayEnd, calendarIdentifier: identifier) { result in
            switch result {
            case .failure(let error): self.calendarFailure(error, meetingId: meeting.id)
            case .success(let events):
                let available = self.unassignedEvents(events, excluding: meeting)
                DispatchQueue.main.async {
                    self.calendarAccessMessage = "Calendar access is on."
                    self.calendarCandidates[meeting.id] = available
                    self.calendarMessages[meeting.id] = available.isEmpty
                        ? "No free calendar events on \(label). Step to another day."
                        : "\(available.count) calendar event(s) on \(label). Choose one or step to another day."
                }
            }
        }
    }

    /// Moves the browsed day, so the user can walk backwards through past meetings.
    public func stepCalendarBrowse(for meeting: MeetingRecord, days: Int) {
        let base = calendarBrowseDay[meeting.id] ?? Calendar.current.startOfDay(for: meeting.date)
        let next = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
        browseCalendarEvents(for: meeting, day: next)
    }

    private func handleCalendarMatches(_ events: [MeetingCalendarEvent], for meeting: MeetingRecord) {
        let availableEvents = unassignedEvents(events, excluding: meeting)
        DispatchQueue.main.async {
            self.calendarBrowseDay[meeting.id] = Calendar.current.startOfDay(for: meeting.date)
            self.calendarCandidates[meeting.id] = availableEvents
            if events.isEmpty {
                self.calendarMessages[meeting.id] = "No overlapping calendar event found."
            } else if availableEvents.isEmpty {
                self.calendarMessages[meeting.id] = "The overlapping calendar event is already assigned to another recording."
            } else {
                self.calendarMessages[meeting.id] = "Choose a calendar event or keep this recording unassigned."
            }
            self.calendarReviewSubject.send(MeetingCalendarReview(meeting: meeting, events: availableEvents))
        }
    }

    public func selectCalendarEvent(_ event: MeetingCalendarEvent, for meeting: MeetingRecord) {
        applyCalendarEvent(event, to: meeting)
    }

    public func saveMeetingReview(event: MeetingCalendarEvent?, customer: String, for meeting: MeetingRecord) {
        let customerName = customer.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            if let event {
                guard self.meetingStore.setCalendarEvent(event, for: meeting) else {
                    DispatchQueue.main.async { self.calendarMessages[meeting.id] = "Could not save calendar details. Try again." }
                    self.postNotification(title: "Calendar meeting not saved", body: "Could not save calendar details. Try again.")
                    return
                }
                if !self.meetingStore.hasTitleOverride(meeting) {
                    self.meetingStore.setTitleOverride(meeting, to: event.title)
                }
            } else {
                self.meetingStore.clearCalendarEvent(for: meeting)
            }

            do {
                if customerName.isEmpty {
                    self.meetingStore.setCompany(meeting, to: "")
                } else {
                    let canonical = try self.canonicalCustomer(customerName)
                    self.meetingStore.setCompany(meeting, to: canonical)
                    if let event { try self.customerStore.remember(event: event, customer: canonical) }
                }
                self.refreshMeetings()
                DispatchQueue.main.async {
                    self.calendarCandidates.removeValue(forKey: meeting.id)
                    self.calendarBrowseDay.removeValue(forKey: meeting.id)
                    self.calendarMessages[meeting.id] = event == nil ? "Client details saved." : "Calendar meeting details saved."
                }
            } catch {
                DispatchQueue.main.async { self.customerStatus = error.localizedDescription }
                self.postNotification(title: "Client not saved", body: error.localizedDescription)
            }
        }
    }

    private func applyCalendarEvent(_ event: MeetingCalendarEvent, to meeting: MeetingRecord) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard self.meetingStore.setCalendarEvent(event, for: meeting) else {
                DispatchQueue.main.async { self.calendarMessages[meeting.id] = "Could not save calendar details. Try again." }
                return
            }
            if !self.meetingStore.hasTitleOverride(meeting) {
                self.meetingStore.setTitleOverride(meeting, to: event.title)
            }
            let needsCustomer = meeting.company.isEmpty && !self.resolveCustomer(event: event, meeting: meeting)
            self.refreshMeetings()
            DispatchQueue.main.async {
                self.calendarCandidates.removeValue(forKey: meeting.id)
                self.calendarBrowseDay.removeValue(forKey: meeting.id)
                self.calendarMessages[meeting.id] = needsCustomer ? "Calendar details added. Choose a customer." : "Calendar details added."
                if needsCustomer {
                    self.pendingCustomerEvents[meeting.id] = event
                    if self.customerPromptMeetingId == nil { self.customerPromptMeetingId = meeting.id }
                }
            }
        }
    }

    private func resolveCustomer(event: MeetingCalendarEvent, meeting: MeetingRecord) -> Bool {
        do {
            let catalog = try customerStore.customers(meetingNames: meetingStore.listMeetings().map(\.company))
            let associations = try customerStore.associations()
            guard let customer = MeetingCustomerMatcher.resolve(event: event, customers: catalog, associations: associations) else { return false }
            meetingStore.setCompany(meeting, to: customer)
            return true
        } catch {
            DispatchQueue.main.async { self.customerStatus = error.localizedDescription }
            return false
        }
    }

    public func confirmCustomer(_ customer: String, for meeting: MeetingRecord) {
        let event = pendingCustomerEvents[meeting.id]
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let canonical = try self.canonicalCustomer(customer)
                self.meetingStore.setCompany(meeting, to: canonical)
                if let event { try self.customerStore.remember(event: event, customer: canonical) }
                DispatchQueue.main.async { self.finishCustomerPrompt(meetingId: meeting.id) }
                self.refreshMeetings()
            } catch {
                DispatchQueue.main.async { self.customerStatus = error.localizedDescription }
            }
        }
    }

    public func dismissCustomerPrompt(for meeting: MeetingRecord) {
        finishCustomerPrompt(meetingId: meeting.id)
    }

    private func finishCustomerPrompt(meetingId: String) {
        pendingCustomerEvents.removeValue(forKey: meetingId)
        if customerPromptMeetingId == meetingId {
            customerPromptMeetingId = pendingCustomerEvents.keys.sorted().first
        }
    }

    public func changeCustomerAssociation(_ association: MeetingCustomerAssociation, to customer: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.customerStore.changeAssociation(id: association.id, customer: customer)
                self.refreshMeetings()
            } catch {
                DispatchQueue.main.async { self.customerStatus = error.localizedDescription }
            }
        }
    }

    public func forgetCustomerAssociation(_ association: MeetingCustomerAssociation) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.customerStore.forgetAssociation(id: association.id)
                self.refreshMeetings()
            } catch {
                DispatchQueue.main.async { self.customerStatus = error.localizedDescription }
            }
        }
    }

    public func beginManualCalendarEntry(for meeting: MeetingRecord) {
        clearCalendarSelection(for: meeting, message: "Enter the title and customer manually.")
    }

    public func dismissCalendarCandidates(for meeting: MeetingRecord) {
        clearCalendarSelection(for: meeting, message: "No calendar event selected.")
    }

    private func clearCalendarSelection(for meeting: MeetingRecord, message: String) {
        calendarCandidates.removeValue(forKey: meeting.id)
        calendarBrowseDay.removeValue(forKey: meeting.id)
        calendarMessages[meeting.id] = message
        DispatchQueue.global(qos: .userInitiated).async {
            self.meetingStore.clearCalendarEvent(for: meeting)
            self.refreshMeetings()
        }
    }

    public func retryMeetingFinalization(_ meeting: MeetingRecord) {
        meetingStore.setProcessingState(in: meeting.url, state: .finalizing)
        refreshMeetings()
        meetingFinalizationQueue.async {
            let notes = self.meetingStore.retryFinalization(meeting)
            self.completeFinalization(notesURL: notes, sourceMeetingId: nil)
        }
    }

    public func openCalendarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    public func loadMeetingChat(_ meeting: MeetingRecord) {
        meetingChatQueue.async {
            do {
                self.publishMeetingChat(try self.meetingStore.chatArchive(for: meeting), for: meeting.id)
            } catch {
                self.publishMeetingChatError(error, for: meeting.id)
            }
        }
    }

    public func startMeetingChatSession(_ meeting: MeetingRecord) {
        guard !meetingChatBusyIds.contains(meeting.id) else { return }
        meetingChatQueue.async {
            do {
                self.publishMeetingChat(try self.meetingStore.startChatSession(meeting), for: meeting.id)
                self.refreshMeetings()
            } catch {
                self.publishMeetingChatError(error, for: meeting.id)
            }
        }
    }

    public func selectMeetingChatSession(_ meeting: MeetingRecord, sessionId: String) {
        guard !meetingChatBusyIds.contains(meeting.id) else { return }
        meetingChatQueue.async {
            do {
                self.publishMeetingChat(try self.meetingStore.selectChatSession(meeting, sessionId: sessionId), for: meeting.id)
            } catch {
                self.publishMeetingChatError(error, for: meeting.id)
            }
        }
    }

    public func askMeetingQuestion(_ meeting: MeetingRecord, question: String) {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !meetingChatBusyIds.contains(meeting.id) else { return }
        meetingChatBusyIds.insert(meeting.id)
        meetingChatErrors.removeValue(forKey: meeting.id)
        meetingChatQueue.async {
            do {
                let archive = try self.meetingStore.answerQuestion(meeting, question: clean, onUserStored: {
                    self.publishMeetingChat($0, for: meeting.id)
                })
                self.publishMeetingChat(archive, for: meeting.id)
                self.refreshMeetings()
            } catch {
                self.publishStoredMeetingChat(meeting, after: error)
                self.refreshMeetings()
            }
            DispatchQueue.main.async { self.meetingChatBusyIds.remove(meeting.id) }
        }
    }

    private func publishMeetingChat(_ archive: MeetingChatArchive, for meetingId: String) {
        DispatchQueue.main.async {
            self.meetingChats[meetingId] = archive
            self.meetingChatErrors.removeValue(forKey: meetingId)
        }
    }

    private func publishStoredMeetingChat(_ meeting: MeetingRecord, after error: Error) {
        do {
            let archive = try meetingStore.chatArchive(for: meeting)
            DispatchQueue.main.async { self.meetingChats[meeting.id] = archive }
        } catch {
            publishMeetingChatError(error, for: meeting.id)
            return
        }
        publishMeetingChatError(error, for: meeting.id)
    }

    private func publishMeetingChatError(_ error: Error, for meetingId: String) {
        DispatchQueue.main.async { self.meetingChatErrors[meetingId] = error.localizedDescription }
    }

    public func mergeMeetings(_ meetings: [MeetingRecord], options: MeetingMergeOptions) {
        guard mergeStatus == nil else { return }
        mergeStatus = "Preparing merge…"
        DispatchQueue.global(qos: .userInitiated).async {
            let merged = self.meetingStore.mergeMeetings(meetings, options: options) { step in
                DispatchQueue.main.async { self.mergeStatus = step }
            }
            guard let dir = merged, self.meetingStore.hasReadableMeeting(at: dir) else {
                DispatchQueue.main.async { self.mergeStatus = nil }
                self.pushEvent("🔀 Merge failed")
                return
            }
            for meeting in meetings where !meeting.isActive { self.meetingStore.trashMeeting(meeting) }
            self.refreshMeetings()
            DispatchQueue.main.async { self.mergeStatus = nil }
            self.pushEvent("🔀 Merged \(meetings.count) meetings into \(dir.lastPathComponent)")
        }
    }

    public func deleteReceivedFile(_ file: ReceivedFile) {
        try? FileManager.default.removeItem(at: file.url)
        DispatchQueue.main.async { self.receivedFiles.removeAll { $0.id == file.id } }
        pushEvent("🗑️ Deleted \(file.name)")
    }

    public func handleNotificationClick(_ userInfo: [AnyHashable: Any]) {
        guard let action = userInfo["action"] as? String else { return }
        if action == "openFile", let path = userInfo["path"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        if action == "copyClipboard", let text = userInfo["text"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            pushEvent("📋 Copied clipboard notification")
        }
        if action == "openScreenRecordingSettings" {
            openScreenRecordingSettings()
        }
    }

    public func requestScreenRecordingAccess() {
        DispatchQueue.main.async {
            if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
                self.pushEvent("✅ Screen Recording access is on")
            } else {
                self.pushEvent("⚠️ Allow Screen Recording, then relaunch Android Bridge")
                self.openScreenRecordingSettings()
            }
        }
    }

    public func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Send a file to the peer, chunked (offer + chunks).
    public func sendFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        send(Message(id: UUID().uuidString, type: MessageTypes.fileOffer,
                     payload: ["name": .string(name), "size": .int(data.count)]))
        var offset = 0
        var seq = 0
        let chunk = 48 * 1024
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            let slice = data.subdata(in: offset..<end)
            let last = end == data.count
            send(Message(id: UUID().uuidString, type: MessageTypes.fileChunk,
                         payload: ["seq": .int(seq), "data": .string(slice.base64EncodedString()), "last": .string(last ? "true" : "false")]))
            offset = end; seq += 1
        }
        pushEvent("📎 Sent \(name) (\(data.count) B)")
    }

    // MARK: - Mac screen capture (two-way, U8)

    public func startScreenShare() {
        dbg("SCREEN share requested connected=\(connection != nil) preflight=\(CGPreflightScreenCaptureAccess())")
        pushEvent("🖥️ Share Mac screen requested")
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        warnedScreenCapture = false
        captureGeneration += 1
        let generation = captureGeneration
        captureActive = true
        DispatchQueue.main.async { self.screenSharing = true }
        queue.async { self.captureLoop(generation: generation) }
    }

    public func stopScreenShare() {
        captureGeneration += 1
        captureActive = false
        DispatchQueue.main.async { self.screenSharing = false }
    }

    private func captureLoop(generation: Int) {
        guard captureActive, generation == captureGeneration else { return }
        if connection != nil || relayConnected, let cg = CGDisplayCreateImage(CGMainDisplayID()),
           let jpeg = Self.jpeg(from: cg, maxWidth: 360, quality: 0.25) {
            let scale = 360.0 / Double(cg.width)
            if !warnedScreenCapture {
                warnedScreenCapture = true
                dbg("SCREEN sending frames jpeg=\(jpeg.count)")
                pushEvent("🖥️ Sending Mac screen frames")
            }
            send(Message(id: UUID().uuidString, type: MessageTypes.screenFrame,
                         payload: ["data": .string(jpeg.base64EncodedString()), "w": .int(360), "h": .int(Int(Double(cg.height) * scale))]))
        } else if !warnedScreenCapture {
            warnedScreenCapture = true
            captureActive = false
            DispatchQueue.main.async { self.screenSharing = false }
            postNotification(title: "Cannot capture Mac screen", body: "Click to open Screen Recording settings.", userInfo: ["action": "openScreenRecordingSettings"])
            dbg("SCREEN cannot capture connection=\(connection != nil)")
            pushEvent("🖥️ Cannot capture Mac screen")
        }
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.captureLoop(generation: generation) }
    }

    private func performMacTap(x: Double, y: Double, w: Double, h: Double) {
        let p = macPoint(x: x, y: y, w: w, h: h)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        pushEvent("🖱️ Phone tapped Mac")
    }

    private func performMacSwipe(x1: Double, y1: Double, x2: Double, y2: Double, w: Double, h: Double) {
        let a = macPoint(x: x1, y: y1, w: w, h: h)
        let b = macPoint(x: x2, y: y2, w: w, h: h)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: b, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left)?.post(tap: .cghidEventTap)
        pushEvent("🖱️ Phone dragged Mac")
    }

    private func macPoint(x: Double, y: Double, w: Double, h: Double) -> CGPoint {
        let display = CGMainDisplayID()
        return CGPoint(x: x / max(w, 1) * Double(CGDisplayPixelsWide(display)),
                       y: y / max(h, 1) * Double(CGDisplayPixelsHigh(display)))
    }

    private static func jpeg(from cg: CGImage, maxWidth: Int, quality: CGFloat) -> Data? {
        let scale = CGFloat(maxWidth) / CGFloat(cg.width)
        let w = maxWidth
        let h = Int(CGFloat(cg.height) * scale)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func send(_ message: Message) {
        if let conn = connection {
            guard let bytes = try? MessageCodec.encode(message) else { return }
            conn.send(content: Data(bytes), completion: .contentProcessed { [weak self] err in
                if err != nil { self?.dbg("send failed → cancel"); conn.cancel() }
            })
            return
        }
        queue.async {
            if self.connection != nil {
                self.send(message)
                return
            }
            guard self.relaySettings.enabled, let replaySession = self.replaySession else { return }
            do {
                let frames = try replaySession.enqueue(message)
                guard self.relayConnected else { return }
                for frame in frames { try self.relayTransport.send(frame) }
            } catch {
                self.setRelayStatus(error.localizedDescription)
            }
        }
    }

    private func txtValue(_ txt: NWTXTRecord, _ key: String) -> String? {
        if case let .string(v)? = txt.getEntry(for: key) { return v }
        return nil
    }

    private func setStatus(_ s: ConnectionState) {
        DispatchQueue.main.async { self.status = s }
    }
}
