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

    private let defaults: UserDefaults
    private let statesKey = "wonderMix.appStates"
    private let launchAtLoginKey = "wonderMix.launchAtLogin"
    private let showInactiveKey = "wonderMix.showInactiveApps"
    private let isEnabledKey = "wonderMix.isEnabled"
    private let equalizerKey = "wonderMix.equalizerConfig"

    private var states: [String: AppMixerState] = [:]
    private var cachedEqualizerConfig: EqualizerConfiguration?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// When unset, defaults to enabled so existing installs keep working.
    var isEnabled: Bool {
        get {
            guard defaults.object(forKey: isEnabledKey) != nil else { return true }
            return defaults.bool(forKey: isEnabledKey)
        }
        set { defaults.set(newValue, forKey: isEnabledKey) }
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

    var equalizerConfig: EqualizerConfiguration {
        get {
            if let cached = cachedEqualizerConfig {
                return cached
            }
            if let data = defaults.data(forKey: equalizerKey),
               let decoded = try? JSONDecoder().decode(EqualizerConfiguration.self, from: data) {
                cachedEqualizerConfig = decoded
                return decoded
            }
            return .default
        }
        set {
            cachedEqualizerConfig = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: equalizerKey)
            }
        }
    }

    func resetEqualizer() {
        equalizerConfig = .default
    }

    func resetAll() {
        states.removeAll()
        persist()
        resetEqualizer()
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
