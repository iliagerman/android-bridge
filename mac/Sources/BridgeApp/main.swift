import AppKit
import SwiftUI
import Combine
import UserNotifications
import BridgeCore

// Pure-AppKit menu-bar app (reliable across ad-hoc builds, unlike SwiftUI MenuBarExtra). A status-bar
// item opens AppKit-hosted SwiftUI windows; inbound events show a custom banner (works without the
// notification entitlement that ad-hoc apps lack).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate, NSWindowDelegate, NSMenuItemValidation {

    /// Phone-dependent menu items are greyed out while the phone is not connected.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openScreen) { return LinkManager.shared.status == .connected }
        if menuItem.action == #selector(pushClipboard) { return LinkManager.shared.status == .connected }
        return true
    }
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var screenWindow: NSWindow?
    private var screenShown = false
    private var toastPanels: [NSPanel] = []
    private var callPanel: NSPanel?
    private var meetingReviewPanel: NSPanel?
    private var meetingReviewMeetingId: String?
    private var pendingMeetingReviews: [MeetingCalendarReview] = []
    private var cancellables = Set<AnyCancellable>()
    private let updates = MacUpdateController()
    private let presence = TrustedPresenceController()
    private var menuBarVisibilityTimer: Timer?
    private var menuBarIconHidden = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "setup.mode") == nil {
            defaults.set(defaults.bool(forKey: "setupWizard.seen") ? "macAndAndroid" : "macOnly", forKey: "setup.mode")
        }
        do {
            try SecondBrainSkillManager.installBundledSkillIfNeeded()
        } catch {
            diag("second-brain skill installation failed: \(error.localizedDescription)")
        }

        // Pin the item as far RIGHT as a third-party item is allowed to sit, because a
        // crowded menu bar hides the leftmost items first.
        //
        // The value is distance in points from the right edge, so SMALLER is further right.
        // macOS reserves the right-hand cluster for itself — on a typical Mac the clock is
        // at 66 and Control Center runs from 153 (BentoBox) out to 386 (Sound) — and it will
        // not honour a third-party item placed inside that range. v1 asked for 100, landed
        // in the reserved zone, and got pushed to the far left where it was the first thing
        // hidden. 400 is immediately left of the system cluster: the rightmost slot actually
        // available, so ours is the last third-party icon to be dropped.
        if !UserDefaults.standard.bool(forKey: "com.androidbridge.pinnedRight.v2") {
            UserDefaults.standard.set(400.0, forKey: "NSStatusItem Preferred Position AndroidBridge")
            UserDefaults.standard.set(true, forKey: "com.androidbridge.pinnedRight.v2")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "AndroidBridge" // remember position if the user ⌘-drags it
        if let btn = statusItem.button {
            if let img = NSImage(systemSymbolName: "arrow.left.arrow.right.circle.fill", accessibilityDescription: "Android Bridge") {
                img.isTemplate = true
                btn.image = img
            } else {
                btn.title = "⟷"
            }
        }
        let menu = NSMenu()
        menu.addItem(appMenuItem("Open Bridge", action: #selector(openBridge), key: "o"))
        menu.addItem(appMenuItem("Open Meetings", action: #selector(openMeetings), key: "m"))
        menu.addItem(appMenuItem("Open Second Brain", action: #selector(openSecondBrain), key: "b"))
        menu.addItem(appMenuItem("Open Trusted Presence", action: #selector(openTrustedPresence), key: "t"))
        menu.addItem(appMenuItem("Open Settings", action: #selector(openSettings), key: ","))
        menu.addItem(appMenuItem("Open Phone Screen", action: #selector(openScreen), key: "s"))
        menu.addItem(.separator())
        menu.addItem(quickActionsMenuItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Android Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        diag("statusItem created: visible=\(statusItem.isVisible) hasButton=\(statusItem.button != nil) hasImage=\(statusItem.button?.image != nil)")
        // macOS silently hides status items when the menu bar is full. If ours is occluded,
        // fall back to a Dock icon so the app is always reachable, and tell the user why.
        //
        // Re-checked on a timer rather than once: the menu bar fills and empties as other
        // apps come and go, and a one-shot check at 6s left the app unreachable whenever it
        // was hidden later. The warning is shown only on the first transition into hidden.
        // Not at 6s: the menu bar is still laying itself out then and reports a false
        // "hidden", which cost an unnecessary policy flip. First real check at 20s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.checkMenuBarVisibility(announce: true) }
        let visibilityTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkMenuBarVisibility(announce: false)
        }
        RunLoop.main.add(visibilityTimer, forMode: .common)
        self.menuBarVisibilityTimer = visibilityTimer

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        LinkManager.shared.start()

        LinkManager.shared.$screenImage.receive(on: RunLoop.main).sink { [weak self] img in
            guard let self else { return }
            if img != nil && !self.screenShown { self.screenShown = true; self.openScreenInternal(requestShare: false) }
            if img == nil { self.screenShown = false }
        }.store(in: &cancellables)

        LinkManager.shared.notificationSubject.receive(on: RunLoop.main).sink { [weak self] event in
            self?.showToast(title: event.title, body: event.body, userInfo: event.userInfo)
        }.store(in: &cancellables)

        LinkManager.shared.incomingCallSubject.receive(on: RunLoop.main).sink { [weak self] call in
            self?.showCallPanel(number: call.number, name: call.name)
        }.store(in: &cancellables)

        LinkManager.shared.callStateSubject.receive(on: RunLoop.main).sink { [weak self] ev in
            switch ev.state {
            case "active": self?.showActiveCallPanel(number: ev.number, name: ev.name)
            case "ended": self?.dismissCallPanel()
            default: break
            }
        }.store(in: &cancellables)

        LinkManager.shared.calendarReviewSubject.receive(on: RunLoop.main).sink { [weak self] review in
            self?.enqueueMeetingReview(review)
        }.store(in: &cancellables)

        openDashboard()
        updates.startAutomaticCheck()
        presence.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        LinkManager.shared.stop()
        updates.cleanup()
        presence.stop()  // never leave the Mac unlocked because the app went away
    }

    @objc private func systemWillSleep() { LinkManager.shared.prepareForSleep() }
    @objc private func systemDidWake() { LinkManager.shared.resumeAfterWake() }

    private func appMenuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func quickActionsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quick Actions", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Quick Actions")
        menu.addItem(appMenuItem("Push Clipboard", action: #selector(pushClipboard), key: ""))
        item.submenu = menu
        return item
    }

    private func installMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem()
        let edit = NSMenuItem()
        main.addItem(app)
        main.addItem(edit)

        let appMenu = NSMenu(title: "Android Bridge")
        appMenu.addItem(NSMenuItem(title: "Quit Android Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        app.submenu = appMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.submenu = editMenu
        NSApp.mainMenu = main
    }

    @objc func openDashboard() {
        if window == nil {
            let size = AppUIState.windowSize()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Android Bridge"
            w.isReleasedWhenClosed = false
            // Without this an accessory app's window is treated as transient: macOS parks it
            // in its own Space and refuses to let it be dragged to another desktop.
            // `.managed` makes it an ordinary window that belongs to a Space like any other.
            w.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
            w.center()
            w.delegate = self
            w.contentView = NSHostingView(rootView: DashboardView(link: LinkManager.shared, updates: updates, presence: presence))
            window = w
            AppUIState.shared.window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func openBridge() {
        AppUIState.shared.selectedTab = 0
        openDashboard()
    }

    @objc func openMeetings() {
        AppUIState.shared.selectedTab = 1
        openDashboard()
    }

    @objc func openSecondBrain() {
        AppUIState.shared.selectedTab = 2
        openDashboard()
    }

    @objc func openTrustedPresence() {
        AppUIState.shared.selectedTab = 4
        openDashboard()
    }

    @objc func openSettings() {
        AppUIState.shared.selectedTab = 3
        openDashboard()
    }

    /// The size the user drags the dashboard to becomes the new default for every tab.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        AppUIState.saveWindowSize(w.frame.size)
    }

    @objc func openScreen() {
        openScreenInternal(requestShare: true)
    }

    @objc func pushClipboard() {
        LinkManager.shared.sendClipboard(NSPasteboard.general.string(forType: .string) ?? "")
    }

    func openScreenInternal(requestShare: Bool) {
        if requestShare { LinkManager.shared.requestPhoneScreen() }
        if screenWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Phone Screen"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentView = NSHostingView(rootView: ScreenMirrorView(link: LinkManager.shared))
            screenWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        screenWindow?.makeKeyAndOrderFront(nil)
    }

    /// Keeps the app reachable when macOS hides our menu bar icon: shows a Dock icon while
    /// hidden, and drops back to menu-bar-only when the icon reappears.
    private func checkMenuBarVisibility(announce: Bool) {
        let hidden = statusItem.button?.window?.occlusionState.contains(.visible) == false
        let changed = hidden != menuBarIconHidden
        guard changed || announce else { return }
        menuBarIconHidden = hidden
        if changed { diag("menu bar icon hidden=\(hidden)") }
        applyActivationPolicy()
        guard hidden, announce else { return }
        showToast(title: "Menu bar is full",
                  body: "macOS hid the Android Bridge icon — using a Dock icon instead. ⌘-drag other icons off the menu bar, or hide some in System Settings ▸ Control Center, to make room.")
    }

    /// Shows a Dock icon only while the menu bar icon is hidden.
    ///
    /// Deferred while a window is on screen: changing activation policy re-parents every open
    /// window, and macOS can strand one in a Space of its own that cannot be dragged to
    /// another desktop. Nothing is lost by waiting — the Dock icon exists to reach the app
    /// when no window is showing, which is exactly when this is allowed to run.
    private func applyActivationPolicy() {
        guard window?.isVisible != true else { return }
        NSApp.setActivationPolicy(menuBarIconHidden ? .regular : .accessory)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        DispatchQueue.main.async { self.applyActivationPolicy() }
    }

    private func diag(_ s: String) {
        let line = "[\(Int(Date().timeIntervalSince1970))] \(s)\n"
        let url = URL(fileURLWithPath: "/tmp/androidbridge-diag.txt")
        if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close() }
        else { try? line.data(using: .utf8)!.write(to: url) }
    }

    private func showToast(title: String, body: String, userInfo: [AnyHashable: Any] = [:]) {
        diag("TOAST_FIRED title=\(title)")
        let copyText = userInfo["path"] as? String ?? body
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.contentView = NSHostingView(rootView: ToastView(title: title, message: body) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyText, forType: .string)
        }.onTapGesture { [weak panel] in
            LinkManager.shared.handleNotificationClick(userInfo)
            panel?.orderOut(nil)
        })
        if toastPanels.count >= 5 {
            let oldest = toastPanels.removeFirst()
            oldest.contentView = nil
            oldest.close()
        }
        if let vf = NSScreen.main?.visibleFrame {
            let offset = CGFloat(96 + toastPanels.count * 92)
            panel.setFrameOrigin(NSPoint(x: vf.maxX - 376, y: vf.maxY - offset))
        }
        panel.orderFrontRegardless()
        toastPanels.append(panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.contentView = nil
            panel.close()
            self.toastPanels.removeAll { $0 === panel }
        }
    }

    /// Interactive top-right panel for a ringing phone: Answer / Decline act on the phone remotely.
    /// Unlike toasts this accepts clicks, so it must not be `ignoresMouseEvents`.
    private func showCallPanel(number: String, name: String) {
        diag("CALL_PANEL_FIRED name=\(name)")
        callPanel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 138),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        let dismiss: () -> Void = { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.callPanel === panel { self?.callPanel = nil }
        }
        panel.contentView = NSHostingView(rootView: IncomingCallView(
            name: name, number: number,
            onAnswer: { LinkManager.shared.answerCall(); dismiss() },
            onDecline: { LinkManager.shared.hangupCall(); dismiss() }))
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.minX + 16, y: vf.maxY - 154))
        }
        panel.orderFrontRegardless()
        callPanel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak panel] in
            guard let panel, self?.callPanel === panel else { return }
            dismiss()
        }
    }

    private func enqueueMeetingReview(_ review: MeetingCalendarReview) {
        guard meetingReviewPanel == nil else {
            if meetingReviewMeetingId != review.meeting.id,
               !pendingMeetingReviews.contains(where: { $0.meeting.id == review.meeting.id }) {
                pendingMeetingReviews.append(review)
            }
            return
        }
        showMeetingReview(review)
    }

    private func showMeetingReview(_ review: MeetingCalendarReview) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Review meeting"
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let finish: () -> Void = { [weak self, weak panel] in
            panel?.orderOut(nil)
            panel?.contentView = nil
            self?.meetingReviewPanel = nil
            self?.meetingReviewMeetingId = nil
            guard let next = self?.pendingMeetingReviews.first else { return }
            self?.pendingMeetingReviews.removeFirst()
            self?.showMeetingReview(next)
        }
        panel.contentView = NSHostingView(rootView: MeetingCalendarReviewView(
            review: review,
            customers: LinkManager.shared.customers,
            onDismiss: {
                finish()
                LinkManager.shared.dismissCalendarCandidates(for: review.meeting)
            },
            onSave: { event, customer in
                LinkManager.shared.saveMeetingReview(event: event, customer: customer, for: review.meeting)
                finish()
            }
        ))
        panel.center()
        meetingReviewPanel = panel
        meetingReviewMeetingId = review.meeting.id
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Once a call is active, replace the ringing panel with an in-call panel (elapsed time + End Call).
    private func showActiveCallPanel(number: String, name: String) {
        diag("ACTIVE_CALL_PANEL name=\(name)")
        callPanel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 138),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        let dismiss: () -> Void = { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.callPanel === panel { self?.callPanel = nil }
        }
        panel.contentView = NSHostingView(rootView: ActiveCallView(
            name: name, number: number, start: Date(),
            onEnd: { LinkManager.shared.hangupCall(); dismiss() }))
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.minX + 16, y: vf.maxY - 154))
        }
        panel.orderFrontRegardless()
        callPanel = panel
    }

    /// The call ended on the phone — tear down whatever call panel is showing.
    private func dismissCallPanel() {
        diag("CALL_PANEL_DISMISS")
        callPanel?.orderOut(nil)
        callPanel = nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        LinkManager.shared.handleNotificationClick(response.notification.request.content.userInfo)
        completionHandler()
    }

    /// Clicking the Dock icon (fallback mode) reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDashboard() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        m.addItem(appMenuItem("Open Bridge", action: #selector(openBridge), key: ""))
        m.addItem(appMenuItem("Open Meetings", action: #selector(openMeetings), key: ""))
        m.addItem(appMenuItem("Open Second Brain", action: #selector(openSecondBrain), key: ""))
        m.addItem(appMenuItem("Open Settings", action: #selector(openSettings), key: ""))
        m.addItem(appMenuItem("Open Phone Screen", action: #selector(openScreen), key: ""))
        m.addItem(.separator())
        m.addItem(quickActionsMenuItem())
        return m
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
