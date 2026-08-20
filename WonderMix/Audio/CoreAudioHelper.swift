import CoreAudio
import Foundation

enum CoreAudioError: Error, LocalizedError {
    case status(OSStatus, String)
    case missingProperty(String)
    case invalidDevice

    var errorDescription: String? {
        switch self {
        case .status(let status, let context):
            return "Core Audio error \(AudioLog.describe(status)) while \(context)"
        case .missingProperty(let name):
            return "Missing audio property: \(name)"
        case .invalidDevice:
            return "Invalid audio device"
        }
    }
}

enum CoreAudioHelper {
    static func getPropertyData<T>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        defaultValue: T
    ) throws -> T {
        var address = address
        var dataSize = UInt32(MemoryLayout<T>.size)
        var data = defaultValue
        let status = withUnsafeMutablePointer(to: &data) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else {
            throw CoreAudioError.status(status, "getPropertyData")
        }
        return data
    }

    static func setPropertyData<T>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        value: T
    ) throws {
        var address = address
        var value = value
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<T>.size),
                pointer
            )
        }
        guard status == noErr else {
            throw CoreAudioError.status(status, "setPropertyData")
        }
    }

    static func getPropertyArray<T>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [T] {
        var address = address
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw CoreAudioError.status(status, "getPropertyDataSize")
        }
        let count = Int(dataSize) / MemoryLayout<T>.size
        guard count > 0 else { return [] }

        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }

        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        guard status == noErr else {
            throw CoreAudioError.status(status, "getPropertyArray")
        }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    static func getStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        let value: CFString = try getObjectProperty(
            objectID: objectID,
            selector: selector,
            scope: scope
        )
        return value as String
    }

    /// Reads a property whose payload is a single retained object reference — used for
    /// `CATapDescription`, tap UIDs and the aggregate tap list.
    static func getObjectProperty<T: AnyObject>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        var raw: UnsafeMutableRawPointer?
        let status = withUnsafeMutablePointer(to: &raw) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else {
            throw CoreAudioError.status(status, "getObjectProperty \(AudioLog.describe(selector: selector))")
        }
        guard let raw else {
            throw CoreAudioError.missingProperty(AudioLog.describe(selector: selector))
        }
        return Unmanaged<T>.fromOpaque(raw).takeRetainedValue()
    }

    static func setObjectProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        value: AnyObject
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var pointer = Unmanaged.passUnretained(value).toOpaque()
        let status = withUnsafePointer(to: &pointer) { boxed in
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UnsafeRawPointer>.size),
                boxed
            )
        }
        guard status == noErr else {
            throw CoreAudioError.status(status, "setObjectProperty \(AudioLog.describe(selector: selector))")
        }
    }

    /// Channel count of each buffer the HAL will hand us, in buffer order.
    static func streamConfiguration(
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else {
            throw CoreAudioError.status(status, "streamConfiguration size")
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, raw)
        guard status == noErr else {
            throw CoreAudioError.status(status, "streamConfiguration")
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.map(\.mNumberChannels)
    }

    static func channelCount(objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
        guard let config = try? streamConfiguration(objectID: objectID, scope: scope) else {
            return 0
        }
        return config.reduce(0, +)
    }

    static func sampleRate(objectID: AudioObjectID) -> Double {
        (try? getPropertyData(
            objectID: objectID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            defaultValue: Double(0)
        )) ?? 0
    }

    static func bufferFrameSize(objectID: AudioObjectID) -> UInt32 {
        (try? getPropertyData(
            objectID: objectID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            defaultValue: UInt32(0)
        )) ?? 0
    }

    static func addListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        block: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        var address = address
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, nil, block)
        guard status == noErr else {
            throw CoreAudioError.status(status, "addListener")
        }
    }

    static func removeListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = address
        _ = AudioObjectRemovePropertyListenerBlock(objectID, &address, nil, block)
    }

    static var defaultOutputDeviceID: AudioObjectID {
        get throws {
            try getPropertyData(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                defaultValue: AudioObjectID(kAudioObjectUnknown)
            )
        }
    }

    static func deviceUID(for deviceID: AudioObjectID) throws -> String {
        try getStringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func deviceID(forUID uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uidCF) { uidPointer in
            withUnsafeMutablePointer(to: &deviceID) { devicePointer in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    UInt32(MemoryLayout<CFString>.size),
                    uidPointer,
                    &size,
                    devicePointer
                )
            }
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw CoreAudioError.invalidDevice
        }
        return deviceID
    }
}
