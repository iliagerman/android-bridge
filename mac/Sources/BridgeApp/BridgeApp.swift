import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import BridgeCore

// SwiftUI views hosted in the AppKit windows created by AppDelegate (see main.swift).

/// Shared UI state so the AppKit tray/dock menus can drive the SwiftUI tab selection,
/// and so the window size the user picks per tab is remembered as the new default.
final class AppUIState: ObservableObject {
    static let shared = AppUIState()
    @Published var selectedTab = 0
    @Published var showSetup = !UserDefaults.standard.bool(forKey: "setupWizard.seen")
    /// The dashboard window, set by AppDelegate — tab-driven resizing must not rely on
    /// NSApp.keyWindow, which is not yet updated when the tray menu switches the tab.
    weak var window: NSWindow?

    /// One shared size for every tab so switching tabs never resizes the window.
    /// Falls back to the old per-tab keys once so an existing preferred size survives.
    static func windowSize() -> CGSize {
        for key in ["windowSize", "windowSize.meetings", "windowSize.brain", "windowSize.bridge", "windowSize.settings"] {
            let w = UserDefaults.standard.double(forKey: "\(key).width")
            let h = UserDefaults.standard.double(forKey: "\(key).height")
            if w > 0 && h > 0 { return CGSize(width: w, height: h) }
        }
        return CGSize(width: 1360, height: 860)
    }

    static func saveWindowSize(_ size: CGSize) {
        UserDefaults.standard.set(Double(size.width), forKey: "windowSize.width")
        UserDefaults.standard.set(Double(size.height), forKey: "windowSize.height")
    }
}

struct DashboardView: View {
    @ObservedObject var link: LinkManager
    @ObservedObject var updates: MacUpdateController
    @ObservedObject var presence: TrustedPresenceController
    @State private var dropTargeted = false
    @State private var dialNumber = ""
    @State private var activityExpanded = false
    @State private var selectedMeetings = Set<String>()
    @State private var meetingQuestions = [String: String]()
    @State private var meetingSearch = ""
    @State private var speakerRename = [String: String]()
    @State private var meetingRename = [String: String]()
    @State private var meetingCompany = [String: String]()
    @State private var meetingDateFilter = Date()
    @State private var filterByDate = false
    @State private var selectedMeetingId: String?
    @State private var showRawMarkdown = false
    @ObservedObject private var ui = AppUIState.shared
    private var connected: Bool { link.status == .connected }

    var body: some View {
        TabView(selection: $ui.selectedTab) {
        Form {
            Section {
                LabeledContent("Status") { StatusBadge(status: link.status) }
                LabeledContent("This Mac", value: link.deviceName)
            }

            Section("Nearby Devices") {
                if link.nearby.isEmpty {
                    Label("Searching the local network…", systemImage: "wifi").foregroundStyle(.secondary)
                } else {
                    ForEach(link.nearby) { peer in
                        HStack {
                            Label(peer.name, systemImage: "iphone")
                            Spacer()
                            if link.pairedFingerprints.contains(peer.fingerprint) {
                                Label("Paired", systemImage: "checkmark.seal.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                            } else {
                                Button("Pair") { link.pair(peer) }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }

            Section("Screen") {
                if link.screenImage != nil {
                    Text("Phone screen is streaming in its own window.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Start screen share on the phone to view it in a window.").foregroundStyle(.secondary).font(.callout)
                }
                if link.screenSharing {
                    Button(role: .destructive) { link.stopScreenShare() } label: { Label("Stop sharing my screen", systemImage: "stop.circle") }
                } else {
                    Button { link.startScreenShare() } label: { Label("Share my screen to phone", systemImage: "rectangle.on.rectangle") }.disabled(!connected)
                }
                Button { link.requestScreenRecordingAccess() } label: { Label("Request Screen Recording Access", systemImage: "record.circle") }
                Button { link.openScreenRecordingSettings() } label: { Label("Open Screen Recording Settings", systemImage: "gear") }
            }

            Section("Clipboard & Files") {
                Text(link.clipboardAutoSync ? "Clipboard text syncs automatically while connected." : "Clipboard sharing is manual until Auto Sync is enabled.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Auto Sync clipboard", isOn: Binding(
                    get: { link.clipboardAutoSync },
                    set: { link.setClipboardAutoSync($0) }
                ))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .frame(height: 64)
                    .overlay(Label("Drop files here to send", systemImage: "arrow.down.doc").foregroundStyle(.secondary))
                    .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                        for p in providers {
                            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                                var url: URL?
                                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                                else if let u = item as? URL { url = u }
                                if let url { DispatchQueue.main.async { link.sendFile(url) } }
                            }
                        }
                        return true
                    }
                HStack {
                    Button { link.sendClipboard(NSPasteboard.general.string(forType: .string) ?? "") } label: { Label("Push clipboard", systemImage: "doc.on.clipboard") }
                    Button { pickAndSendFile() } label: { Label("Send file…", systemImage: "doc.badge.plus") }
                }.disabled(!connected)

                if !link.receivedFiles.isEmpty {
                    Divider()
                    Text("Received files are kept here temporarily and auto-cleaned after 24 hours.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(link.receivedFiles) { file in
                        HStack {
                            Label(file.name, systemImage: "doc").lineLimit(1)
                            Spacer()
                            Button { link.copyReceivedFile(file) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            Button(role: .destructive) { link.deleteReceivedFile(file) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }

            Section("Meetings") {
                Text("Use the Meetings tab for live transcription, summaries, recordings, questions, and merge tools.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Phone") {
                Text("Answer, decline, and place calls through your phone. Call audio stays on the phone.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Phone number", text: $dialNumber)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { link.dial(dialNumber) }
                    Button { link.dial(dialNumber) } label: { Label("Call", systemImage: "phone.arrow.up.right") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!connected || dialNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button(role: .destructive) { link.hangupCall() } label: { Label("End current call", systemImage: "phone.down") }
                    .disabled(!connected)
            }

            Section("Test") {
                HStack {
                    Button("Notification") { link.sendTestNotification() }
                    Button("SMS") { link.sendTestSms() }
                    Button("Call") { link.sendTestCall() }
                }.disabled(!connected)
            }

            Section("Activity") {
                DisclosureGroup(isExpanded: $activityExpanded) {
                    if link.events.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(link.events.enumerated()), id: \.offset) { _, e in Text(e).font(.callout) }
                    }
                } label: {
                    Text(activityExpanded ? "Hide activity" : "Show activity")
                }
            }
        }
        .formStyle(.grouped)
        .tabItem { Label("Bridge", systemImage: "arrow.left.arrow.right") }
        .tag(0)

        MeetingCaptureTab(link: link, selectedMeetings: $selectedMeetings, meetingQuestions: $meetingQuestions, meetingSearch: $meetingSearch, speakerRename: $speakerRename, meetingRename: $meetingRename, meetingCompany: $meetingCompany, meetingDateFilter: $meetingDateFilter, filterByDate: $filterByDate, selectedMeetingId: $selectedMeetingId, showRawMarkdown: $showRawMarkdown)
            .tabItem { Label("Meetings", systemImage: "note.text") }
            .tag(1)

        SecondBrainTab(link: link)
            .tabItem { Label("Second Brain", systemImage: "brain.head.profile") }
            .tag(2)

        SettingsTab(link: link, updates: updates)
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(3)

        TrustedPresenceTab(presence: presence)
            .tabItem { Label("Trusted Presence", systemImage: "lock.open.laptopcomputer") }
            .tag(4)
        }
        .sheet(isPresented: $ui.showSetup) {
            SetupWizardView(link: link)
        }
        .alert("Update Available", isPresented: $updates.showConsent, presenting: updates.availableUpdate) { update in
            Button("Not Now", role: .cancel) {}
            Button("Download \(update.version.description)") { updates.approveDownload() }
        } message: { update in
            Text("Android Bridge \(update.version.description) is available. Download it now? The update will be verified before macOS opens it.")
        }
        .alert("Update Error", isPresented: $updates.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(updates.errorMessage)
        }
        .alert("Install Android Bridge", isPresented: $updates.showGuidance) {
            Button("Not Now", role: .cancel) {}
            Button("Reveal in Finder") { updates.revealVerifiedUpdate() }
            Button("Open Again") { updates.openVerifiedUpdate() }
        } message: {
            Text("Open the verified disk image, drag AndroidBridge.app to Applications, then Control-click the app and choose Open the first time. This build is not Apple-notarized.")
        }
    }

    private func toggleMeeting(_ id: String) {
        if selectedMeetings.contains(id) { selectedMeetings.remove(id) } else { selectedMeetings.insert(id) }
    }

    private func pickAndSendFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { link.sendFile(url) }
    }
}

struct MeetingCaptureTab: View {
    @ObservedObject var link: LinkManager
    @Binding var selectedMeetings: Set<String>
    @Binding var meetingQuestions: [String: String]
    @Binding var meetingSearch: String
    @Binding var speakerRename: [String: String]
    @Binding var meetingRename: [String: String]
    @Binding var meetingCompany: [String: String]
    @Binding var meetingDateFilter: Date
    @Binding var filterByDate: Bool
    @Binding var selectedMeetingId: String?
    @Binding var showRawMarkdown: Bool
    @State private var sortByCompany = false
    @State private var showMergeSheet = false
    @State private var mergeTitle = ""
    @State private var mergeDate = Date()

    /// Meetings ticked for merging, oldest first, so the first one supplies the default title and date.
    private var mergeCandidates: [MeetingRecord] {
        link.meetings.filter { selectedMeetings.contains($0.id) }.sorted { $0.date < $1.date }
    }

    private var filteredMeetings: [MeetingRecord] {
        let q = meetingSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let meetings = link.meetings.filter { meeting in
            let matchesText = q.isEmpty || [meeting.title, meeting.company, meeting.summary, meeting.transcript, meeting.questions].joined(separator: "\n").lowercased().contains(q)
            let matchesDate = !filterByDate || Calendar.current.isDate(meeting.date, inSameDayAs: meetingDateFilter)
            return matchesText && matchesDate
        }
        if sortByCompany {
            return meetings.sorted {
                let left = $0.company.isEmpty ? "~" : $0.company.lowercased()
                let right = $1.company.isEmpty ? "~" : $1.company.lowercased()
                return left == right ? $0.date > $1.date : left < right
            }
        }
        return meetings
    }

    private var selectedMeeting: MeetingRecord? {
        let id = selectedMeetingId ?? filteredMeetings.first?.id
        return link.meetings.first { $0.id == id }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.title2)
                        .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("Meetings").font(.title2).bold()
                }
                if let active = link.meetings.first(where: { $0.isActive }) {
                    HStack(spacing: 8) {
                        PulsingDot()
                        Text("Recording: \(active.title)").fontWeight(.semibold)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [Color.red.opacity(0.18), Color.red.opacity(0.06)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.25)))
                }
                Text("Live chunks are transcribed as they arrive. Meetings stay local and searchable.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Search meetings, company, transcript, Q&A", text: $meetingSearch).textFieldStyle(.roundedBorder)
                HStack {
                    Toggle("Filter date", isOn: $filterByDate)
                    DatePicker("", selection: $meetingDateFilter, displayedComponents: .date).labelsHidden()
                    Spacer()
                    Toggle("Sort by customer", isOn: $sortByCompany)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if link.macMeetingActive {
                            Button { link.stopMeetingOnMac() } label: { Label("Stop Mac", systemImage: "stop.circle") }
                        } else {
                            Button { link.startMeetingOnMac() } label: { Label("Record on Mac", systemImage: "mic.circle.fill") }
                                .tint(.red)
                        }
                        Button { link.openMeetingsFolder() } label: { Label("Folder", systemImage: "folder") }
                    }
                    HStack {
                        if link.phoneMeetingActive {
                            Button { link.stopMeetingOnPhone() } label: { Label("Stop phone", systemImage: "stop.circle") }
                        } else {
                            Button { link.startMeetingOnPhone() } label: { Label("Start on phone", systemImage: "iphone") }
                                .tint(.blue)
                        }
                    }
                    .disabled(link.status != .connected)
                }
                Text("Record directly on this Mac, or start recording on the phone. Phone photos can still be added to active phone meetings.")
                    .font(.caption).foregroundStyle(.secondary)
                List(filteredMeetings, selection: $selectedMeetingId) { meeting in
                    MeetingListRow(
                        meeting: meeting,
                        selected: selectedMeetings.contains(meeting.id),
                        name: Binding(get: { meetingRename[meeting.id] ?? meeting.title }, set: { meetingRename[meeting.id] = $0 }),
                        company: Binding(get: { meetingCompany[meeting.id] ?? meeting.company }, set: { meetingCompany[meeting.id] = $0 }),
                        customers: link.customers,
                        onRename: { link.renameMeeting(meeting, to: meetingRename[meeting.id] ?? meeting.title); meetingRename[meeting.id] = nil },
                        onChangeCompany: {
                            let company = meetingCompany[meeting.id] ?? meeting.company
                            if company.trimmingCharacters(in: .whitespacesAndNewlines) != meeting.company { link.changeMeetingCompany(meeting, to: company) }
                            meetingCompany[meeting.id] = nil
                        },
                        onDelete: {
                            selectedMeetings.remove(meeting.id)
                            if selectedMeetingId == meeting.id { selectedMeetingId = nil }
                            link.deleteMeeting(meeting)
                        },
                        onToggle: {
                            if selectedMeetings.contains(meeting.id) { selectedMeetings.remove(meeting.id) } else { selectedMeetings.insert(meeting.id) }
                        }
                    )
                    .tag(meeting.id)
                }
                Button {
                    mergeTitle = mergeCandidates.first?.title ?? ""
                    mergeDate = mergeCandidates.first?.date ?? Date()
                    showMergeSheet = true
                } label: {
                    Label("Merge selected", systemImage: "arrow.triangle.merge")
                }.disabled(selectedMeetings.count < 2 || link.mergeStatus != nil)
                if let status = link.mergeStatus {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
            .sheet(isPresented: $showMergeSheet) {
                MergeMeetingsSheet(
                    meetings: mergeCandidates,
                    title: $mergeTitle,
                    date: $mergeDate,
                    onCancel: { showMergeSheet = false },
                    onMerge: {
                        link.mergeMeetings(mergeCandidates, options: MeetingMergeOptions(title: mergeTitle, date: mergeDate))
                        selectedMeetings.removeAll()
                        showMergeSheet = false
                    }
                )
            }

            if let meeting = selectedMeeting {
                MeetingPreview(
                    link: link,
                    meeting: meeting,
                    question: Binding(get: { meetingQuestions[meeting.id] ?? "" }, set: { meetingQuestions[meeting.id] = $0 }),
                    meetingName: Binding(get: { meetingRename[meeting.id] ?? meeting.title }, set: { meetingRename[meeting.id] = $0 }),
                    companyName: Binding(get: { meetingCompany[meeting.id] ?? meeting.company }, set: { meetingCompany[meeting.id] = $0 }),
                    speakerRename: $speakerRename,
                    showRawMarkdown: $showRawMarkdown,
                    onAsk: { link.askMeetingQuestion(meeting, question: meetingQuestions[meeting.id] ?? ""); meetingQuestions[meeting.id] = "" },
                    onRenameMeeting: { link.renameMeeting(meeting, to: meetingRename[meeting.id] ?? meeting.title); meetingRename[meeting.id] = nil },
                    onChangeCompany: {
                        let company = meetingCompany[meeting.id] ?? meeting.company
                        if company.trimmingCharacters(in: .whitespacesAndNewlines) != meeting.company { link.changeMeetingCompany(meeting, to: company) }
                        meetingCompany[meeting.id] = nil
                    },
                    onRenameSpeaker: { oldName, newName in link.renameSpeaker(meeting, from: oldName, to: newName); speakerRename["\(meeting.id)|\(oldName)"] = nil }
                )
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "note.text")
                        .font(.system(size: 44))
                        .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("No meeting selected").font(.title2).bold()
                    Text("Start a meeting on the phone or choose an existing meeting.").foregroundStyle(.secondary)
                }.frame(minWidth: 520, maxHeight: .infinity)
            }
        }
    }
}

struct MeetingCalendarReviewView: View {
    let review: MeetingCalendarReview
    let customers: [String]
    let onDismiss: () -> Void
    let onSave: (MeetingCalendarEvent?, String) -> Void
    @State private var selectedEventIndex: Int
    @State private var customer: String

    init(review: MeetingCalendarReview, customers: [String], onDismiss: @escaping () -> Void, onSave: @escaping (MeetingCalendarEvent?, String) -> Void) {
        self.review = review
        self.customers = customers
        self.onDismiss = onDismiss
        self.onSave = onSave
        _selectedEventIndex = State(initialValue: review.events.isEmpty ? -1 : 0)
        _customer = State(initialValue: review.meeting.company)
    }

    private var selectedEvent: MeetingCalendarEvent? {
        selectedEventIndex < 0 ? nil : review.events[selectedEventIndex]
    }

    private var hasSelection: Bool {
        selectedEvent != nil || !customer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Recording finished", systemImage: "waveform.badge.checkmark")
                .font(.title2).bold().foregroundStyle(.tint)
            Text(review.meeting.title).font(.headline).lineLimit(2)
            Text(review.meeting.date.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)

            Picker("Calendar meeting", selection: $selectedEventIndex) {
                Text("No calendar meeting").tag(-1)
                ForEach(review.events.indices, id: \.self) { index in
                    let event = review.events[index]
                    Text("\(event.title) · \(event.start.formatted(date: .omitted, time: .shortened))")
                        .tag(index)
                }
            }
            if review.events.isEmpty {
                Text("No unassigned overlapping calendar meeting was found.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text("Client").frame(width: 115, alignment: .trailing)
                CustomerPickerField(value: $customer, customers: customers)
            }

            Spacer()
            HStack {
                Button("Later") { onDismiss() }
                Spacer()
                Button("Save meeting details") { onSave(selectedEvent, customer) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasSelection)
            }
        }
        .padding(24)
        .frame(width: 520, height: 330)
    }
}

struct CustomerPickerField: View {
    @Binding var value: String
    let customers: [String]

    private var filteredCustomers: [String] {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? customers : customers.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var canCreate: Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && !customers.contains { $0.caseInsensitiveCompare(clean) == .orderedSame }
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Search customers", text: $value)
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(filteredCustomers, id: \.self) { customer in
                    Button(customer) { value = customer }
                }
                if canCreate {
                    if !filteredCustomers.isEmpty { Divider() }
                    Button("Create \"\(value.trimmingCharacters(in: .whitespacesAndNewlines))\"") {
                        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if filteredCustomers.isEmpty && !canCreate {
                    Text("No customers")
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Choose an existing customer or create the typed name")
        }
    }
}

struct CustomerChoiceSheet: View {
    let title: String
    let message: String
    let customers: [String]
    let actionTitle: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var value: String

    init(title: String, message: String, initialValue: String, customers: [String], actionTitle: String, onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.customers = customers
        self.actionTitle = actionTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2).bold()
            Text(message).foregroundStyle(.secondary)
            CustomerPickerField(value: $value, customers: customers)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(actionTitle) { onConfirm(value) }
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Asks which title and date the combined meeting should carry before merging.
struct MergeMeetingsSheet: View {
    let meetings: [MeetingRecord]
    @Binding var title: String
    @Binding var date: Date
    let onCancel: () -> Void
    let onMerge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge \(meetings.count) meetings").font(.title3).bold()
            Text("Every recording, photo, and transcript is kept. Choose the title and date the merged note should carry.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.caption).bold()
                TextField("Merged meeting title", text: $title).textFieldStyle(.roundedBorder)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(meetings) { meeting in
                            Button(meeting.title) { title = meeting.title }.buttonStyle(.link)
                        }
                        Button("All titles") { title = meetings.map(\.title).joined(separator: " + ") }.buttonStyle(.link)
                    }.font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Date").font(.caption).bold()
                DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(meetings) { meeting in
                            Button(meeting.date.formatted(date: .abbreviated, time: .shortened)) { date = meeting.date }.buttonStyle(.link)
                        }
                        Button("Now") { date = Date() }.buttonStyle(.link)
                    }.font(.caption)
                }
            }

            Text("After merging, the AI writes one combined summary. On a local model that step can take a few minutes — progress is shown in the meetings list.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Merge") { onMerge() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct MeetingListRow: View {
    let meeting: MeetingRecord
    let selected: Bool
    @Binding var name: String
    @Binding var company: String
    let customers: [String]
    let onRename: () -> Void
    let onChangeCompany: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void
    @State private var editing = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) { Image(systemName: selected ? "checkmark.circle.fill" : "circle") }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    TextField("Meeting name", text: $name).textFieldStyle(.roundedBorder)
                    CustomerPickerField(value: $company, customers: customers)
                } else {
                    Text(meeting.title).font(.headline).lineLimit(1)
                }
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Text(meeting.company.isEmpty ? "No customer" : meeting.company).font(.caption).foregroundStyle(meeting.company.isEmpty ? .tertiary : .secondary)
                ProcessingStateLabel(state: meeting.processingState)
                Text("\(meeting.audioCount) recordings · \(meeting.photoCount) images").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if meeting.isActive { PulsingDot() }
                if editing {
                    Button { onRename(); onChangeCompany(); editing = false } label: { Image(systemName: "checkmark.circle.fill") }.buttonStyle(.plain)
                    Button { name = meeting.title; company = meeting.company; editing = false } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                } else {
                    Button { name = meeting.title; company = meeting.company; editing = true } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct ProcessingStateLabel: View {
    let state: MeetingProcessingState

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }

    private var title: String {
        switch state {
        case .recording: return "Recording"
        case .finalizing: return "Finalizing"
        case .ready: return "Ready"
        case .needsAttention: return "Needs attention"
        }
    }

    private var icon: String {
        switch state {
        case .recording: return "record.circle"
        case .finalizing: return "clock.arrow.circlepath"
        case .ready: return "checkmark.circle"
        case .needsAttention: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch state {
        case .recording: return .red
        case .finalizing: return .orange
        case .ready: return .green
        case .needsAttention: return .orange
        }
    }
}

/// Status dot used for "recording" and "connecting" states.
struct PulsingDot: View {
    var color: Color = .red

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

struct MeetingPreview: View {
    @ObservedObject var link: LinkManager
    let meeting: MeetingRecord
    @Binding var question: String
    @Binding var meetingName: String
    @Binding var companyName: String
    @Binding var speakerRename: [String: String]
    @Binding var showRawMarkdown: Bool
    let onAsk: () -> Void
    let onRenameMeeting: () -> Void
    let onChangeCompany: () -> Void
    let onRenameSpeaker: (String, String) -> Void
    @State private var player: AVPlayer?
    @State private var now = Date()
    @AppStorage("summaryLanguage") private var summaryLanguage = "Original"
    @AppStorage("summaryType") private var summaryType = "Detailed"
    @State private var noteTab = "Summary"
    @State private var showRecordings = false
    @State private var editingTitle = false
    @State private var editingCompany = false
    @State private var showBrainPrompt = false
    @State private var noteMarkdown: String?
    @State private var noteMarkdownIdentity = ""
    @AppStorage("secondBrainClient") private var brainClient = ""

    private var notesURL: URL { meeting.notesURL ?? meeting.url.appendingPathComponent("notes.md") }
    private var noteIdentity: String { notesURL.path + (meeting.notesUpdatedAt?.description ?? "") }

    private var customerSheetPresented: Binding<Bool> {
        Binding(
            get: { showBrainPrompt || link.customerPromptMeetingId == meeting.id },
            set: { presented in
                guard !presented else { return }
                showBrainPrompt = false
                if link.customerPromptMeetingId == meeting.id { link.dismissCustomerPrompt(for: meeting) }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
                meetingToolbar
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                Divider()
                ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        HStack {
                            if editingTitle {
                                TextField("Meeting name", text: $meetingName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.largeTitle.bold())
                                    .onSubmit { onRenameMeeting(); editingTitle = false }
                                Button { onRenameMeeting(); editingTitle = false } label: { Image(systemName: "checkmark.circle.fill") }
                                Button { meetingName = meeting.title; editingTitle = false } label: { Image(systemName: "xmark.circle") }
                            } else {
                                Text(meeting.title).font(.largeTitle).bold()
                                Button { meetingName = meeting.title; editingTitle = true } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.plain)
                            }
                        }
                        Text(meeting.date.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ProcessingStateLabel(state: meeting.processingState)
                            if meeting.processingState == .finalizing { ProgressView().controlSize(.small) }
                            if meeting.processingState == .needsAttention {
                                Button("Retry finalization") { link.retryMeetingFinalization(meeting) }
                            }
                        }
                        HStack {
                            if editingCompany {
                                CustomerPickerField(value: $companyName, customers: link.customers)
                                    .frame(width: 340)
                                Button { onChangeCompany(); editingCompany = false } label: { Image(systemName: "checkmark.circle.fill") }
                                Button { companyName = meeting.company; editingCompany = false } label: { Image(systemName: "xmark.circle") }
                            } else {
                                Text(meeting.company.isEmpty ? "No customer set" : "Customer: \(meeting.company)").foregroundStyle(.secondary)
                                Button { companyName = meeting.company; editingCompany = true } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                            }
                        }
                        if meeting.isActive {
                            Text("Elapsed: \(elapsed(from: meeting.date, to: now))")
                                .font(.title3.monospacedDigit()).foregroundStyle(.red)
                        }

                    }
                    Spacer()
                }
                .sheet(isPresented: customerSheetPresented) {
                    if link.customerPromptMeetingId == meeting.id {
                        CustomerChoiceSheet(
                            title: "Choose customer",
                            message: "This calendar event has no safe customer match. Your choice will be remembered.",
                            initialValue: "",
                            customers: link.customers,
                            actionTitle: "Use Customer",
                            onConfirm: { link.confirmCustomer($0, for: meeting) },
                            onCancel: { link.dismissCustomerPrompt(for: meeting) }
                        )
                    } else {
                        CustomerChoiceSheet(
                            title: "Transfer to Second Brain",
                            message: "Saves this meeting under the selected customer.",
                            initialValue: brainClient,
                            customers: link.customers,
                            actionTitle: "Transfer",
                            onConfirm: { link.transferToSecondBrain(meeting, client: $0); showBrainPrompt = false },
                            onCancel: { showBrainPrompt = false }
                        )
                    }
                }

                SectionBox("Note") {
                    Group {
                    if noteTab == "Summary" {
                        // Cap the line length — full-window paragraphs are unreadable.
                        if meeting.summary.isEmpty {
                            let message = meeting.isActive
                                ? "Live summary will appear after the first recorded chunk is transcribed."
                                : meeting.transcript.isEmpty
                                    ? "No transcript is available yet. Re-transcribe the saved audio chunks."
                                    : "Transcript captured and available in the Transcript tab. Summary generation failed; check the Summarize model or retry."
                            VStack(alignment: .leading, spacing: 10) {
                                Text(message).foregroundStyle(.secondary)
                                if !meeting.transcript.isEmpty, !meeting.isActive {
                                    Button("Generate Missing Summary") { link.regenerateMeetingSummary(meeting) }
                                        .disabled(link.regeneratingSummaryIds.contains(meeting.id))
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Spacer(minLength: 0)
                                    Button { copy(meeting.summary) } label: {
                                        Label("Copy summary", systemImage: "doc.on.doc")
                                    }
                                    .help("Copy the whole summary. You can also click the text and press ⌘A then ⌘C.")
                                }
                                SelectableNoteText(text: meeting.summary)
                                    .frame(maxWidth: 760, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if noteTab == "Transcript" {
                        if meeting.transcript.isEmpty {
                            Text("Transcript is still empty.")
                        } else {
                            TranscriptTextView(text: meeting.transcript)
                        }
                    } else if noteTab == "Chat" {
                        MeetingChatView(
                            archive: link.meetingChats[meeting.id] ?? .empty,
                            draft: $question,
                            isSending: link.meetingChatBusyIds.contains(meeting.id),
                            error: link.meetingChatErrors[meeting.id],
                            onSend: onAsk,
                            onNewSession: { link.startMeetingChatSession(meeting) },
                            onSelectSession: { link.selectMeetingChatSession(meeting, sessionId: $0) }
                        )
                    } else if noteTab == "Events" {
                        EventLogView(events: link.events)
                    } else if let noteMarkdown, noteMarkdownIdentity == noteIdentity {
                        Toggle("Show raw Markdown", isOn: $showRawMarkdown)
                        if showRawMarkdown {
                            Text(markdownPreviewText(noteMarkdown)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        } else {
                            MeetingFullNotePreview(markdown: noteMarkdown, baseURL: meeting.url)
                        }
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading full note…").foregroundStyle(.secondary)
                        }
                    }
                    }
                    .transition(.opacity)
                }

                SectionBox("Calendar") {
                    Text("Uses events already available in Apple Calendar, including configured Google accounts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(link.calendarAccessMessage)
                        .font(.caption)
                        .foregroundStyle(link.calendarAccessMessage == "Calendar access is on." ? .green : .secondary)
                    if let event = meeting.calendarEvent {
                        Label(event.title, systemImage: "calendar.badge.checkmark")
                            .font(.headline)
                        Text("\(event.calendarTitle) · \(event.start.formatted(date: .abbreviated, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let organizer = event.organizer { Text("Organizer: \(organizer)").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let message = link.calendarMessages[meeting.id] {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    let candidates = link.calendarCandidates[meeting.id] ?? []
                    let browsedDay = link.calendarBrowseDay[meeting.id] ?? Calendar.current.startOfDay(for: meeting.date)
                    HStack {
                        if !candidates.isEmpty {
                            Menu("Choose calendar event") {
                                ForEach(candidates) { event in
                                    Button("\(event.title) — \(event.start.formatted(date: .abbreviated, time: .shortened))") {
                                        link.selectCalendarEvent(event, for: meeting)
                                    }
                                }
                                Divider()
                                Button("Enter manually") {
                                    link.beginManualCalendarEntry(for: meeting)
                                    meetingName = meeting.title
                                    companyName = meeting.company
                                    editingTitle = true
                                    editingCompany = true
                                }
                                Button("No calendar event") { link.dismissCalendarCandidates(for: meeting) }
                            }
                        }
                        Button { link.enrichMeetingFromCalendar(meeting) } label: {
                            Label(meeting.calendarEvent == nil ? "Find Calendar Event" : "Refresh Calendar Match", systemImage: "calendar")
                        }
                        Button("Request Calendar Access") { link.requestCalendarAccess() }
                        Button("Calendar Settings") { link.openCalendarSettings() }
                    }
                    HStack(spacing: 8) {
                        Button { link.stepCalendarBrowse(for: meeting, days: -1) } label: {
                            Image(systemName: "chevron.left")
                        }
                        .help("Browse the previous day")
                        Text(browsedDay.formatted(date: .abbreviated, time: .omitted))
                            .font(.callout).monospacedDigit()
                        Button { link.stepCalendarBrowse(for: meeting, days: 1) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .help("Browse the next day")
                        Button("Show this day's events") { link.browseCalendarEvents(for: meeting, day: browsedDay) }
                        Button("Recording day") { link.browseCalendarEvents(for: meeting, day: meeting.date) }
                    }
                    Text("Browsing lists past and already finished events too, not only the ones overlapping the recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !meeting.audioFiles.isEmpty {
                    SectionBox("Recordings") {
                        let sourceRecordingCount = meeting.audioFiles.count { $0.lastPathComponent != "merged-recording.m4a" }
                        HStack {
                            Button { link.mergeMeetingRecordings(meeting) } label: {
                                Label("Merge into one recording", systemImage: "waveform.path")
                            }
                            .disabled(meeting.isActive || sourceRecordingCount < 2)
                            Text("Source chunks are preserved.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Audio files (\(meeting.audioFiles.count))", isExpanded: $showRecordings) {
                            ForEach(meeting.audioFiles, id: \.path) { file in
                                HStack {
                                    Text(file.lastPathComponent).lineLimit(1)
                                    Spacer()
                                    Button("Play") { player = AVPlayer(url: file); player?.play() }
                                    Button("Stop") { player?.pause(); player = nil }
                                }
                            }
                        }
                    }
                }

                SectionBox("Speaker Names") {
                    ForEach(speakers, id: \.self) { speaker in
                        HStack {
                            Text(speaker).frame(width: 100, alignment: .leading)
                            TextField("New name", text: Binding(get: { speakerRename[renameKey(speaker)] ?? "" }, set: { speakerRename[renameKey(speaker)] = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Button("Apply") { onRenameSpeaker(speaker, speakerRename[renameKey(speaker)] ?? "") }
                                .disabled((speakerRename[renameKey(speaker)] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Text("Voice profiles are not stored yet; this version renames transcript labels in the note.")
                        .font(.caption).foregroundStyle(.secondary)
                }


                if !meeting.imageFiles.isEmpty {
                    SectionBox("Images") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                            ForEach(meeting.imageFiles, id: \.path) { image in
                                if let ns = NSImage(contentsOf: image) {
                                    Image(nsImage: ns).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }

            }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
        .task(id: noteIdentity + noteTab) {
            if noteTab == "Full note" { await loadMarkdown() }
        }
        .task(id: meeting.id) { link.loadMeetingChat(meeting) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { if meeting.isActive { now = $0 } }
    }

    private func readMarkdown() async -> String {
        let url = notesURL
        return await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
    }

    private func loadMarkdown() async {
        let identity = noteIdentity
        noteMarkdown = nil
        noteMarkdownIdentity = ""
        let markdown = await readMarkdown()
        guard !Task.isCancelled, identity == noteIdentity else { return }
        noteMarkdown = markdown
        noteMarkdownIdentity = identity
    }

    private func copyFullNote() {
        Task {
            let markdown: String
            if noteMarkdownIdentity == noteIdentity, let noteMarkdown {
                markdown = noteMarkdown
            } else {
                markdown = await readMarkdown()
            }
            guard !Task.isCancelled else { return }
            copy(markdown)
        }
    }

    /// Single pinned toolbar with note navigation and all meeting actions.
    private var meetingToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Note section", selection: Binding(
                    get: { noteTab },
                    set: { value in withAnimation(.easeInOut(duration: 0.2)) { noteTab = value } }
                )) {
                    Text("Summary").tag("Summary")
                    Text("Transcript").tag("Transcript")
                    Text("Full note").tag("Full note")
                    Text("Chat").tag("Chat")
                    Text("Events").tag("Events")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Button { withAnimation(.easeInOut(duration: 0.2)) { noteTab = "Chat" } } label: {
                    Label("Ask", systemImage: "bubble.left.and.bubble.right")
                }

                Menu("Copy") {
                    Button("Entire summary") { copy(meeting.summary) }.disabled(meeting.summary.isEmpty)
                    Button("Transcript") { copy(meeting.transcript) }.disabled(meeting.transcript.isEmpty)
                    Button("Chat") { copy(meeting.questions) }.disabled(meeting.questions.isEmpty)
                    Button("Full note") { copyFullNote() }
                }

                Button {
                    if !meeting.company.isEmpty { brainClient = meeting.company }
                    showBrainPrompt = true
                } label: {
                    Label("Second Brain", systemImage: "brain.head.profile")
                }
                .disabled(link.brainTransferIds.contains(meeting.id))

                Menu {
                    Button { link.retranscribeMeeting(meeting) } label: {
                        Label("Re-transcribe", systemImage: "waveform")
                    }
                    .disabled(link.regeneratingSummaryIds.contains(meeting.id))
                    Button { link.shareMeeting(meeting) } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) { link.deleteMeeting(meeting) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("Tools", systemImage: "ellipsis.circle")
                }
            }

            if noteTab == "Summary" || link.brainTransferIds.contains(meeting.id) || link.regeneratingSummaryIds.contains(meeting.id) {
                HStack(spacing: 12) {
                    if noteTab == "Summary" {
                        Picker("Summary language", selection: Binding(get: { summaryLanguage }, set: { summaryLanguage = $0; link.regenerateMeetingSummary(meeting) })) {
                            Text("Original").tag("Original")
                            Text("Hebrew").tag("Hebrew")
                            Text("English").tag("English")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                        Picker("Summary type", selection: Binding(get: { summaryType }, set: { summaryType = $0; link.regenerateMeetingSummary(meeting) })) {
                            Text("Detailed").tag("Detailed")
                            Text("Short").tag("Short")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                    if link.brainTransferIds.contains(meeting.id) {
                        ProgressView().controlSize(.small)
                        Text("Sending to Second Brain…").font(.caption).foregroundStyle(.secondary)
                    } else if link.regeneratingSummaryIds.contains(meeting.id) {
                        ProgressView().controlSize(.small)
                        Text("Working on meeting…").font(.caption).foregroundStyle(.secondary)
                    } else if noteTab == "Summary", let updated = meeting.notesUpdatedAt {
                        Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func markdownPreviewText(_ text: String) -> String {
        let limit = 80_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n… Full note is large; showing first \(limit) characters to keep the app responsive. Use Transcript/Summary tabs for focused reading, or open the meeting folder for the full Markdown file."
    }

    private var speakers: [String] {
        let names = meeting.transcript.split(separator: "\n").compactMap { line -> String? in
            guard let bracket = line.firstIndex(of: "[") else { return nil }
            return String(line[..<bracket]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Array(Set(names)).sorted()
    }

    private func renameKey(_ speaker: String) -> String { "\(meeting.id)|\(speaker)" }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct EventLogView: View {
    let events: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if events.isEmpty { Text("No events yet.").foregroundStyle(.secondary) }
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                Text(event).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TranscriptTextView: View {
    private let chunks: [String]

    init(text: String) {
        var chunks: [String] = []
        var lines: [String] = []
        var characterCount = 0

        for line in text.components(separatedBy: .newlines) {
            let lineCharacterCount = line.count + (lines.isEmpty ? 0 : 1)
            if !lines.isEmpty && (lines.count == 80 || characterCount + lineCharacterCount > 12_000) {
                chunks.append(lines.joined(separator: "\n"))
                lines = []
                characterCount = 0
            }
            lines.append(line)
            characterCount += line.count + (lines.count == 1 ? 0 : 1)
        }
        if !lines.isEmpty { chunks.append(lines.joined(separator: "\n")) }
        self.chunks = chunks
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                Text(chunk)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MeetingChatView: View {
    let archive: MeetingChatArchive
    @Binding var draft: String
    let isSending: Bool
    let error: String?
    let onSend: () -> Void
    let onNewSession: () -> Void
    let onSelectSession: (String) -> Void

    private var messages: [MeetingChatMessage] { archive.activeSession?.messages ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !archive.sessions.isEmpty {
                    Menu(activeSessionLabel) {
                        ForEach(Array(archive.sessions.enumerated()), id: \.element.id) { index, session in
                            Button(sessionLabel(session, index: index)) { onSelectSession(session.id) }
                        }
                    }
                    .disabled(isSending)
                }
                Spacer()
                Button(action: onNewSession) {
                    Label("New Session", systemImage: "plus.bubble")
                }
                .disabled(isSending)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            Text("Ask about this meeting. Answers use only this meeting note.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .padding()
                        } else {
                            ForEach(messages) { message in
                                MeetingChatBubble(message: message)
                            }
                        }
                        Color.clear.frame(height: 1).id("meeting-chat-bottom")
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 380)
                .onAppear { scrollToBottom(proxy) }
                .onChange(of: messages.count) { _ in scrollToBottom(proxy) }
            }

            if isSending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking about this note…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask a question about this meeting", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                Button("Send", action: onSend)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var activeSessionLabel: String {
        guard let session = archive.activeSession,
              let index = archive.sessions.firstIndex(where: { $0.id == session.id }) else { return "Chat" }
        return sessionLabel(session, index: index)
    }

    private func sessionLabel(_ session: MeetingChatSession, index: Int) -> String {
        "Chat \(index + 1) · \(session.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { withAnimation { proxy.scrollTo("meeting-chat-bottom", anchor: .bottom) } }
    }
}

struct MeetingChatBubble: View {
    let message: MeetingChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            Group {
                if message.role == .assistant {
                    FormattedNoteText(text: message.content)
                } else {
                    Text(message.content).textSelection(.enabled)
                }
            }
            .padding(10)
            .foregroundStyle(message.role == .user ? .white : .primary)
            .background(message.role == .user ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 560, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

struct FormattedNoteText: View {
    let text: String

    private enum Block {
        case paragraph([String])   // raw lines; markdown is parsed lazily at render time
        case table([[String]])
    }

    // Parsed once at init (cheap string work only). The expensive
    // AttributedString(markdown:) parsing is deferred to each visible paragraph
    // by the LazyVStack, so a long note no longer builds one giant Text and
    // freezes the main thread.
    private let rtl: Bool
    private let blocks: [Block]

    init(text: String) {
        self.text = text
        self.rtl = text.isMostlyHebrew
        self.blocks = FormattedNoteText.parse(text)
    }

    var body: some View {
        LazyVStack(alignment: rtl ? .trailing : .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let lines):
                    Text(attributedParagraph(lines))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .multilineTextAlignment(rtl ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                case .table(let rows):
                    tableView(rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
    }

    /// Summaries sometimes come back with bare or numbered section titles
    /// ("Decisions", "2) Action Items") — promote them to headings so the
    /// rendered note gets real structure.
    private static func sectionHeading(_ line: String) -> String? {
        let sections = ["Summary", "Decisions", "Action Items", "Open Questions/Risks"]
        for section in sections {
            if line == section { return "## \(section)" }
            for n in 1...4 where line == "\(n)) \(section)" || line == "\(n). \(section)" { return "## \(section)" }
        }
        return nil
    }

    /// Groups the note into paragraphs (split on blank lines) and tables. Only
    /// string work happens here so it stays cheap for very long notes; the
    /// per-paragraph markdown parsing runs lazily in `attributedParagraph`.
    private static func parse(_ text: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var tableRows: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph)); paragraph = [] }
        }
        func flushTable() {
            if !tableRows.isEmpty { result.append(.table(tableRows)); tableRows = [] }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()
            if lowered == "```" || lowered == "```markdown" { continue }
            if isTableSeparator(trimmed) { continue }
            if let cells = parseTableRow(trimmed) {
                flushParagraph()
                tableRows.append(cells)
                continue
            }
            flushTable()
            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = sectionHeading(trimmed) {
                flushParagraph()
                paragraph.append(heading)
                flushParagraph()
            } else {
                paragraph.append(trimmed)
            }
        }
        flushParagraph()
        flushTable()
        return result
    }

    /// Builds one paragraph's AttributedString by parsing each of its lines.
    private func attributedParagraph(_ lines: [String]) -> AttributedString {
        var joined = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { joined += AttributedString("\n") }
            joined += attributedLine(line)
        }
        return joined
    }

    private func attributedLine(_ line: String) -> AttributedString {
        if let heading = parseHeading(line) {
            var content = inlineMarkdown(heading.text)
            content.font = heading.level == 1 ? .title2.bold() : (heading.level == 2 ? .title3.bold() : .headline.bold())
            return content
        }
        if let bullet = parseBullet(line) {
            return AttributedString("•  ") + inlineMarkdown(bullet)
        }
        return inlineMarkdown(line)
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func tableView(_ rows: [[String]]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                GridRow {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        FormattedCell(text: cell)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0 else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, String(text))
    }

    private static func parseTableRow(_ line: String) -> [String]? {
        guard line.hasPrefix("|") && line.hasSuffix("|") else { return nil }
        let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return cells.isEmpty ? nil : cells
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") && line.hasSuffix("|") else { return false }
        let body = line.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
        return !body.isEmpty && body.allSatisfy { $0 == "-" || $0.isWhitespace }
    }

    private func parseBullet(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") else { return nil }
        return String(line.dropFirst(2))
    }
}

struct FormattedCell: View {
    let text: String
    var body: some View {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        Text(attributed)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: text.isMostlyHebrew ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension String {
    var isMostlyHebrew: Bool {
        let letters = unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let hebrew = letters.filter { CharacterSet(charactersIn: "\u{0590}"..."\u{05FF}").contains($0) }
        return hebrew.count > letters.count / 2
    }
}

struct MeetingFullNotePreview: View {
    let markdown: String
    let baseURL: URL

    var body: some View {
        let limit = 80_000
        if markdown.count > limit {
            VStack(alignment: .leading, spacing: 10) {
                Label("Large note preview", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("This note is very large, so Android Bridge shows a truncated preview to avoid freezing the app.")
                    .foregroundStyle(.secondary)
                MarkdownPreview(markdown: String(markdown.prefix(limit)), baseURL: baseURL)
                Text("… Truncated. Use Summary/Transcript tabs or open the meeting folder for the complete Markdown file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            MarkdownPreview(markdown: markdown, baseURL: baseURL)
        }
    }
}

struct MarkdownPreview: View {
    let markdown: String
    let baseURL: URL

    private enum Chunk {
        case text(String)
        case image(URL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                switch chunk {
                case .text(let block):
                    FormattedNoteText(text: block)
                case .image(let url):
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var chunks: [Chunk] {
        var result: [Chunk] = []
        var textLines: [String] = []
        func flushText() {
            let block = textLines.joined(separator: "\n")
            if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(block)) }
            textLines = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("!["), let path = imagePath(line) {
                flushText()
                result.append(.image(baseURL.appendingPathComponent(path)))
            } else {
                textLines.append(line)
            }
        }
        flushText()
        return result
    }

    private func imagePath(_ line: String) -> String? {
        guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return nil }
        return String(line[line.index(after: open)..<close])
    }
}

struct ChatQAView: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            if entries.isEmpty {
                Text("No questions yet. Ask something about this note to build a chat history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.0) { entry in
                VStack(spacing: 6) {
                    HStack {
                        Spacer(minLength: 60)
                        Text(entry.1)
                            .padding(10)
                            .background(
                                LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.75)], startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .foregroundStyle(.white)
                    }
                    HStack {
                        Text(entry.2.isEmpty ? "Thinking…" : entry.2)
                            .padding(10)
                            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                            .textSelection(.enabled)
                        Spacer(minLength: 60)
                    }
                }
            }
        }
    }
    private var entries: [(Int, String, String)] {
        text.components(separatedBy: "## Q: ").enumerated().compactMap { i, part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let pieces = trimmed.components(separatedBy: "\n\n")
            return (i, pieces.first ?? "Question", pieces.dropFirst().joined(separator: "\n\n"))
        }
    }
}

struct LLMSettingsView: View {
    @ObservedObject var link: LinkManager
    let feature: LLMFeature
    @AppStorage private var usePi: Bool
    @AppStorage private var model: String
    @State private var modelSearch = ""
    @State private var ollamaModels = [String]()
    @State private var piModels = [String]()
    @State private var piModelError: String?
    @State private var loadingPiModels = false

    init(_ feature: LLMFeature, link: LinkManager) {
        self.feature = feature
        self.link = link
        _usePi = AppStorage(wrappedValue: false, "llm.\(feature.key).usePi")
        _model = AppStorage(wrappedValue: "gemma4:e4b", "llm.\(feature.key).model")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(feature.rawValue).frame(width: 160, alignment: .leading)
                Picker("Provider", selection: $usePi) {
                    Text("Local Ollama").tag(false)
                    Text("pi").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                if usePi {
                    Picker("pi model", selection: $model) {
                        ForEach(filteredPiModels, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 280)
                } else {
                    Picker("Ollama model", selection: $model) {
                        ForEach(filteredOllamaModels, id: \.self) { Text($0).tag($0) }
                        if filteredOllamaModels.isEmpty { Text(model.isEmpty ? "gemma4:e4b" : model).tag(model.isEmpty ? "gemma4:e4b" : model) }
                    }
                    .frame(width: 280)
                    Button { loadOllamaModels() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            if usePi {
                TextField("Search pi models", text: $modelSearch)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(width: 640)
                HStack {
                    Button("Refresh pi models") { loadPiModels() }.disabled(loadingPiModels)
                    if loadingPiModels { ProgressView().controlSize(.small) }
                    if let piModelError { Text(piModelError).font(.caption).foregroundStyle(.red) }
                }
            } else {
                TextField("Search Ollama models", text: $modelSearch)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(width: 640)
            }
            if feature == .summarize {
                HStack {
                    Button("Backfill Missing Summaries") { link.backfillMissingSummaries() }
                        .disabled(link.summaryBackfillRunning)
                    Button("Regenerate All Summaries") { link.backfillMissingSummaries(force: true) }
                        .disabled(link.summaryBackfillRunning)
                        .help("Re-summarizes every meeting with the current language, type, and prompt — use after changing summary settings or to clean up old wall-of-text summaries.")
                    if link.summaryBackfillRunning { ProgressView().controlSize(.small) }
                    if let status = link.summaryBackfillStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear { loadOllamaModels(); loadPiModels() }
    }

    private var filteredPiModels: [String] {
        let q = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.isEmpty ? piModels : piModels.filter { $0.lowercased().contains(q) }
    }

    private var filteredOllamaModels: [String] {
        let q = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let models = ollamaModels.isEmpty ? ["gemma4:e4b"] : ollamaModels
        return q.isEmpty ? models : models.filter { $0.lowercased().contains(q) }
    }

    private func loadPiModels() {
        loadingPiModels = true
        piModelError = nil
        let executable = UserDefaults.standard.string(forKey: "pi.executable")?.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .utility).async {
            do {
                let models = try PiModelCatalog.load(executable: executable?.isEmpty == false ? executable! : "pi")
                DispatchQueue.main.async {
                    piModels = models
                    loadingPiModels = false
                }
            } catch {
                DispatchQueue.main.async {
                    piModels = []
                    piModelError = error.localizedDescription
                    loadingPiModels = false
                }
            }
        }
    }

    private func loadOllamaModels() {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ollama", "list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let names = output.components(separatedBy: .newlines).dropFirst().compactMap { line in
                line.split(separator: " ").first.map(String.init)
            }.filter { !$0.isEmpty }
            DispatchQueue.main.async { if !names.isEmpty { ollamaModels = names } }
        }
    }
}

struct SecondBrainSkillEditor: View {
    let skillRoot: String
    @State private var text = ""
    @State private var savedText = ""
    @State private var status = ""

    var body: some View {
        DisclosureGroup("Edit embedded Second Brain skill") {
            VStack(alignment: .leading, spacing: 8) {
                Text(skillURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 260)
                    .border(Color.secondary.opacity(0.3))
                HStack {
                    Button("Save") { save() }.disabled(text == savedText)
                    Button("Restore bundled version") { restore() }
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(.top, 8)
        }
        .onAppear { load() }
        .onChange(of: skillRoot) { _ in load() }
    }

    private var skillURL: URL {
        URL(fileURLWithPath: skillRoot).appendingPathComponent("SKILL.md")
    }

    private func load() {
        do {
            text = try String(contentsOf: skillURL, encoding: .utf8)
            savedText = text
            status = ""
        } catch {
            text = ""
            savedText = ""
            status = error.localizedDescription
        }
    }

    private func save() {
        do {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "SecondBrainSkill", code: 2, userInfo: [NSLocalizedDescriptionKey: "SKILL.md cannot be empty."])
            }
            try text.write(to: skillURL, atomically: true, encoding: .utf8)
            savedText = text
            status = "Saved"
        } catch { status = error.localizedDescription }
    }

    private func restore() {
        do {
            text = try SecondBrainSkillManager.bundledSkillText()
            try text.write(to: skillURL, atomically: true, encoding: .utf8)
            savedText = text
            status = "Restored"
        } catch { status = error.localizedDescription }
    }
}

struct SettingsTab: View {
    @ObservedObject var link: LinkManager
    @ObservedObject var updates: MacUpdateController
    @AppStorage("pi.executable") private var piExecutable = "pi"
    @AppStorage("pi.secondBrainSkill") private var piSecondBrainSkill = SecondBrainSkillManager.installedURL().path
    @AppStorage("secondBrain.root") private var secondBrainRoot = NSHomeDirectory() + "/second_brain"
    @AppStorage("meetings.root") private var meetingsRoot = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent("AndroidBridgeMeetings").path
    @State private var relayEndpoint = ""
    @State private var relayWorkspaceId = ""
    @State private var relaySetupCode = ""

    var body: some View {
        Form {
            Section("Software Update") {
                LabeledContent("Installed version", value: updates.installedVersionText)
                Text(updates.status).font(.caption).foregroundStyle(.secondary)
                if updates.isChecking || updates.isDownloading {
                    ProgressView(updates.isDownloading ? "Downloading and verifying…" : "Checking…")
                }
                HStack {
                    Button("Check for Updates") { updates.checkManually() }
                        .disabled(updates.isChecking || updates.isDownloading)
                    if let update = updates.availableUpdate {
                        Button(updates.verifiedUpdate == nil ? "Download \(update.version.description)" : "Open Verified DMG") {
                            if updates.verifiedUpdate == nil { updates.showConsent = true }
                            else { updates.openVerifiedUpdate() }
                        }
                        .disabled(updates.isDownloading)
                        Link("View Release Page", destination: update.pageURL)
                    }
                }
                if updates.verifiedUpdate != nil {
                    Button("Reveal Verified DMG in Finder") { updates.revealVerifiedUpdate() }
                }
            }
            Section("Setup") {
                Button { AppUIState.shared.showSetup = true } label: {
                    Label("Open Setup Wizard…", systemImage: "wand.and.stars")
                }
                Text("Detect installed tools, repair dependencies, review permissions, and connect your Android phone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Remote relay") {
                Toggle("Enable relay fallback", isOn: Binding(
                    get: { link.relayEnabled },
                    set: { link.setRelayEnabled($0) }
                ))
                LabeledContent("Status", value: link.relayStatus)
                TextField("HTTPS endpoint", text: $relayEndpoint)
                    .textFieldStyle(.roundedBorder)
                TextField("Workspace", text: $relayWorkspaceId)
                    .textFieldStyle(.roundedBorder)
                SecureField("One-time setup code", text: $relaySetupCode)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save endpoint") {
                        link.saveRelayEndpoint(relayEndpoint, workspaceId: relayWorkspaceId)
                    }
                    Button(link.relayEnrolled ? "Re-enroll Mac" : "Enroll Mac") {
                        let code = relaySetupCode
                        relaySetupCode = ""
                        link.enrollRelay(endpoint: relayEndpoint, workspaceId: relayWorkspaceId, setupCode: code)
                    }
                    .disabled(relayEndpoint.isEmpty || relayWorkspaceId.isEmpty || relaySetupCode.isEmpty)
                    Button("Create phone invitation") { link.createRelayPhoneInvitation() }
                        .disabled(!link.relayEnrolled)
                }
                if let invitation = link.relayInvitation {
                    LabeledContent("Phone invitation") {
                        Text(invitation).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    if let expiry = link.relayInvitationExpiresAt {
                        Text("Expires \(expiry)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Direct connection stays preferred. Relay starts after a bounded direct attempt. Credentials and settings are stored in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Durable protocol-message replay and Second Brain Markdown/meeting-photo delta sync are active over relay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("LLM routing") {
                ForEach(LLMFeature.allCases) { feature in LLMSettingsView(feature, link: link) }
            }
            Section("Customers and Calendar") {
                Picker("Main calendar", selection: Binding(
                    get: { link.mainCalendarIdentifier },
                    set: { link.setMainCalendarIdentifier($0) }
                )) {
                    Text("No preferred calendar").tag("")
                    if !link.mainCalendarIdentifier.isEmpty && !link.availableCalendars.contains(where: { $0.id == link.mainCalendarIdentifier }) {
                        Text("Saved calendar unavailable — using fallback").tag(link.mainCalendarIdentifier)
                    }
                    ForEach(link.availableCalendars) { calendar in
                        Text("\(calendar.title) — \(calendar.source)").tag(calendar.id)
                    }
                }
                HStack {
                    Button("Refresh calendars") { link.refreshCalendars() }
                    Text(link.customerStatus).font(.caption).foregroundStyle(.secondary)
                }
                if link.customerAssociations.isEmpty {
                    Text("Customer matches learned from Calendar will appear here.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(link.customerAssociations) { association in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(association.eventTitle).lineLimit(1)
                                Text(association.externalDomains.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Menu(association.customer) {
                                ForEach(link.customers, id: \.self) { customer in
                                    Button(customer) { link.changeCustomerAssociation(association, to: customer) }
                                }
                            }
                            Button("Forget", role: .destructive) { link.forgetCustomerAssociation(association) }
                        }
                    }
                }
            }
            Section("Paths") {
                pathRow("pi executable", text: $piExecutable, chooseFolder: false)
                pathRow("Second Brain skill", text: $piSecondBrainSkill, chooseFolder: true)
                pathRow("Second Brain root", text: $secondBrainRoot, chooseFolder: true)
                pathRow("Meetings folder", text: $meetingsRoot, chooseFolder: true)
                Text("Path changes are used by the next pi, Second Brain, or meeting operation. Second Brain refresh no longer requires a relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
                SecondBrainSkillEditor(skillRoot: piSecondBrainSkill)
            }
            Section("How pi integration works") {
                Text("Each task can use Local Ollama or pi. Local Ollama is the default and uses the model name in the row, usually gemma4:e4b.")
                Text("Meeting tasks run without tools or skills. Second Brain tasks load only the configured Second Brain skill and allow its required bash tool:")
                Text("<pi executable> --print --no-session --no-extensions --no-skills --tools bash --skill <Second Brain skill> --model <model> <prompt>")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text("The editable skill can run shell commands when a Second Brain task uses pi. Review skill changes before saving them. CRUD writes through brain.py so indexes stay consistent.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            relayEndpoint = link.relayEndpoint
            relayWorkspaceId = link.relayWorkspaceId
        }
    }

    private func pathRow(_ label: String, text: Binding<String>, chooseFolder: Bool) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .environment(\.layoutDirection, .leftToRight)
            Button("Choose…") { choosePath(text, folder: chooseFolder) }
        }
    }

    private func choosePath(_ text: Binding<String>, folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path }
    }
}

struct SecondBrainTab: View {
    @ObservedObject var link: LinkManager
    @State private var search = ""
    @State private var draft = ""
    @State private var question = ""
    @State private var newTitle = ""
    @State private var newBody = ""
    @State private var addTargetCluster = ""
    @State private var showAddNote = false
    @State private var rawMode = false
    @State private var draftDirty = false
    @State private var brainView = "Files"

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "brain.head.profile").font(.title2).foregroundStyle(.purple)
                    Text("Second Brain").font(.title2).bold()
                    Spacer()
                    Button { link.refreshBrain(loadMap: brainView == "Map") } label: { Image(systemName: "arrow.clockwise") }
                    Button { link.openSecondBrainFolder() } label: { Image(systemName: "folder") }
                }
                Text("\(link.brainStorePath) • \(link.brainStatus)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    TextField("Search second brain", text: $search).textFieldStyle(.roundedBorder).onSubmit { link.searchBrain(search) }
                    Button("Search") { link.searchBrain(search) }
                }
                Picker("View", selection: $brainView) {
                    Text("Files").tag("Files")
                    Text("Map").tag("Map")
                }
                .pickerStyle(.segmented)
                if !link.brainSearchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Search results").font(.headline)
                            Spacer()
                            Button { link.clearBrainSearch() } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .keyboardShortcut(.escape, modifiers: [])
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(link.brainSearchResults) { result in
                                    Button { link.selectBrainNode(result.path) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Image(systemName: "doc.text.magnifyingglass")
                                                Text(result.title).font(.headline).lineLimit(1)
                                            }
                                            Text(result.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            Text(result.snippet)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.primary)
                                                .lineLimit(6)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                    }.buttonStyle(.plain)
                                }
                            }.padding(8)
                        }
                    }
                    .padding(8)
                    .frame(minHeight: 260, maxHeight: 360)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if brainView == "Files" {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(link.brainNodes) { node in
                                Button { link.selectBrainNode(node.path) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: node.isDirectory ? "folder" : "doc.text")
                                        Text(node.label).lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.leading, CGFloat(node.depth * 16))
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 8)
                                    .background(link.selectedBrainPath == node.path ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                } else {
                    BrainMapView(nodes: link.brainNodes, edges: link.brainEdges, open: link.selectBrainNode)
                }
            }
            .padding()
            .frame(minWidth: 340, idealWidth: 430)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(link.selectedBrainPath).font(.headline).lineLimit(1)
                    Spacer()
                    Picker("View", selection: $rawMode) {
                        Text("Parsed").tag(false)
                        Text("Raw/Edit").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    Button("Save") { link.saveBrainNode(draft) { if $0 { draftDirty = false } } }.disabled(!rawMode)
                    Button("Add Note") { showAddNote = true }
                    Button("Delete Note", role: .destructive) { link.deleteSelectedBrainNote() }
                        .disabled(link.selectedBrainPath.hasSuffix("index.md"))
                }
                Group {
                    if rawMode {
                        TextEditor(text: Binding(
                            get: { draft },
                            set: { draft = $0; draftDirty = true }
                        ))
                            .font(.system(.body, design: .monospaced))
                            .border(Color.secondary.opacity(0.25))
                    } else {
                        ScrollView { BrainMarkdownView(markdown: draft, currentPath: link.selectedBrainPath, open: link.selectBrainNode).padding().frame(maxWidth: .infinity, alignment: .leading) }
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .onChange(of: link.selectedBrainContent) { if !draftDirty { draft = $0 } }
                .onChange(of: link.selectedBrainPath) { _ in draftDirty = false }
                .onAppear { if !draftDirty { draft = link.selectedBrainContent } }
                .sheet(isPresented: $showAddNote) { addNoteSheet.frame(width: 560, height: 420) }

                SectionBox("Chat with selected node") {
                    HStack(alignment: .bottom) {
                        TextField("Ask about this node", text: $question, axis: .vertical).textFieldStyle(.roundedBorder)
                        Button("Send") { link.askBrain(question); question = "" }
                            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ChatQAView(text: link.brainChat)
                }
            }
            .padding()
            .frame(minWidth: 620)
        }
        .onAppear { link.refreshBrain(loadMap: brainView == "Map", refreshSelectedContent: !draftDirty) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled {
                    link.refreshBrainIfChanged(loadMap: brainView == "Map", refreshSelectedContent: !draftDirty)
                }
            }
        }
        .onChange(of: brainView) { view in
            if view == "Map" { link.loadBrainMap() }
        }
    }

    private var addNoteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add note").font(.title2).bold()
            TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder)
            TextField("Cluster path (blank = selected folder/index parent)", text: $addTargetCluster).textFieldStyle(.roundedBorder)
            TextEditor(text: $newBody).border(Color.secondary.opacity(0.25))
            HStack {
                Spacer()
                Button("Cancel") { showAddNote = false }
                Button("Add Note") {
                    link.addBrainNote(cluster: targetCluster, title: newTitle, body: newBody)
                    newTitle = ""; newBody = ""; showAddNote = false
                }.disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private var targetCluster: String {
        let clean = addTargetCluster.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        let path = link.selectedBrainPath
        if path.hasSuffix("/index.md") { return String(path.dropLast("/index.md".count)) }
        return (path as NSString).deletingLastPathComponent
    }
}

struct BrainMapView: View {
    let nodes: [BrainNode]
    let edges: [BrainEdge]
    let open: (String) -> Void

    private struct ClusterLayout {
        let name: String
        let center: CGPoint
        let radius: CGFloat
    }

    private struct MapLayout {
        var clusters: [ClusterLayout] = []
        var points: [String: CGPoint] = [:]
        var size: CGSize = .zero
    }

    private static let nodeSpacing: CGFloat = 84
    private static let clusterGap: CGFloat = 44
    private static let margin: CGFloat = 50
    private static let maxRowWidth: CGFloat = 1500

    private var notePaths: [String] {
        nodes.filter { !$0.isDirectory && !$0.path.hasSuffix("index.md") }.map(\.path).sorted()
    }

    private var graphEdges: [BrainEdge] {
        edges.filter { notePaths.contains($0.from) && notePaths.contains($0.to) }
    }

    var body: some View {
        let layout = layout()
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for cluster in layout.clusters {
                        let rect = CGRect(x: cluster.center.x - cluster.radius, y: cluster.center.y - cluster.radius, width: cluster.radius * 2, height: cluster.radius * 2)
                        let tint = color(for: cluster.name)
                        context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.07)))
                        context.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(0.3)), lineWidth: 1)
                    }
                    for edge in graphEdges {
                        guard let a = layout.points[edge.from], let b = layout.points[edge.to] else { continue }
                        var path = Path()
                        path.move(to: a)
                        path.addLine(to: b)
                        context.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 1)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)

                ForEach(layout.clusters, id: \.name) { cluster in
                    Text(cluster.name)
                        .font(.caption.bold())
                        .foregroundStyle(color(for: cluster.name))
                        .position(x: cluster.center.x, y: cluster.center.y - cluster.radius - 12)
                }

                ForEach(notePaths, id: \.self) { node in
                    let tint = color(for: clusterName(of: node))
                    let connected = graphEdges.contains { $0.from == node || $0.to == node }
                    Button { open(node) } label: {
                        VStack(spacing: 5) {
                            Circle()
                                .fill(tint)
                                .frame(width: connected ? 15 : 11, height: connected ? 15 : 11)
                                .shadow(color: tint.opacity(0.9), radius: 6)
                            Text(short(node))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 92)
                    }
                    .buttonStyle(.plain)
                    .position(layout.points[node] ?? .zero)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
        }
        .frame(minHeight: 420)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11), in: RoundedRectangle(cornerRadius: 8))
    }

    private func layout() -> MapLayout {
        var grouped = [String: [String]]()
        for path in notePaths { grouped[clusterName(of: path), default: []].append(path) }
        let clusters = grouped.keys.sorted {
            grouped[$0]!.count == grouped[$1]!.count ? $0 < $1 : grouped[$0]!.count > grouped[$1]!.count
        }

        var result = MapLayout()
        var x = Self.margin
        var y = Self.margin
        var rowHeight: CGFloat = 0
        for cluster in clusters {
            let notes = grouped[cluster]!
            let radius = max(72, Self.nodeSpacing * sqrt(CGFloat(notes.count)) * 0.62 + 36)
            if x + radius * 2 > Self.maxRowWidth, x > Self.margin {
                x = Self.margin
                y += rowHeight + Self.clusterGap
                rowHeight = 0
            }
            let center = CGPoint(x: x + radius, y: y + radius + 16)
            result.clusters.append(ClusterLayout(name: cluster, center: center, radius: radius))
            for (index, note) in notes.enumerated() {
                let angle = CGFloat(index) * 2.399963
                let distance = (radius - 48) * sqrt(CGFloat(index) / CGFloat(max(notes.count - 1, 1)))
                result.points[note] = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            }
            x += radius * 2 + Self.clusterGap
            rowHeight = max(rowHeight, radius * 2 + 16)
        }
        let width = result.clusters.map { $0.center.x + $0.radius }.max() ?? 400
        result.size = CGSize(width: max(width + Self.margin, 500), height: max(y + rowHeight + Self.margin, 460))
        return result
    }

    private func clusterName(of path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "root" : dir
    }

    private func color(for cluster: String) -> Color {
        var hash: UInt32 = 5381
        for byte in cluster.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.6, brightness: 0.92)
    }

    private func short(_ path: String) -> String { (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "") }
}

struct BrainMarkdownView: View {
    let currentPath: String
    let open: (String) -> Void
    // Parsed once at init instead of on every body pass. The per-line
    // AttributedString(markdown:) work is deferred to the visible rows by the
    // LazyVStack below, so opening a long note no longer freezes the main thread.
    private let blocks: [Block]

    init(markdown: String, currentPath: String, open: @escaping (String) -> Void) {
        self.currentPath = currentPath
        self.open = open
        self.blocks = BrainMarkdownView.parse(markdown)
    }

    private enum Block { case line(String), code(String), table([[String]]) }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .line(let line): lineView(line)
                case .code(let code): codeView(code)
                case .table(let rows): tableView(rows)
                }
            }
        }
        // Note links are rewritten to brain:// URLs by inlineMarkdown; route them
        // to the in-app note navigation, everything else to the system browser.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "brain" else { return .systemAction }
            open(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? "")
            return .handled
        })
    }

    private func codeView(_ code: String) -> some View {
        Text(code.trimmingCharacters(in: .newlines))
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tableView(_ rows: [[String]]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(inlineMarkdown(cell))
                            .font(index == 0 ? .body.bold() : .body)
                            .textSelection(.enabled)
                            .padding(.vertical, 2)
                    }
                }
                if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "---" {
            EmptyView()
        } else if let heading = heading(trimmed) {
            Text(inlineMarkdown(heading.text)).font(heading.level == 1 ? .title2.bold() : .headline.bold())
        } else if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if let bullet = bullet(trimmed) {
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text(inlineMarkdown(bullet)).textSelection(.enabled)
            }
        } else {
            Text(inlineMarkdown(trimmed)).textSelection(.enabled)
        }
    }

    private static func parse(_ markdown: String) -> [Block] {
        var lines = markdown.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }
        var blocks: [Block] = []
        var codeLines: [String] = []
        var tableRows: [[String]] = []
        var inCode = false
        func flushTable() {
            if !tableRows.isEmpty { blocks.append(.table(tableRows)); tableRows = [] }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushTable()
                if inCode { blocks.append(.code(codeLines.joined(separator: "\n"))); codeLines = [] }
                inCode.toggle()
            } else if inCode {
                codeLines.append(line)
            } else if let row = tableRow(trimmed) {
                tableRows.append(row)
            } else if isTableSeparator(trimmed) {
                continue
            } else {
                flushTable()
                blocks.append(.line(line))
            }
        }
        flushTable()
        if !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        return blocks
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: linkified(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// Rewrites relative note links (`[t](acme/kickoff.md)`) into `brain://` URLs
    /// so AttributedString turns every link into a tappable one. External links
    /// (http, https, mailto…) are left as-is and open in the browser.
    private func linkified(_ text: String) -> String {
        guard text.contains("](") else { return text }
        let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let title = ns.substring(with: match.range(at: 1))
            let target = ns.substring(with: match.range(at: 2))
            if target.contains("://") || target.hasPrefix("mailto:") {
                out += "[\(title)](\(target))"
            } else {
                let resolved = resolve(target)
                let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolved
                out += "[\(title)](brain:///\(encoded))"
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func tableRow(_ line: String) -> [String]? {
        guard line.hasPrefix("|") && line.hasSuffix("|") && !isTableSeparator(line) else { return nil }
        return line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") && line.hasSuffix("|") else { return false }
        let body = line.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
        return !body.isEmpty && body.allSatisfy { $0 == "-" || $0.isWhitespace }
    }

    private func bullet(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        return String(line.dropFirst(2))
    }

    private func heading(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return level > 0 && !text.isEmpty ? (level, text) : nil
    }

    private func resolve(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        let base = (currentPath as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: base).appendingPathComponent(target).path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct ScreenMirrorView: View {
    @ObservedObject var link: LinkManager
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let img = link.screenImage {
                    ZStack {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .allowsHitTesting(false)
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in if dragStart == nil { dragStart = value.location } }
                                .onEnded { value in
                                    let size = fittedSize(image: img, in: geo.size)
                                    let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
                                    let start = clamp(dragStart ?? value.startLocation, origin: origin, size: size)
                                    let end = clamp(value.location, origin: origin, size: size)
                                    dragStart = nil
                                    if hypot(end.x - start.x, end.y - start.y) < 6 {
                                        link.tapPhone(x: start.x, y: start.y, w: size.width, h: size.height)
                                    } else {
                                        link.swipePhone(x1: start.x, y1: start.y, x2: end.x, y2: end.y, w: size.width, h: size.height)
                                    }
                                })
                    }
                } else {
                    VStack(spacing: 8) {
                        Text("Waiting for the phone screen…")
                        Text("Approve screen sharing on the phone. To control it from Mac, enable Android Bridge in Android Accessibility.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
    }

    private func fittedSize(image: NSImage, in bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func clamp(_ point: CGPoint, origin: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x - origin.x, 0), size.width),
            y: min(max(point.y - origin.y, 0), size.height)
        )
    }
}

struct StatusBadge: View {
    let status: ConnectionState
    var body: some View {
        let (color, label): (Color, String) = {
            switch status {
            case .connected: return (.green, "Connected")
            case .connecting, .reconnecting: return (.orange, "Connecting")
            case .discovering: return (.secondary, "Searching")
            case .disconnected: return (.secondary, "Offline")
            }
        }()
        HStack(spacing: 6) {
            if status == .connecting || status == .reconnecting {
                PulsingDot(color: .orange)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
                    .shadow(color: status == .connected ? Color.green.opacity(0.6) : .clear, radius: 3)
            }
            Text(label).font(.callout).foregroundStyle(color == .secondary ? Color.secondary : color)
        }
        .animation(.easeInOut(duration: 0.25), value: status)
    }
}

/// Interactive banner shown when the phone rings — Answer/Decline act on the phone.
struct IncomingCallView: View {
    let name: String
    let number: String
    let onAnswer: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "phone.fill").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "Incoming call" : name).font(.headline).lineLimit(1)
                    Text(name == number || number.isEmpty ? "Ringing on your phone" : number)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(action: onDecline) {
                    Label("Decline", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
                }
                .tint(.red).buttonStyle(.borderedProminent)
                Button(action: onAnswer) {
                    Label("Answer", systemImage: "phone.fill").frame(maxWidth: .infinity)
                }
                .tint(.green).buttonStyle(.borderedProminent)
            }
            Label("Audio plays on your phone or a paired headset", systemImage: "info.circle")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(width: 340, height: 138, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// In-call panel shown once a call is active: caller, live elapsed timer, and End Call.
/// Audio is on the phone (see the HFP spike) — the copy says so plainly.
struct ActiveCallView: View {
    let name: String
    let number: String
    let start: Date
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "phone.connection.fill").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "On call" : name).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(timerInterval: start...start.addingTimeInterval(24 * 3600), countsDown: false)
                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        if !number.isEmpty && number != name {
                            Text("· \(number)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            Button(action: onEnd) {
                Label("End Call", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
            }
            .tint(.red).buttonStyle(.borderedProminent)
            Label("Audio is on your phone or a paired headset", systemImage: "info.circle")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(width: 340, height: 138, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
    }
}

struct ToastView: View {
    let title: String
    let message: String
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(message).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy notification content")
        }
        .padding(12)
        .frame(width: 360, height: 90, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
    }
}
