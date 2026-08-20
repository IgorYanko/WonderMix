import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Hashable {
    var id: String { uid }
    let uid: String
    let objectID: AudioObjectID
    let name: String
    let isDefault: Bool
}

enum OutputDeviceEnumerator {
    static func listOutputDevices() -> [OutputDevice] {
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
            return []
        }

        let defaultID = (try? CoreAudioHelper.defaultOutputDeviceID) ?? kAudioObjectUnknown
        var devices: [OutputDevice] = []

        for deviceID in deviceIDs {
            guard hasOutputChannels(deviceID) else { continue }
            // Skip private aggregate devices we create.
            if let name = try? CoreAudioHelper.getStringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName
            ), name.hasPrefix("WonderMix") {
                continue
            }

            guard
                let uid = try? CoreAudioHelper.deviceUID(for: deviceID),
                let name = try? CoreAudioHelper.getStringProperty(
                    objectID: deviceID,
                    selector: kAudioObjectPropertyName
                )
            else {
                continue
            }

            devices.append(
                OutputDevice(
                    uid: uid,
                    objectID: deviceID,
                    name: name,
                    isDefault: deviceID == defaultID
                )
            )
        }

        return devices.sorted {
            if $0.isDefault != $1.isDefault {
                return $0.isDefault && !$1.isDefault
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func defaultOutputUID() -> String? {
        guard let defaultID = try? CoreAudioHelper.defaultOutputDeviceID else { return nil }
        return try? CoreAudioHelper.deviceUID(for: defaultID)
    }

    private static func hasOutputChannels(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else {
            return false
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else {
            return false
        }

        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channels = 0
        for buffer in buffers {
            channels += Int(buffer.mNumberChannels)
        }
        return channels > 0
    }
}
