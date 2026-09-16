import AppKit
import AVFoundation
import BridgeCore
import CoreImage.CIFilterBuiltins
import SwiftUI
import UserNotifications

@MainActor
final class SetupWizardModel: ObservableObject {
    @Published var states = [SetupDependencyID: SetupDependencyState]()
    @Published var output = ""
    @Published var pendingConfirmation: SetupDependency?
    @Published var activeDependency: SetupDependencyID?

    let dependencies: [SetupDependency]
    private let detector: SetupDetector
    private var process: Process?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let toolRoot = Bundle.main.resourceURL?.appendingPathComponent("Tools/mlx_whisper")
        let requirements = toolRoot?.appendingPathComponent("requirements.txt")
        let bundledPython = toolRoot?.appendingPathComponent(".venv/bin/python")
        dependencies = SetupCatalog.dependencies(applicationSupport: support, requirements: requirements)
        detector = SetupDetector(applicationSupport: support, bundledWhisperPython: bundledPython)
        refresh()
    }

    func refresh() {
        for dependency in dependencies { states[dependency.id] = .checking }
        let dependencies = dependencies
        let detector = detector
        Task.detached {
            let detected = Dictionary(uniqueKeysWithValues: dependencies.map { ($0.id, detector.state(for: $0.id)) })
            await MainActor.run { self.states = detected }
        }
    }

    func requestInstall(_ dependency: SetupDependency) {
        pendingConfirmation = dependency
    }

    func installConfirmed() {
        guard let dependency = pendingConfirmation else { return }
        pendingConfirmation = nil
        activeDependency = dependency.id
        states[dependency.id] = .installing
        output = "$ \(([dependency.installProgram] + dependency.installArguments).joined(separator: " "))\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: dependency.installProgram)
        process.arguments = dependency.installArguments
        process.environment = setupProcessEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.process = process

        Task.detached {
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run {
                    self.output += text
                    self.activeDependency = nil
                    self.process = nil
                    self.states[dependency.id] = process.terminationStatus == 0
                        ? self.detector.state(for: dependency.id)
                        : .failed("Installation exited with status \(process.terminationStatus).")
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.activeDependency = nil
                    self.process = nil
                    self.states[dependency.id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        process?.interrupt()
    }
}

struct SetupWizardView: View {
    @ObservedObject var link: LinkManager
    @StateObject private var model = SetupWizardModel()
    @ObservedObject private var ui = AppUIState.shared
    @State private var page = 0
    @State private var notificationsGranted = false
    @AppStorage("setup.mode") private var setupMode = "macOnly"

    private var includesAndroid: Bool { setupMode == "macAndAndroid" }
    private var pages: [String] {
        includesAndroid
            ? ["Welcome", "Dependencies", "Permissions", "Android phone", "Ready"]
            : ["Welcome", "Dependencies", "Permissions", "Ready"]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "wand.and.stars").font(.title).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Android Bridge Setup").font(.title2).bold()
                    Text(pages[page]).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(page + 1) of \(pages.count)").foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            Group {
                switch page {
                case 0: welcome
                case 1: dependencies
                case 2: permissions
                case 3 where includesAndroid: androidPhone
                default: readiness
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Back") { page -= 1 }.disabled(page == 0)
                Spacer()
                if page == pages.count - 1 {
                    Button("Finish") {
                        UserDefaults.standard.set(true, forKey: "setupWizard.seen")
                        ui.showSetup = false
                    }.buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") { page += 1 }.buttonStyle(.borderedProminent)
                }
            }.padding()
        }
        .frame(minWidth: 760, minHeight: 620)
        .onAppear {
            refreshNotificationPermission()
            link.setPhoneFeaturesEnabled(includesAndroid)
        }
        .onChange(of: setupMode) { _ in link.setPhoneFeaturesEnabled(includesAndroid) }
        .confirmationDialog("Install \(model.pendingConfirmation?.name ?? "dependency")?", isPresented: Binding(
            get: { model.pendingConfirmation != nil },
            set: { if !$0 { model.pendingConfirmation = nil } }
        )) {
            Button("Install") { model.installConfirmed() }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
        } message: {
            if let dependency = model.pendingConfirmation {
                Text("\(dependency.purpose)\n\nCommand: \(([dependency.installProgram] + dependency.installArguments).joined(separator: " "))")
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.and.mic").font(.system(size: 72)).foregroundStyle(.blue)
            Text("Choose how you will use Android Bridge").font(.largeTitle).bold()
            Picker("Setup mode", selection: $setupMode) {
                Text("Mac only").tag("macOnly")
                Text("Mac + Android phone").tag("macAndAndroid")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            Text(includesAndroid
                 ? "Set up Meetings, Second Brain, and phone continuity features."
                 : "Set up local meeting recording, transcription, summaries, and Second Brain. No Android app or phone is required.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 560)
            Text("Existing tools are detected automatically. Every third-party installation requires separate approval.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 560)
        }.padding(40)
    }

    private var dependencies: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tools and local AI").font(.title2).bold()
                Spacer()
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            ScrollView {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Second Brain skill").font(.headline)
                            Text("Embedded in the app and copied to an editable user folder on first launch.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    ForEach(model.dependencies) { dependency in dependencyRow(dependency) }
                }
            }
            if !model.output.isEmpty {
                ScrollView { Text(model.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 120).padding(8).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
            }
        }.padding()
    }

    private func dependencyRow(_ dependency: SetupDependency) -> some View {
        HStack(spacing: 12) {
            Image(systemName: stateIcon(model.states[dependency.id])).foregroundStyle(stateColor(model.states[dependency.id])).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(dependency.name).font(.headline)
                Text(dependency.purpose).font(.caption).foregroundStyle(.secondary)
                Text(stateText(model.states[dependency.id])).font(.caption).foregroundStyle(stateColor(model.states[dependency.id]))
            }
            Spacer()
            if model.activeDependency == dependency.id {
                Button("Cancel") { model.cancel() }
            } else {
                Button(isInstalled(model.states[dependency.id]) ? "Repair…" : "Install…") { model.requestInstall(dependency) }
                    .disabled(model.activeDependency != nil || model.states[dependency.id] == .checking)
            }
        }.padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var permissions: some View {
        Form {
            Section("macOS permissions") {
                permissionRow("Microphone", granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, action: requestMicrophone)
                permissionRow("Screen & System Audio", granted: CGPreflightScreenCaptureAccess(), action: requestScreenCapture)
                permissionRow("Notifications", granted: notificationsGranted, action: { openSettings("Notifications") })
                if includesAndroid {
                    permissionRow("Accessibility", granted: AXIsProcessTrusted(), action: { openSettings("Privacy_Accessibility") })
                    Text("Local Network permission is requested by macOS when Android Bridge first discovers your phone.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped).padding()
    }

    private func permissionRow(_ name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? .green : .secondary)
            Spacer()
            if !granted { Button("Open / Request") { action() } }
        }
    }

    private var androidPhone: some View {
        VStack(spacing: 18) {
            Text("Install Android Bridge on your phone").font(.title2).bold()
            if let image = qrImage(apkURL) { Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220) }
            Link("Download AndroidBridge-android.apk", destination: apkURL)
            Text("Optional Android 13+ companion: allow ‘Install unknown apps’ for your browser or file manager, install the release-signed APK, grant the requested permissions, then open it on the same Wi-Fi network.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 580)
            Label(link.status == .connected ? "Phone connected" : "Waiting for phone connection", systemImage: link.status == .connected ? "checkmark.circle.fill" : "wifi")
                .foregroundStyle(link.status == .connected ? .green : .secondary)
        }.padding()
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Readiness summary").font(.title2).bold()
            ForEach(model.dependencies) { dependency in
                Label("\(dependency.name): \(stateText(model.states[dependency.id]))", systemImage: isInstalled(model.states[dependency.id]) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isInstalled(model.states[dependency.id]) ? .green : .secondary)
            }
            Divider()
            if includesAndroid {
                Label(link.status == .connected ? "Android phone connected" : "Android phone not connected", systemImage: link.status == .connected ? "checkmark.circle.fill" : "iphone")
            } else {
                Label("Mac-only setup selected. Android is not required.", systemImage: "laptopcomputer")
                    .foregroundStyle(.green)
            }
            Text("You can finish now and return to Setup from Settings at any time. Transcription needs ffmpeg, Python, and MLX Whisper. Summaries and Q&A need either Ollama or pi.").foregroundStyle(.secondary)
        }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var apkURL: URL { URL(string: "https://github.com/iliagerman/android-bridge/releases/latest/download/AndroidBridge-android.apk")! }

    private func qrImage(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    private func requestMicrophone() { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
    private func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }
    private func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { notificationsGranted = settings.authorizationStatus == .authorized }
        }
    }
    private func openSettings(_ anchor: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!) }
    private func isInstalled(_ state: SetupDependencyState?) -> Bool { if case .installed = state { return true }; return false }
    private func stateIcon(_ state: SetupDependencyState?) -> String { isInstalled(state) ? "checkmark.circle.fill" : state == .installing ? "arrow.triangle.2.circlepath" : "circle" }
    private func stateColor(_ state: SetupDependencyState?) -> Color {
        if isInstalled(state) { return .green }
        if case .failed = state { return .red }
        return .secondary
    }
    private func stateText(_ state: SetupDependencyState?) -> String {
        switch state { case .checking: return "Checking…"; case .missing: return "Not installed"; case .installed(let detail): return "Installed · \(detail)"; case .installing: return "Installing…"; case .failed(let error): return error; case nil: return "Checking…" }
    }
}
