import Foundation

struct AppMixerState: Codable, Equatable {
    var volume: Float
    var isMuted: Bool
    var outputDeviceUID: String?

    static let `default` = AppMixerState(volume: 1.0, isMuted: false, outputDeviceUID: nil)
}

@MainActor
final class MixerPreferences {
    static let shared = MixerPreferences()

    private let defaults = UserDefaults.standard
    private let statesKey = "wonderMix.appStates"
    private let launchAtLoginKey = "wonderMix.launchAtLogin"
    private let showInactiveKey = "wonderMix.showInactiveApps"

    private var states: [String: AppMixerState] = [:]

    private init() {
        load()
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: launchAtLoginKey) }
        set { defaults.set(newValue, forKey: launchAtLoginKey) }
    }

    var showInactiveApps: Bool {
        get { defaults.object(forKey: showInactiveKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: showInactiveKey) }
    }

    func state(forBundleID bundleID: String) -> AppMixerState {
        states[bundleID] ?? .default
    }

    func setVolume(_ volume: Float, forBundleID bundleID: String) {
        var state = state(forBundleID: bundleID)
        state.volume = min(max(volume, 0), 1.5)
        states[bundleID] = state
        persist()
    }

    func setMuted(_ muted: Bool, forBundleID bundleID: String) {
        var state = state(forBundleID: bundleID)
        state.isMuted = muted
        states[bundleID] = state
        persist()
    }

    func setOutputDeviceUID(_ uid: String?, forBundleID bundleID: String) {
        var state = state(forBundleID: bundleID)
        state.outputDeviceUID = uid
        states[bundleID] = state
        persist()
    }

    func resetAll() {
        states.removeAll()
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: statesKey) else { return }
        if let decoded = try? JSONDecoder().decode([String: AppMixerState].self, from: data) {
            states = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(states) {
            defaults.set(data, forKey: statesKey)
        }
    }
}
