import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class MixerController: ObservableObject {
    static let shared = MixerController()

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var appStates: [String: AppMixerState] = [:]
    @Published private(set) var peaks: [String: Float] = [:]
    @Published private(set) var permissionStatus: AudioCapturePermission.Status = .unknown
    @Published private(set) var isRequestingPermission = false
    var hasPermission: Bool { permissionStatus.isGranted }
    /// Soft power switch: app stays in the menu bar, taps/aggregates are torn down while off.
    @Published var isEnabled: Bool = true {
        didSet {
            guard !isSyncingPreferences else { return }
            guard oldValue != isEnabled else { return }
            preferences.isEnabled = isEnabled
            applyEnabledState()
        }
    }
    @Published var launchAtLogin: Bool = false {
        didSet {
            guard !isSyncingPreferences else { return }
            preferences.launchAtLogin = launchAtLogin
            applyLoginItemPreference()
        }
    }
    @Published var showInactiveApps: Bool = false {
        didSet {
            guard !isSyncingPreferences else { return }
            preferences.showInactiveApps = showInactiveApps
            refresh(forceRebuild: false)
        }
    }
    /// Shown in Settings when SMAppService register/unregister fails (common under Xcode).
    @Published private(set) var loginItemMessage: String?

    let diagnostics = AudioDiagnostics()

    private let preferences = MixerPreferences.shared
    private let engine = TapEngine()
    private var refreshTimer: Timer?
    private var peakTimer: Timer?
    private var diagnosticsTimer: Timer?
    private var deviceDebounce: Task<Void, Never>?
    private var processDebounce: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?
    private var didStart = false
    private var isSyncingPreferences = false
    private var activationObserver: NSObjectProtocol?
    /// Every app Core Audio knows about; `apps` is only the filtered UI view.
    private var allApps: [AudioApp] = []
    private var lastDefaultOutputUID: String?

    private init() {
        isSyncingPreferences = true
        isEnabled = preferences.isEnabled
        launchAtLogin = preferences.launchAtLogin
        showInactiveApps = preferences.showInactiveApps
        isSyncingPreferences = false
        permissionStatus = AudioCapturePermission.currentStatus()
        engine.onDevicesChange = { [weak self] in
            self?.scheduleRefresh(forceRebuild: false, delayNs: 300_000_000)
        }
        engine.onProcessesChange = { [weak self] in
            self?.scheduleRefresh(forceRebuild: false, delayNs: 150_000_000)
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        refreshPermissionStatus()
        syncLoginItemFromSystem()
        refresh(forceRebuild: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(forceRebuild: false)
            }
        }
        peakTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePeaks()
            }
        }
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                self.diagnostics.update(sessions: self.engine.activeSessions())
            }
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionStatus(andRebuildIfGranted: true)
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    private func applyEnabledState() {
        if isEnabled {
            AudioLog.shared.event(.route, "WonderMix enabled")
            refresh(forceRebuild: true)
        } else {
            AudioLog.shared.event(.route, "WonderMix disabled")
            engine.teardownAll()
            peaks = [:]
            diagnostics.update(sessions: [])
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        peakTimer?.invalidate()
        diagnosticsTimer?.invalidate()
        refreshTimer = nil
        peakTimer = nil
        diagnosticsTimer = nil
        deviceDebounce?.cancel()
        processDebounce?.cancel()
        permissionPollTask?.cancel()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        engine.teardownAll()
        didStart = false
    }

    /// One-tap flow: ask the system, then open Settings if still blocked, and poll until granted.
    func requestPermission() {
        guard !isRequestingPermission else { return }

        // Already denied → skip the (no-op) dialog and go straight to Settings.
        if permissionStatus == .denied {
            openPermissionSettings()
            return
        }

        isRequestingPermission = true
        AudioCapturePermission.request { [weak self] status in
            guard let self else { return }
            self.permissionStatus = status
            self.isRequestingPermission = false

            if status.isGranted {
                self.refresh(forceRebuild: true)
                return
            }

            AudioCapturePermission.openSystemSettings()
            self.startPermissionPolling()
        }
    }

    func openPermissionSettings() {
        AudioCapturePermission.openSystemSettings()
        startPermissionPolling()
    }

    func refreshPermissionStatus(andRebuildIfGranted: Bool = false) {
        let previous = permissionStatus
        permissionStatus = AudioCapturePermission.currentStatus()
        if andRebuildIfGranted, permissionStatus.isGranted, previous != .authorized {
            refresh(forceRebuild: true)
        }
    }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                let status = AudioCapturePermission.currentStatus()
                permissionStatus = status
                if status.isGranted {
                    refresh(forceRebuild: true)
                    return
                }
            }
        }
    }

    func setVolume(_ volume: Float, for app: AudioApp) {
        var state = state(for: app)
        state.volume = min(max(volume, 0), 1.5)
        appStates[app.key] = state
        preferences.setVolume(state.volume, forBundleID: app.key)
        let gain = state.isMuted ? 0 : state.volume
        engine.setGain(gain, for: app.key)
    }

    func toggleMute(for app: AudioApp) {
        var state = state(for: app)
        state.isMuted.toggle()
        appStates[app.key] = state
        preferences.setMuted(state.isMuted, forBundleID: app.key)
        let gain = state.isMuted ? 0 : state.volume
        engine.setGain(gain, for: app.key)
        AudioLog.shared.event(.route, "\(app.name): \(state.isMuted ? "muted" : "unmuted")")
    }

    func setOutputDevice(uid: String?, for app: AudioApp) {
        var state = state(for: app)
        state.outputDeviceUID = uid
        appStates[app.key] = state
        preferences.setOutputDeviceUID(uid, forBundleID: app.key)
        let target = devices.first { $0.uid == uid }?.name ?? "default output"
        AudioLog.shared.event(.route, "\(app.name): routed to \(target)")
        // A soft sync moves the tap between aggregates; nothing gets torn down.
        refresh(forceRebuild: false)
    }

    func resetAllStates() {
        preferences.resetAll()
        appStates.removeAll()
        refresh(forceRebuild: true)
    }

    func state(for app: AudioApp) -> AppMixerState {
        if let existing = appStates[app.key] {
            return existing
        }
        let loaded = preferences.state(forBundleID: app.key)
        appStates[app.key] = loaded
        return loaded
    }

    func selectedDeviceUID(for app: AudioApp) -> String {
        if let uid = state(for: app).outputDeviceUID,
           devices.contains(where: { $0.uid == uid }) {
            return uid
        }
        return devices.first(where: \.isDefault)?.uid
            ?? devices.first?.uid
            ?? ""
    }

    // MARK: - Diagnostics

    func resetDiagnostics() {
        diagnostics.reset(sessions: engine.activeSessions())
    }

    func diagnosticsReport() -> String {
        diagnostics.update(sessions: engine.activeSessions())
        return diagnostics.report()
    }

    // MARK: - Refresh

    private func refresh(forceRebuild: Bool) {
        permissionStatus = AudioCapturePermission.currentStatus()
        devices = OutputDeviceEnumerator.listOutputDevices()
        allApps = ProcessEnumerator.listApps()
        apps = visibleApps(from: allApps)

        for app in allApps where appStates[app.key] == nil {
            appStates[app.key] = preferences.state(forBundleID: app.key)
        }

        guard MixerRuntimePolicy.shouldDriveAudio(isEnabled: isEnabled, hasPermission: hasPermission) else {
            engine.teardownAll()
            return
        }

        guard let defaultUID = OutputDeviceEnumerator.defaultOutputUID()
                ?? devices.first?.uid
        else {
            return
        }

        if defaultUID != lastDefaultOutputUID {
            if lastDefaultOutputUID != nil {
                let name = devices.first { $0.uid == defaultUID }?.name ?? defaultUID
                AudioLog.shared.event(.route, "default output changed to \(name)")
            }
            lastDefaultOutputUID = defaultUID
        }

        if forceRebuild {
            engine.rebuildAll(apps: allApps, states: appStates, defaultOutputUID: defaultUID)
        } else {
            engine.sync(apps: allApps, states: appStates, defaultOutputUID: defaultUID)
        }
    }

    /// Inactive apps are hidden from the mixer, but they keep their tap so a helper that
    /// resumes playback does not need the tap to be rebuilt.
    private func visibleApps(from source: [AudioApp]) -> [AudioApp] {
        source.filter { app in
            let custom = (appStates[app.key] ?? .default) != .default
            return MixerRuntimePolicy.isVisible(
                isRunningOutput: app.isRunningOutput,
                showInactiveApps: showInactiveApps,
                hasCustomState: custom
            )
        }
    }

    private func updatePeaks() {
        guard isEnabled else {
            if !peaks.isEmpty { peaks = [:] }
            return
        }
        var next: [String: Float] = [:]
        for app in apps {
            let raw = engine.peakLevel(for: app.key)
            let previous = peaks[app.key] ?? 0
            next[app.key] = max(raw, previous * 0.82)
        }
        peaks = next
    }

    private func scheduleRefresh(forceRebuild: Bool, delayNs: UInt64) {
        if forceRebuild {
            deviceDebounce?.cancel()
            deviceDebounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled else { return }
                refresh(forceRebuild: true)
            }
        } else {
            processDebounce?.cancel()
            processDebounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled else { return }
                refresh(forceRebuild: false)
            }
        }
    }

    /// Aligns the toggle with the real SMAppService status without calling register/unregister.
    private func syncLoginItemFromSystem() {
        let enabled = SMAppService.mainApp.status == .enabled
        isSyncingPreferences = true
        launchAtLogin = enabled
        preferences.launchAtLogin = enabled
        isSyncingPreferences = false
        loginItemMessage = nil
    }

    private func applyLoginItemPreference() {
        let service = SMAppService.mainApp

        do {
            if launchAtLogin {
                if service.status == .enabled {
                    loginItemMessage = nil
                    return
                }
                try service.register()
                loginItemMessage = nil
            } else {
                switch service.status {
                case .notRegistered, .notFound:
                    loginItemMessage = nil
                    return
                default:
                    try service.unregister()
                    loginItemMessage = nil
                }
            }
        } catch {
            // Revert toggle to whatever the system actually has.
            isSyncingPreferences = true
            launchAtLogin = (service.status == .enabled)
            preferences.launchAtLogin = launchAtLogin
            isSyncingPreferences = false

            if Self.isRunningFromDevelopmentBuild {
                loginItemMessage =
                    "\"Abrir ao iniciar\" só funciona com o app em /Applications (não pelo Run do Xcode)."
            } else if service.status == .requiresApproval {
                loginItemMessage =
                    "Permita o WonderMix em Ajustes → Geral → Itens de Login e Extensões."
            } else {
                loginItemMessage =
                    "Não foi possível alterar o item de login (\(error.localizedDescription))."
            }
        }
    }

    private static var isRunningFromDevelopmentBuild: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }
}
