import CoreAudio
import Foundation
import os

enum AudioLogCategory: String, CaseIterable {
    case tap
    case aggregate
    case route
    case enumerator
    case io
}

struct AudioLogEvent: Identifiable {
    let id: UInt64
    let date: Date
    let category: AudioLogCategory
    let message: String
}

/// Structured logging plus an in-memory event history used by the diagnostics panel.
///
/// Never call this from the HAL real-time thread — use the atomic counters in
/// `RTDeviceMix` instead.
final class AudioLog {
    static let shared = AudioLog()

    static let subsystem = "com.wondermix.audio"

    private static let historyLimit = 200

    private let loggers: [AudioLogCategory: Logger]
    private let signposter = OSSignposter(
        subsystem: AudioLog.subsystem,
        category: "intervals"
    )
    private let lock = NSLock()
    private var history: [AudioLogEvent] = []
    private var nextEventID: UInt64 = 0

    private init() {
        loggers = Dictionary(
            uniqueKeysWithValues: AudioLogCategory.allCases.map { category in
                (category, Logger(subsystem: AudioLog.subsystem, category: category.rawValue))
            }
        )
    }

    func logger(_ category: AudioLogCategory) -> Logger {
        loggers[category] ?? Logger(subsystem: AudioLog.subsystem, category: category.rawValue)
    }

    /// Records to both the unified log and the in-memory history shown in Settings.
    func event(_ category: AudioLogCategory, _ message: String) {
        logger(category).info("\(message, privacy: .public)")
        append(category: category, message: message)
    }

    func warning(_ category: AudioLogCategory, _ message: String) {
        logger(category).warning("\(message, privacy: .public)")
        append(category: category, message: message)
    }

    func failure(_ category: AudioLogCategory, _ context: String, _ status: OSStatus) {
        let message = "\(context) failed: \(AudioLog.describe(status))"
        logger(category).error("\(message, privacy: .public)")
        append(category: category, message: message)
    }

    /// Debug-level detail that stays out of the history to keep it readable.
    func detail(_ category: AudioLogCategory, _ message: String) {
        logger(category).debug("\(message, privacy: .public)")
    }

    func recentEvents() -> [AudioLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    private func append(category: AudioLogCategory, message: String) {
        lock.lock()
        defer { lock.unlock() }
        history.append(
            AudioLogEvent(id: nextEventID, date: Date(), category: category, message: message)
        )
        nextEventID += 1
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    /// Wraps HAL calls that block for tens of milliseconds so they show up in Instruments.
    func measure<T>(_ name: StaticString, _ body: () -> T) -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return body()
    }

    /// Core Audio reports errors as four-char codes; the raw integer is unreadable.
    static func describe(_ status: OSStatus) -> String {
        guard let code = fourCharCode(status) else {
            return "\(status)"
        }
        return "'\(code)' (\(status))"
    }

    static func fourCharCode(_ status: OSStatus) -> String? {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
        return String(decoding: bytes)
    }

    private static func fourCharCodeString(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            return "0x" + String(value, radix: 16)
        }
        return String(decoding: bytes)
    }

    static func describe(selector: AudioObjectPropertySelector) -> String {
        fourCharCodeString(selector)
    }
}

private extension String {
    init(decoding bytes: [UInt8]) {
        self = String(bytes.map { Character(UnicodeScalar($0)) })
    }
}
