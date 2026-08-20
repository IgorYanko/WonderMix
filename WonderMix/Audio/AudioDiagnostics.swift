import Foundation

struct DeviceDiagnostics: Identifiable {
    var id: String { topology.deviceUID }
    let topology: DeviceMixTopology

    var dropoutsPerSecond: Double
    var overloadsPerSecond: Double
    var silentCyclesPerSecond: Double

    var isHealthy: Bool {
        topology.stats.dropoutCount == 0
            && topology.stats.overloadCount == 0
            && topology.stats.silentCycles == 0
            && topology.mapNote == nil
    }

    var loadPercent: Double {
        let cycleNanos = topology.sampleRate > 0 && topology.bufferFrameSize > 0
            ? Double(topology.bufferFrameSize) / topology.sampleRate * 1.0e9
            : 0
        guard cycleNanos > 0 else { return 0 }
        return Double(topology.stats.maxProcessNanos) / cycleNanos * 100
    }
}

/// Polls the real-time counters and turns them into something the UI and the log can
/// show. The IO thread only ever increments atomics; all interpretation happens here.
@MainActor
final class AudioDiagnostics: ObservableObject {
    @Published private(set) var devices: [DeviceDiagnostics] = []
    @Published private(set) var events: [AudioLogEvent] = []

    private struct Baseline {
        var dropouts: UInt64
        var overloads: UInt64
        var silentCycles: UInt64
        var ioStopped: UInt64
        var clipCycles: UInt64
        var timestamp: Date
    }

    private var baselines: [String: Baseline] = [:]
    private var lastNotes: [String: String] = [:]

    func update(sessions: [DeviceMixSession]) {
        let now = Date()
        var next: [DeviceDiagnostics] = []
        var liveKeys: Set<String> = []

        for session in sessions {
            let topology = session.topology()
            let stats = topology.stats
            liveKeys.insert(topology.deviceUID)

            let previous = baselines[topology.deviceUID]
            let elapsed = previous.map { max(now.timeIntervalSince($0.timestamp), 0.001) } ?? 1

            let dropoutDelta = delta(stats.dropoutCount, previous?.dropouts)
            let overloadDelta = delta(stats.overloadCount, previous?.overloads)
            let silentDelta = delta(stats.silentCycles, previous?.silentCycles)
            let stoppedDelta = delta(stats.ioStoppedCount, previous?.ioStopped)
            let clipDelta = delta(stats.clipCycles, previous?.clipCycles)

            reportIfChanged(
                topology: topology,
                dropouts: dropoutDelta,
                overloads: overloadDelta,
                silent: silentDelta,
                stopped: stoppedDelta,
                clipped: clipDelta
            )

            baselines[topology.deviceUID] = Baseline(
                dropouts: stats.dropoutCount,
                overloads: stats.overloadCount,
                silentCycles: stats.silentCycles,
                ioStopped: stats.ioStoppedCount,
                clipCycles: stats.clipCycles,
                timestamp: now
            )

            next.append(
                DeviceDiagnostics(
                    topology: topology,
                    dropoutsPerSecond: Double(dropoutDelta) / elapsed,
                    overloadsPerSecond: Double(overloadDelta) / elapsed,
                    silentCyclesPerSecond: Double(silentDelta) / elapsed
                )
            )
        }

        baselines = baselines.filter { liveKeys.contains($0.key) }
        lastNotes = lastNotes.filter { liveKeys.contains($0.key) }
        devices = next
        events = AudioLog.shared.recentEvents().reversed()
    }

    func reset(sessions: [DeviceMixSession]) {
        for session in sessions {
            session.resetStats()
        }
        baselines.removeAll()
        AudioLog.shared.event(.io, "diagnostics counters reset")
        update(sessions: sessions)
    }

    /// A plain-text dump to paste into a bug report.
    func report() -> String {
        var lines: [String] = []
        lines.append("WonderMix diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        if devices.isEmpty {
            lines.append("No active output sessions.")
        }

        for device in devices {
            let topology = device.topology
            let stats = topology.stats
            lines.append("Device: \(topology.deviceName)")
            lines.append("  uid: \(topology.deviceUID)")
            lines.append("  aggregate: \(topology.aggregateID)")
            lines.append(
                "  aggregate rate/buffer: \(Int(topology.sampleRate)) Hz / \(topology.bufferFrameSize) frames"
            )
            lines.append("  device rate: \(Int(topology.deviceSampleRate)) Hz")
            lines.append(
                "  channels: \(topology.inputChannelTotal) in / \(topology.outputChannelTotal) out"
            )
            lines.append("  enabled: \(stats.enabled), slots: \(stats.publishedSlotCount)")
            if let note = topology.mapNote {
                lines.append("  map note: \(note)")
            }
            for slot in topology.slots {
                lines.append(
                    "  tap \(slot.appName): buffer \(slot.bufferIndex), ch \(slot.channelOffset)…\(slot.channelOffset + slot.channelCount - 1)"
                )
            }
            lines.append("  io cycles: \(stats.ioCycles), frames: \(stats.lastFrameCount)")
            lines.append(
                "  dropouts: \(stats.dropoutCount) (max gap \(Self.millis(stats.maxGapNanos)) ms)"
            )
            lines.append("  overloads: \(stats.overloadCount), io stopped: \(stats.ioStoppedCount)")
            lines.append(
                "  silent cycles: \(stats.silentCycles), empty input: \(stats.emptyInputCycles), clipped: \(stats.clipCycles)"
            )
            lines.append(
                "  process time last/max: \(Self.millis(stats.lastProcessNanos))/\(Self.millis(stats.maxProcessNanos)) ms (\(String(format: "%.1f", device.loadPercent))% of cycle)"
            )
            lines.append("")
        }

        lines.append("Recent events:")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        for event in events {
            lines.append(
                "  \(formatter.string(from: event.date)) [\(event.category.rawValue)] \(event.message)"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func millis(_ nanos: UInt64) -> String {
        String(format: "%.2f", Double(nanos) / 1_000_000)
    }

    private func delta(_ current: UInt64, _ previous: UInt64?) -> UInt64 {
        guard let previous, current >= previous else { return 0 }
        return current - previous
    }

    /// Keeps the log quiet while everything is fine and noisy exactly when it is not.
    private func reportIfChanged(
        topology: DeviceMixTopology,
        dropouts: UInt64,
        overloads: UInt64,
        silent: UInt64,
        stopped: UInt64,
        clipped: UInt64
    ) {
        var problems: [String] = []
        if dropouts > 0 {
            problems.append(
                "\(dropouts) dropout(s), max gap \(Self.millis(topology.stats.maxGapNanos)) ms"
            )
        }
        if overloads > 0 { problems.append("\(overloads) overload(s)") }
        if silent > 0 { problems.append("\(silent) silent cycle(s) from channel map mismatch") }
        if stopped > 0 { problems.append("\(stopped) abnormal IO stop(s)") }
        if clipped > 0 { problems.append("\(clipped) clipped cycle(s)") }

        guard !problems.isEmpty else {
            lastNotes[topology.deviceUID] = nil
            return
        }

        let summary = problems.joined(separator: ", ")
        guard lastNotes[topology.deviceUID] != summary else { return }
        lastNotes[topology.deviceUID] = summary
        AudioLog.shared.warning(.io, "\(topology.deviceName): \(summary)")
    }
}
