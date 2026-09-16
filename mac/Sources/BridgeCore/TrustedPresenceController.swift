import Foundation
import AppKit
import Combine

/// Watches for trusted Wi-Fi routers and Bluetooth devices and applies the user's two
/// switches. Owns all the timing and side effects; the decisions themselves are pure
/// functions in `TrustedPresence`, which is where the tests are.
public final class TrustedPresenceController: ObservableObject {

    @Published public private(set) var snapshot = PresenceSnapshot(wifiSSID: nil, connectedBluetoothAddresses: [])
    @Published public private(set) var matched: [TrustedPlace] = []
    @Published public private(set) var isHoldingAwake = false
    @Published public private(set) var passwordRequired = true
    @Published public private(set) var lastError: String?

    @Published public var settings: TrustedPresenceSettings {
        didSet {
            store.save(settings)
            refresh()
        }
    }

    public var isTrusted: Bool { !matched.isEmpty }
    public let passwords = LoginPasswordStore()
    public let location = LocationAccess()

    private let store: TrustedPresenceStore
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    public init(store: TrustedPresenceStore = TrustedPresenceStore()) {
        self.store = store
        self.settings = store.load()
    }

    /// Begins watching. Safe to call once from the app delegate.
    public func start(interval: TimeInterval = 20) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.apply(TrustedPresence.planForSleep(settings: self?.settings ?? .disabled))
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            },
            // Wi-Fi comes and goes faster than the poll interval; react to it directly.
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            },
        ]
        refresh()
    }

    /// Restores normal locking. Call from `applicationWillTerminate` so quitting the app
    /// can never leave the Mac permanently unlocked.
    public func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        apply(TrustedPresence.planForShutdown())
    }

    /// Reads the world once and applies whatever the settings call for.
    public func refresh() {
        snapshot = PresenceSensor.snapshot(includeBluetooth: TrustedPresence.needsBluetooth(places: settings.places))
        matched = TrustedPresence.present(in: snapshot, trusted: settings.places)
        apply(TrustedPresence.plan(settings: settings, isTrusted: isTrusted))
    }

    public func add(_ place: TrustedPlace) {
        guard !settings.places.contains(where: { $0.id == place.id }) else { return }
        settings.places.append(place)
    }

    public func remove(_ place: TrustedPlace) {
        settings.places.removeAll { $0.id == place.id }
    }

    private func apply(_ plan: PresencePlan) {
        ScreenLockControl.setAwakeHold(plan.holdAwake)
        isHoldingAwake = ScreenLockControl.isHoldingAwake

        // App ownership is enough to decide the next transition. Querying `sysadminctl status`
        // here used a full CPU core on every 20-second presence poll.
        let appDisabledIt = appDisabledLockPassword
        let action = TrustedPresence.lockAction(
            plan: plan,
            featureEnabled: settings.disableLockPassword,
            currentlyRequiresPassword: !appDisabledIt,
            appDisabledIt: appDisabledIt
        )
        passwordRequired = !appDisabledIt
        guard let action else {
            // Nothing to change means nothing is wrong. Without this, an error raised once —
            // "no login password saved", say — outlived the thing that caused it and sat on
            // screen contradicting the rest of the tab.
            lastError = nil
            return
        }

        do {
            try ScreenLockControl.setPasswordRequired(action == .restore)
            appDisabledLockPassword = (action == .disable)
            passwordRequired = (action == .restore)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Remembers that this app, rather than the user, turned the wake password off.
    /// Persisted so a crash or a restart still restores what the app disabled.
    private var appDisabledLockPassword: Bool {
        get { UserDefaults.standard.bool(forKey: "trustedPresence.appDisabledLockPassword") }
        set { UserDefaults.standard.set(newValue, forKey: "trustedPresence.appDisabledLockPassword") }
    }
}
