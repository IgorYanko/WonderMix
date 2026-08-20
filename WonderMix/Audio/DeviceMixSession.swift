import CoreAudio
import Darwin
import Foundation

struct TapSlotInfo {
    let appName: String
    let bufferIndex: UInt32
    let channelOffset: UInt32
    let channelCount: UInt32
}

struct DeviceMixTopology {
    let deviceName: String
    let deviceUID: String
    let aggregateID: AudioObjectID
    let sampleRate: Double
    let bufferFrameSize: UInt32
    let deviceSampleRate: Double
    let inputChannelTotal: UInt32
    let outputChannelTotal: UInt32
    let slots: [TapSlotInfo]
    let mapNote: String?
    let stats: RTDeviceMixSnapshot
}

/// Owns the single private aggregate device — and the single IOProc — for one physical
/// output device. Every app routed to that device contributes one sub-tap, and they are
/// all summed in one IO cycle.
///
/// The previous design created one aggregate per app, so two apps playing to the same
/// speakers meant two aggregates driving the same hardware with independent IO cycles
/// and independent resamplers, which is what produced the periodic dropouts.
final class DeviceMixSession {
    let deviceUID: String
    let deviceName: String

    private(set) var aggregateID: AudioObjectID = kAudioObjectUnknown
    private(set) var taps: [AppTap] = []
    private(set) var slots: [TapSlotInfo] = []
    private(set) var inputChannelTotal: UInt32 = 0
    private(set) var mapNote: String?

    /// Called when the HAL reports IO stopped abnormally and the session needs a restart.
    var onNeedsRestart: (() -> Void)?

    private let mix: OpaquePointer
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var isRunning = false
    private var mapRetryTask: Task<Void, Never>?
    private var mapRebuildAttempts = 0

    /// How long to keep waiting for the HAL to expose the streams of a newly added tap
    /// before giving up on the live update and rebuilding the aggregate.
    private static let mapRetryDelaysNs: [UInt64] = [40_000_000, 120_000_000]
    private static let maxMapRebuildAttempts = 2

    init?(deviceUID: String, deviceName: String) {
        guard let mix = RTMixer_DeviceMixCreate() else { return nil }
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.mix = mix
    }

    deinit {
        teardown()
        RTMixer_DeviceMixDestroy(mix)
    }

    // MARK: - Lifecycle

    func start(taps: [AppTap]) throws {
        self.taps = taps
        try buildAggregate()
    }

    func teardown() {
        mapRetryTask?.cancel()
        mapRetryTask = nil
        RTMixer_DeviceMixSetEnabled(mix, false)
        RTMixer_DeviceMixPublishSlots(mix, nil, 0, 0)
        removeListeners()

        if let ioProcID, aggregateID != kAudioObjectUnknown {
            if isRunning {
                AudioDeviceStop(aggregateID, ioProcID)
                isRunning = false
            }
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status == noErr {
                AudioLog.shared.event(.aggregate, "\(deviceName): aggregate destroyed")
            } else {
                AudioLog.shared.failure(
                    .aggregate,
                    "\(deviceName): AudioHardwareDestroyAggregateDevice",
                    status
                )
            }
            aggregateID = kAudioObjectUnknown
        }
        slots = []
        inputChannelTotal = 0
    }

    /// Swaps the set of taps feeding this device without destroying the aggregate.
    func setTaps(_ newTaps: [AppTap]) {
        let previousUIDs = taps.map(\.tapUID)
        let newUIDs = newTaps.map(\.tapUID)
        taps = newTaps

        guard previousUIDs != newUIDs else {
            refreshChannelMap()
            return
        }
        guard aggregateID != kAudioObjectUnknown else { return }

        let added = Set(newUIDs).subtracting(previousUIDs).count
        let removed = Set(previousUIDs).subtracting(newUIDs).count

        do {
            try CoreAudioHelper.setObjectProperty(
                objectID: aggregateID,
                selector: kAudioAggregateDevicePropertyTapList,
                value: newUIDs as CFArray
            )
            applySubTapDriftCompensation()
            AudioLog.shared.event(
                .aggregate,
                "\(deviceName): tap list updated live (+\(added)/-\(removed), now \(newUIDs.count))"
            )
            refreshChannelMap()
        } catch {
            AudioLog.shared.warning(
                .aggregate,
                "\(deviceName): live tap list update rejected (\(error.localizedDescription)); rebuilding aggregate"
            )
            rebuild()
        }
    }

    func rebuild() {
        teardown()
        do {
            try buildAggregate()
        } catch {
            AudioLog.shared.warning(
                .aggregate,
                "\(deviceName): rebuild failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Diagnostics

    func snapshot() -> RTDeviceMixSnapshot {
        var snapshot = RTDeviceMixSnapshot()
        RTMixer_DeviceMixSnapshot(mix, &snapshot)
        return snapshot
    }

    func resetStats() {
        RTMixer_DeviceMixResetStats(mix)
    }

    func topology() -> DeviceMixTopology {
        let physicalID = (try? CoreAudioHelper.deviceID(forUID: deviceUID)) ?? kAudioObjectUnknown
        return DeviceMixTopology(
            deviceName: deviceName,
            deviceUID: deviceUID,
            aggregateID: aggregateID,
            sampleRate: aggregateID == kAudioObjectUnknown
                ? 0
                : CoreAudioHelper.sampleRate(objectID: aggregateID),
            bufferFrameSize: aggregateID == kAudioObjectUnknown
                ? 0
                : CoreAudioHelper.bufferFrameSize(objectID: aggregateID),
            deviceSampleRate: physicalID == kAudioObjectUnknown
                ? 0
                : CoreAudioHelper.sampleRate(objectID: physicalID),
            inputChannelTotal: inputChannelTotal,
            outputChannelTotal: aggregateID == kAudioObjectUnknown
                ? 0
                : CoreAudioHelper.channelCount(
                    objectID: aggregateID,
                    scope: kAudioDevicePropertyScopeOutput
                ),
            slots: slots,
            mapNote: mapNote,
            stats: snapshot()
        )
    }

    // MARK: - Aggregate construction

    private func buildAggregate() throws {
        let aggregateUID = "com.wondermix.aggregate.\(UUID().uuidString)"
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WonderMix \(deviceName)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: deviceUID,
                    // The main sub-device is the aggregate's clock master. Drift
                    // compensating it against itself only inserts a resampler.
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: taps.map { tap in
                [
                    kAudioSubTapUIDKey: tap.tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            }
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioLog.shared.measure("CreateAggregateDevice") {
            AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID)
        }
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            AudioLog.shared.failure(
                .aggregate,
                "\(deviceName): AudioHardwareCreateAggregateDevice",
                status
            )
            throw CoreAudioError.status(status, "AudioHardwareCreateAggregateDevice")
        }
        aggregateID = newAggregateID

        applySubTapDriftCompensation()
        try installIOProc()
        installListeners()
        refreshChannelMap()
        try startDevice()

        let physicalID = (try? CoreAudioHelper.deviceID(forUID: deviceUID)) ?? kAudioObjectUnknown
        AudioLog.shared.event(
            .aggregate,
            """
            \(deviceName): aggregate ready with \(taps.count) tap(s) — \
            \(Int(CoreAudioHelper.sampleRate(objectID: aggregateID))) Hz / \
            \(CoreAudioHelper.bufferFrameSize(objectID: aggregateID)) frames, \
            device at \(Int(CoreAudioHelper.sampleRate(objectID: physicalID))) Hz
            """
        )
    }

    private func installIOProc() throws {
        var newProcID: AudioDeviceIOProcID?
        // The C IOProc keeps the real-time path free of ARC and Swift runtime calls.
        let status = AudioDeviceCreateIOProcID(
            aggregateID,
            RTMixer_DeviceIOProc,
            UnsafeMutableRawPointer(mix),
            &newProcID
        )
        guard status == noErr, let newProcID else {
            AudioLog.shared.failure(.aggregate, "\(deviceName): AudioDeviceCreateIOProcID", status)
            throw CoreAudioError.status(status, "AudioDeviceCreateIOProcID")
        }
        ioProcID = newProcID
    }

    private func startDevice() throws {
        guard let ioProcID else {
            throw CoreAudioError.missingProperty("ioProcID")
        }

        var status = AudioLog.shared.measure("AudioDeviceStart") {
            AudioDeviceStart(aggregateID, ioProcID)
        }
        var attempts = 0
        while status != noErr && attempts < 20 {
            usleep(20_000)
            status = AudioDeviceStart(aggregateID, ioProcID)
            attempts += 1
        }
        guard status == noErr else {
            AudioLog.shared.failure(.aggregate, "\(deviceName): AudioDeviceStart", status)
            throw CoreAudioError.status(status, "AudioDeviceStart")
        }
        if attempts > 0 {
            AudioLog.shared.detail(
                .aggregate,
                "\(deviceName): AudioDeviceStart succeeded after \(attempts) retries"
            )
        }
        isRunning = true
        RTMixer_DeviceMixSetEnabled(mix, true)
    }

    /// A tap list written through the property API does not inherit the drift settings
    /// from the original composition, so they are reapplied to each sub-tap object.
    private func applySubTapDriftCompensation() {
        guard aggregateID != kAudioObjectUnknown else { return }
        let subTapIDs: [AudioObjectID]
        do {
            subTapIDs = try CoreAudioHelper.getPropertyArray(
                objectID: aggregateID,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioAggregateDevicePropertySubTapList,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
        } catch {
            return
        }

        for subTapID in subTapIDs {
            try? CoreAudioHelper.setPropertyData(
                objectID: subTapID,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioSubTapPropertyDriftCompensation,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                value: UInt32(1)
            )
        }
    }

    // MARK: - Channel map

    /// Maps each tap to its channels inside the aggregate's input buffer list.
    ///
    /// Sub-tap objects expose no UID, so the order has to come from the tap list we
    /// control. The total channel count is used as a checksum: if it does not add up,
    /// no map is published and the IOProc stays silent rather than reading the wrong
    /// channels.
    private func refreshChannelMap(allowRetry: Bool = true) {
        guard aggregateID != kAudioObjectUnknown else { return }

        let bufferChannels: [UInt32]
        do {
            bufferChannels = try CoreAudioHelper.streamConfiguration(
                objectID: aggregateID,
                scope: kAudioDevicePropertyScopeInput
            )
        } catch {
            publish(slots: [], expectedInputChannels: 0)
            mapNote = "input stream configuration unavailable"
            return
        }

        let totalInput = bufferChannels.reduce(0, +)
        inputChannelTotal = totalInput
        let tapChannels = taps.reduce(UInt32(0)) { $0 + $1.channelCount }

        guard !taps.isEmpty else {
            publish(slots: [], expectedInputChannels: totalInput)
            slots = []
            mapNote = nil
            mapRetryTask?.cancel()
            return
        }

        let deviceInputChannels: UInt32
        if let physicalID = try? CoreAudioHelper.deviceID(forUID: deviceUID) {
            deviceInputChannels = CoreAudioHelper.channelCount(
                objectID: physicalID,
                scope: kAudioDevicePropertyScopeInput
            )
        } else {
            deviceInputChannels = 0
        }

        let baseOffset: UInt32
        if totalInput == tapChannels {
            baseOffset = 0
        } else if totalInput == tapChannels + deviceInputChannels {
            baseOffset = deviceInputChannels
        } else {
            publish(slots: [], expectedInputChannels: totalInput)
            slots = []
            mapNote =
                "channel checksum failed: \(totalInput) input ch, taps want \(tapChannels), device has \(deviceInputChannels) in"
            AudioLog.shared.warning(.io, "\(deviceName): \(mapNote ?? "")")
            if allowRetry {
                scheduleMapRecovery()
            }
            return
        }

        var resolvedSlots: [RTTapSlot] = []
        var info: [TapSlotInfo] = []
        var globalChannel = baseOffset

        for tap in taps {
            guard let position = Self.resolve(
                globalChannel: globalChannel,
                in: bufferChannels
            ) else {
                break
            }
            let available = bufferChannels[Int(position.bufferIndex)] - position.channelOffset
            let channelCount = min(tap.channelCount, available)
            guard channelCount > 0 else { break }

            resolvedSlots.append(
                RTTapSlot(
                    bufferIndex: position.bufferIndex,
                    channelOffset: position.channelOffset,
                    channelCount: channelCount,
                    channel: tap.mixerChannel
                )
            )
            info.append(
                TapSlotInfo(
                    appName: tap.name,
                    bufferIndex: position.bufferIndex,
                    channelOffset: position.channelOffset,
                    channelCount: channelCount
                )
            )
            globalChannel += tap.channelCount
        }

        slots = info
        let complete = info.count == taps.count
        mapNote = complete ? nil : "only \(info.count) of \(taps.count) taps could be mapped"

        RTMixer_DeviceMixSetSampleRate(mix, CoreAudioHelper.sampleRate(objectID: aggregateID))
        publish(slots: resolvedSlots, expectedInputChannels: totalInput)

        let layout = info
            .map { "\($0.appName)@b\($0.bufferIndex)+\($0.channelOffset)x\($0.channelCount)" }
            .joined(separator: ", ")

        if complete {
            mapRetryTask?.cancel()
            mapRebuildAttempts = 0
            AudioLog.shared.event(
                .io,
                "\(deviceName): channel map resolved — \(layout) of \(totalInput) input ch"
            )
        } else {
            AudioLog.shared.warning(.io, "\(deviceName): \(mapNote ?? "") — \(layout)")
            if allowRetry {
                scheduleMapRecovery()
            }
        }
    }

    /// A tap added through the live tap list does not always get its input streams before
    /// we read the configuration back. Retry briefly, and if the HAL still does not
    /// expose them, rebuild the aggregate with the full tap list in its composition —
    /// which is the path we know produces one input stream per tap.
    private func scheduleMapRecovery() {
        mapRetryTask?.cancel()
        mapRetryTask = Task { @MainActor [weak self] in
            for delay in Self.mapRetryDelaysNs {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.refreshChannelMap(allowRetry: false)
                if self.mapNote == nil { return }
            }

            guard !Task.isCancelled, let self else { return }
            guard self.mapRebuildAttempts < Self.maxMapRebuildAttempts else {
                AudioLog.shared.warning(
                    .aggregate,
                    "\(self.deviceName): channel map still unusable after \(self.mapRebuildAttempts) rebuild(s); giving up"
                )
                return
            }
            self.mapRebuildAttempts += 1
            AudioLog.shared.event(
                .aggregate,
                "\(self.deviceName): live tap list did not expose the new streams, rebuilding aggregate"
            )
            self.rebuild()
        }
    }

    private func publish(slots: [RTTapSlot], expectedInputChannels: UInt32) {
        if slots.isEmpty {
            RTMixer_DeviceMixPublishSlots(mix, nil, 0, expectedInputChannels)
        } else {
            slots.withUnsafeBufferPointer { buffer in
                RTMixer_DeviceMixPublishSlots(
                    mix,
                    buffer.baseAddress,
                    UInt32(buffer.count),
                    expectedInputChannels
                )
            }
        }
    }

    private static func resolve(
        globalChannel: UInt32,
        in bufferChannels: [UInt32]
    ) -> (bufferIndex: UInt32, channelOffset: UInt32)? {
        var remaining = globalChannel
        for (index, channels) in bufferChannels.enumerated() {
            if remaining < channels {
                return (UInt32(index), remaining)
            }
            remaining -= channels
        }
        return nil
    }

    // MARK: - Health listeners

    private func installListeners() {
        guard aggregateID != kAudioObjectUnknown else { return }

        // Both overload and IO-stopped are signalled from the IO context: bump the
        // atomic counter here and do the reporting from the diagnostics poller.
        let overloadAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let mixPointer = mix
        let overloadBlock: AudioObjectPropertyListenerBlock = { _, _ in
            RTMixer_DeviceMixNoteOverload(mixPointer)
        }
        addListener(overloadAddress, overloadBlock)

        let stoppedAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOStoppedAbnormally,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let stoppedBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            RTMixer_DeviceMixNoteIOStopped(mixPointer)
            Task { @MainActor in
                guard let self else { return }
                AudioLog.shared.warning(
                    .aggregate,
                    "\(self.deviceName): IO stopped abnormally, restarting"
                )
                self.onNeedsRestart?()
            }
        }
        addListener(stoppedAddress, stoppedBlock)

        let layoutAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let layoutBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshChannelMap()
            }
        }
        addListener(layoutAddress, layoutBlock)
    }

    private func addListener(
        _ address: AudioObjectPropertyAddress,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) {
        do {
            try CoreAudioHelper.addListener(objectID: aggregateID, address: address, block: block)
            listeners.append((address, block))
        } catch {
            AudioLog.shared.detail(
                .aggregate,
                "\(deviceName): could not observe \(AudioLog.describe(selector: address.mSelector))"
            )
        }
    }

    private func removeListeners() {
        guard aggregateID != kAudioObjectUnknown else {
            listeners.removeAll()
            return
        }
        for (address, block) in listeners {
            CoreAudioHelper.removeListener(
                objectID: aggregateID,
                address: address,
                block: block
            )
        }
        listeners.removeAll()
    }
}
