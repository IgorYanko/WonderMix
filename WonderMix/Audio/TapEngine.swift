import AppKit
import CoreAudio
import Foundation

@MainActor
final class TapEngine {
    /// One tap per app, keyed by app key. Lives as long as the app itself.
    private var taps: [String: AppTap] = [:]
    /// One aggregate + IOProc per output device, keyed by device UID.
    private var sessions: [String: DeviceMixSession] = [:]

    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var processListener: AudioObjectPropertyListenerBlock?
    private var isListening = false
    /// Devices whose aggregate failed to start, with the time of the failure. Retrying
    /// every sync would tap and untap the affected apps a few times per minute.
    private var deviceFailures: [String: Date] = [:]
    private static let deviceFailureCooldown: TimeInterval = 15
    private var currentEqualizerConfig: EqualizerConfiguration?

    /// Default output / device list changed — needs full rebuild.
    var onDevicesChange: (() -> Void)?
    /// Process list changed — soft sync only (never tears down audio).
    var onProcessesChange: (() -> Void)?

    func applyEqualizer(_ config: EqualizerConfiguration) {
        currentEqualizerConfig = config
        for session in sessions.values {
            session.applyEqualizer(config)
        }
    }

    func setGain(_ gain: Float, for key: String) {
        taps[key]?.setGain(gain)
    }

    func peakLevel(for key: String) -> Float {
        taps[key]?.peakLevel ?? 0
    }

    func activeSessions() -> [DeviceMixSession] {
        sessions.values.sorted { $0.deviceName < $1.deviceName }
    }

    func teardownAll() {
        for session in sessions.values {
            session.teardown()
        }
        sessions.removeAll()
        for tap in taps.values {
            tap.teardown()
        }
        taps.removeAll()
        deviceFailures.removeAll()
        stopListening()
        destroyOrphanWonderMixAggregates()
        // Safe now: every aggregate is stopped, so no IOProc can still hold a channel.
        AppTap.releaseRetiredChannels()
    }

    /// Removes private aggregates left behind after a crash.
    func destroyOrphanWonderMixAggregates() {
        let deviceIDs: [AudioObjectID]
        do {
            deviceIDs = try CoreAudioHelper.getPropertyArray(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
        } catch {
            return
        }

        for deviceID in deviceIDs {
            guard
                let name = try? CoreAudioHelper.getStringProperty(
                    objectID: deviceID,
                    selector: kAudioObjectPropertyName
                ),
                name.hasPrefix("WonderMix")
            else {
                continue
            }
            if AudioHardwareDestroyAggregateDevice(deviceID) == noErr {
                AudioLog.shared.event(.aggregate, "removed orphan aggregate \"\(name)\"")
            }
        }
    }

    /// Reconciles taps and routing with the current app list.
    ///
    /// Nothing is torn down because an app's process objects changed — the tap
    /// description is rewritten in place instead. That churn was audible both as gaps
    /// and as the app briefly escaping its mute back onto the default device.
    func sync(
        apps: [AudioApp],
        states: [String: AppMixerState],
        defaultOutputUID: String
    ) {
        let liveKeys = Set(apps.map(\.key))

        // An app only loses its tap when it disappears from Core Audio entirely.
        for key in Array(taps.keys) where !liveKeys.contains(key) {
            retireTap(for: key)
        }

        var routing: [String: [AppTap]] = [:]

        for app in apps {
            let state = states[app.key] ?? .default
            let deviceUID = resolvedDeviceUID(state.outputDeviceUID, fallback: defaultOutputUID)
            let gain = state.isMuted ? 0 : state.volume

            // A tapped app whose device has no working aggregate would be silent, since
            // the tap keeps muting it. Leave it untapped until the device recovers.
            if isInCooldown(deviceUID) {
                if taps[app.key] != nil {
                    retireTap(for: app.key)
                }
                continue
            }

            let tap: AppTap
            if let existing = taps[app.key] {
                existing.updateProcesses(app.processObjectIDs)
                tap = existing
            } else if shouldTap(app: app, state: state) {
                do {
                    let created = try AppTap(
                        key: app.key,
                        name: app.name,
                        processObjectIDs: app.processObjectIDs,
                        gain: gain
                    )
                    taps[app.key] = created
                    tap = created
                } catch {
                    AudioLog.shared.warning(
                        .tap,
                        "\(app.name): tap not created: \(error.localizedDescription)"
                    )
                    continue
                }
            } else {
                continue
            }

            tap.setGain(gain)
            routing[deviceUID, default: []].append(tap)
        }

        applyRouting(routing)
        startListeningIfNeeded()
    }

    func rebuildAll(
        apps: [AudioApp],
        states: [String: AppMixerState],
        defaultOutputUID: String
    ) {
        AudioLog.shared.event(.route, "full rebuild requested")
        for session in sessions.values {
            session.teardown()
        }
        sessions.removeAll()
        for tap in taps.values {
            tap.teardown()
        }
        taps.removeAll()
        deviceFailures.removeAll()
        destroyOrphanWonderMixAggregates()
        AppTap.releaseRetiredChannels()
        sync(apps: apps, states: states, defaultOutputUID: defaultOutputUID)
    }

    // MARK: - Routing

    private func applyRouting(_ routing: [String: [AppTap]]) {
        for (deviceUID, deviceTaps) in routing {
            if let session = sessions[deviceUID] {
                session.setTaps(deviceTaps)
                continue
            }
            guard let session = makeSession(deviceUID: deviceUID, taps: deviceTaps) else {
                // Restore normal system routing for these apps instead of leaving them
                // muted by a tap that nothing is consuming.
                deviceFailures[deviceUID] = Date()
                for tap in deviceTaps {
                    retireTap(for: tap.key)
                }
                continue
            }
            deviceFailures.removeValue(forKey: deviceUID)
            sessions[deviceUID] = session
        }

        for deviceUID in Array(sessions.keys) where routing[deviceUID] == nil {
            guard let session = sessions.removeValue(forKey: deviceUID) else { continue }
            AudioLog.shared.event(.route, "\(session.deviceName): no taps left, stopping session")
            session.teardown()
        }
    }

    private func makeSession(deviceUID: String, taps deviceTaps: [AppTap]) -> DeviceMixSession? {
        let name = deviceName(forUID: deviceUID)
        guard let session = DeviceMixSession(deviceUID: deviceUID, deviceName: name) else {
            AudioLog.shared.warning(.aggregate, "\(name): could not allocate mix state")
            return nil
        }
        session.onNeedsRestart = { [weak session] in
            session?.rebuild()
        }
        do {
            try session.start(taps: deviceTaps)
            if let currentEqualizerConfig {
                session.applyEqualizer(currentEqualizerConfig)
            }
            return session
        } catch {
            AudioLog.shared.warning(
                .aggregate,
                "\(name): session not started: \(error.localizedDescription)"
            )
            session.teardown()
            return nil
        }
    }

    /// Tap an app once it actually produces audio, or when the user has already
    /// expressed a preference for it. Everything else is left alone so we do not mute
    /// and re-route the whole system.
    private func shouldTap(app: AudioApp, state: AppMixerState) -> Bool {
        app.isRunningOutput || state != .default
    }

    private func isInCooldown(_ deviceUID: String) -> Bool {
        guard let failedAt = deviceFailures[deviceUID] else { return false }
        if Date().timeIntervalSince(failedAt) >= Self.deviceFailureCooldown {
            deviceFailures.removeValue(forKey: deviceUID)
            return false
        }
        return true
    }

    private func retireTap(for key: String) {
        guard let tap = taps.removeValue(forKey: key) else { return }
        // Drop the slot from every device map before destroying the tap, so no IOProc
        // can still be pointing at it.
        for session in sessions.values where session.taps.contains(where: { $0 === tap }) {
            session.setTaps(session.taps.filter { $0 !== tap })
        }
        tap.teardown()
    }

    private func resolvedDeviceUID(_ preferred: String?, fallback: String) -> String {
        guard let preferred else { return fallback }
        if (try? CoreAudioHelper.deviceID(forUID: preferred)) != nil {
            return preferred
        }
        return fallback
    }

    private func deviceName(forUID uid: String) -> String {
        guard
            let deviceID = try? CoreAudioHelper.deviceID(forUID: uid),
            let name = try? CoreAudioHelper.getStringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName
            )
        else {
            return uid
        }
        return name
    }

    // MARK: - System listeners

    private func startListeningIfNeeded() {
        guard !isListening else { return }
        isListening = true

        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.onDevicesChange?()
            }
        }
        deviceListener = deviceBlock

        let processBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.onProcessesChange?()
            }
        }
        processListener = processBlock

        try? CoreAudioHelper.addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            block: deviceBlock
        )
        try? CoreAudioHelper.addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            block: deviceBlock
        )
        try? CoreAudioHelper.addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            block: processBlock
        )
    }

    private func stopListening() {
        guard isListening else { return }
        if let deviceListener {
            CoreAudioHelper.removeListener(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                block: deviceListener
            )
            CoreAudioHelper.removeListener(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                block: deviceListener
            )
        }
        if let processListener {
            CoreAudioHelper.removeListener(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyProcessObjectList,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                block: processListener
            )
        }
        deviceListener = nil
        processListener = nil
        isListening = false
    }
}
