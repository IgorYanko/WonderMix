import AppKit
import Darwin
import Foundation

/// System audio capture permission (`kTCCServiceAudioCapture`).
/// There is no public Apple API — same approach as Apple's sample consumers (AudioCap).
enum AudioCapturePermission {
    enum Status: Equatable {
        case unknown
        case denied
        case authorized

        var isGranted: Bool { self == .authorized }
    }

    static func currentStatus() -> Status {
        guard let preflight = preflightSPI else {
            // Without SPI, assume unknown and let the first tap trigger the prompt.
            return .unknown
        }
        let result = preflight("kTCCServiceAudioCapture" as CFString, nil)
        switch result {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system permission dialog for system-audio capture.
    static func request(completion: @escaping (Status) -> Void) {
        guard let request = requestSPI else {
            // Fallback: open Settings so the user can grant manually.
            openSystemSettings()
            DispatchQueue.main.async {
                completion(currentStatus())
            }
            return
        }

        request("kTCCServiceAudioCapture" as CFString, nil) { granted in
            DispatchQueue.main.async {
                completion(granted ? .authorized : .denied)
            }
        }
    }

    static func openSystemSettings() {
        // Prefer the modern Privacy pane; fall back to legacy URLs.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ]

        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - TCC private SPI (dlopen)

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? = {
        dlopen(
            "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC",
            RTLD_NOW
        )
    }()

    private static let preflightSPI: PreflightFunc? = {
        guard let apiHandle,
              let symbol = dlsym(apiHandle, "TCCAccessPreflight")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: PreflightFunc.self)
    }()

    private static let requestSPI: RequestFunc? = {
        guard let apiHandle,
              let symbol = dlsym(apiHandle, "TCCAccessRequest")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: RequestFunc.self)
    }()
}
