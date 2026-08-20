import AppKit
import CoreAudio
import Darwin
import Foundation

struct AudioApp: Identifiable, Hashable {
    /// Stable UI key — prefers bundle ID, falls back to process object ID.
    var id: String { key }
    let key: String
    /// Every Core Audio process object belonging to this app, including the ones not
    /// currently producing audio. A tap must cover them all, otherwise a helper that
    /// starts playing later escapes the tap and keeps going to the default device.
    let processObjectIDs: [AudioObjectID]
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let isRunningOutput: Bool

    var processObjectID: AudioObjectID { processObjectIDs[0] }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.key == rhs.key
            && lhs.processObjectIDs == rhs.processObjectIDs
            && lhs.isRunningOutput == rhs.isRunningOutput
            && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

@MainActor
enum ProcessEnumerator {
    private struct OwnerInfo {
        let key: String
        let ownerPID: pid_t
        let name: String
        let bundleIdentifier: String?
        let icon: NSImage?
    }

    /// Resolving the owning application walks the process tree and hits AppKit, which is
    /// far too slow to redo for every process object on every 3 s refresh.
    private static var ownerCache: [pid_t: OwnerInfo] = [:]

    static func listApps() -> [AudioApp] {
        let processIDs: [AudioObjectID]
        do {
            processIDs = try CoreAudioHelper.getPropertyArray(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyProcessObjectList,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
        } catch {
            AudioLog.shared.warning(
                .enumerator,
                "could not read process object list: \(error.localizedDescription)"
            )
            return []
        }

        struct MutableApp {
            var processObjectIDs: [AudioObjectID] = []
            var pid: pid_t = 0
            var name: String = ""
            var bundleIdentifier: String?
            var icon: NSImage?
            var isRunningOutput = false
        }

        var grouped: [String: MutableApp] = [:]
        var seenPIDs: Set<pid_t> = []

        for processObjectID in processIDs where processObjectID != kAudioObjectUnknown {
            guard let pid = processPID(of: processObjectID), pid != getpid() else { continue }
            seenPIDs.insert(pid)

            let isRunningOutput = processIsRunningOutput(processObjectID)
            let owner = ownerInfo(for: pid)

            var entry = grouped[owner.key] ?? MutableApp(
                processObjectIDs: [],
                pid: owner.ownerPID,
                name: owner.name,
                bundleIdentifier: owner.bundleIdentifier,
                icon: owner.icon,
                isRunningOutput: false
            )
            if !entry.processObjectIDs.contains(processObjectID) {
                entry.processObjectIDs.append(processObjectID)
            }
            entry.isRunningOutput = entry.isRunningOutput || isRunningOutput
            grouped[owner.key] = entry
        }

        ownerCache = ownerCache.filter { seenPIDs.contains($0.key) }

        return grouped.compactMap { key, value -> AudioApp? in
            guard !value.processObjectIDs.isEmpty else { return nil }
            return AudioApp(
                key: key,
                processObjectIDs: value.processObjectIDs.sorted(),
                pid: value.pid,
                name: value.name,
                bundleIdentifier: value.bundleIdentifier,
                icon: value.icon,
                isRunningOutput: value.isRunningOutput
            )
        }
        .sorted {
            if $0.isRunningOutput != $1.isRunningOutput {
                return $0.isRunningOutput && !$1.isRunningOutput
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func processPID(of processObjectID: AudioObjectID) -> pid_t? {
        try? CoreAudioHelper.getPropertyData(
            objectID: processObjectID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            defaultValue: pid_t(0)
        )
    }

    private static func processIsRunningOutput(_ processObjectID: AudioObjectID) -> Bool {
        let value: UInt32? = try? CoreAudioHelper.getPropertyData(
            objectID: processObjectID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            defaultValue: 0
        )
        return (value ?? 0) != 0
    }

    private static func ownerInfo(for pid: pid_t) -> OwnerInfo {
        if let cached = ownerCache[pid] {
            return cached
        }

        let info: OwnerInfo
        if let owner = owningApplication(for: pid) {
            info = OwnerInfo(
                key: owner.app.bundleIdentifier ?? "pid:\(owner.pid)",
                ownerPID: owner.pid,
                name: owner.app.localizedName ?? bundleName(for: owner.app) ?? "Process \(owner.pid)",
                bundleIdentifier: owner.app.bundleIdentifier,
                icon: owner.app.icon
            )
        } else {
            info = OwnerInfo(
                key: "pid:\(pid)",
                ownerPID: pid,
                name: "Process \(pid)",
                bundleIdentifier: nil,
                icon: nil
            )
        }

        ownerCache[pid] = info
        return info
    }

    /// Walks up the process tree to find the app the user actually sees.
    ///
    /// Audio-producing helpers are their own bundles — an Electron renderer registers as
    /// "Discord Helper (Renderer)" with its own bundle identifier — so stopping at the
    /// first bundle is not enough. Only a `.regular` activation policy means a real
    /// user-facing app; helpers are background-only. Without this the helper shows up as
    /// its own row and keeps playing to the default device while the user believes they
    /// moved the app.
    private static func owningApplication(for pid: pid_t) -> (pid: pid_t, app: NSRunningApplication)? {
        var candidate = pid
        var hops = 0
        var fallback: (pid: pid_t, app: NSRunningApplication)?

        while candidate > 1 && hops < 8 {
            if let app = NSRunningApplication(processIdentifier: candidate),
               app.bundleIdentifier != nil {
                if app.activationPolicy == .regular {
                    return (candidate, app)
                }
                if fallback == nil {
                    fallback = (candidate, app)
                }
            }
            guard let parent = parentPID(of: candidate) else { break }
            candidate = parent
            hops += 1
        }
        return fallback
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }

        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    private static func bundleName(for app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}
