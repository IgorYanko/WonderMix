import CoreAudio
import Foundation

/// One process tap per app, kept alive for the whole lifetime of the app it taps.
///
/// The tap is never destroyed just because the app's audio process objects changed —
/// its description is rewritten in place. Destroying and recreating it would drop the
/// `mutedWhenTapped` behaviour for a few milliseconds, which is audible both as a gap
/// and as the app leaking back onto the default output device.
final class AppTap {
    let key: String
    let name: String
    private(set) var processObjectIDs: [AudioObjectID]
    private(set) var tapID: AudioObjectID = kAudioObjectUnknown
    private(set) var tapUID: String = ""
    /// Channels this tap contributes to an aggregate's input buffer list.
    private(set) var channelCount: UInt32 = 2

    let mixerChannel: OpaquePointer

    /// Channels of retired taps are never freed while the app runs: an in-flight IO
    /// cycle may still hold a pointer to one from a slot map published moments ago.
    private static var retiredChannels: [OpaquePointer] = []

    init(key: String, name: String, processObjectIDs: [AudioObjectID], gain: Float) throws {
        guard let channel = RTMixerChannel_Create(gain) else {
            throw CoreAudioError.missingProperty("RTMixerChannel")
        }
        self.key = key
        self.name = name
        self.processObjectIDs = processObjectIDs
        self.mixerChannel = channel

        do {
            try createTap()
        } catch {
            RTMixerChannel_Destroy(channel)
            throw error
        }
    }

    func setGain(_ gain: Float) {
        RTMixerChannel_SetGain(mixerChannel, gain)
    }

    var peakLevel: Float {
        RTMixerChannel_GetPeak(mixerChannel)
    }

    /// Rewrites the tap's process list in place. `kAudioTapPropertyDescription` is
    /// documented as settable exactly for this.
    func updateProcesses(_ ids: [AudioObjectID]) {
        let incoming = ids.sorted()
        guard incoming != processObjectIDs.sorted() else { return }
        guard tapID != kAudioObjectUnknown else { return }

        do {
            let description: CATapDescription = try CoreAudioHelper.getObjectProperty(
                objectID: tapID,
                selector: kAudioTapPropertyDescription
            )
            description.processes = ids
            try CoreAudioHelper.setObjectProperty(
                objectID: tapID,
                selector: kAudioTapPropertyDescription,
                value: description
            )
            let added = Set(ids).subtracting(processObjectIDs).count
            let removed = Set(processObjectIDs).subtracting(ids).count
            processObjectIDs = ids
            AudioLog.shared.event(
                .tap,
                "\(name): process list updated in place (+\(added)/-\(removed), now \(ids.count))"
            )
        } catch {
            AudioLog.shared.warning(
                .tap,
                "\(name): failed to update process list in place: \(error.localizedDescription)"
            )
        }
    }

    func teardown() {
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status == noErr {
                AudioLog.shared.event(.tap, "\(name): tap destroyed")
            } else {
                AudioLog.shared.failure(.tap, "\(name): AudioHardwareDestroyProcessTap", status)
            }
            tapID = kAudioObjectUnknown
        }
        tapUID = ""
        Self.retiredChannels.append(mixerChannel)
    }

    /// Only safe once every aggregate has been stopped and destroyed.
    static func releaseRetiredChannels() {
        for channel in retiredChannels {
            RTMixerChannel_Destroy(channel)
        }
        retiredChannels.removeAll()
    }

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioLog.shared.measure("CreateProcessTap") {
            AudioHardwareCreateProcessTap(description, &newTapID)
        }
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            AudioLog.shared.failure(.tap, "\(name): AudioHardwareCreateProcessTap", status)
            throw CoreAudioError.status(status, "AudioHardwareCreateProcessTap")
        }
        tapID = newTapID

        // Always read back the UID Core Audio assigned rather than trusting the UUID.
        tapUID = try CoreAudioHelper.getStringProperty(
            objectID: newTapID,
            selector: kAudioTapPropertyUID
        )

        if let format = try? CoreAudioHelper.getPropertyData(
            objectID: newTapID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            defaultValue: AudioStreamBasicDescription()
        ), format.mChannelsPerFrame > 0 {
            channelCount = format.mChannelsPerFrame
        }

        AudioLog.shared.event(
            .tap,
            "\(name): tap created (\(processObjectIDs.count) procs, \(channelCount) ch)"
        )
    }
}
