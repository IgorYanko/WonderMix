import AppKit
import SwiftUI

struct LevelMeterView: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            let width = max(0, min(1, CGFloat(level))) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(meterColor)
                    .frame(width: max(width, level > 0.001 ? 2 : 0))
            }
        }
        .frame(height: 4)
    }

    private var meterColor: Color {
        if level > 0.85 { return .red.opacity(0.85) }
        if level > 0.6 { return .orange.opacity(0.85) }
        return Color.accentColor.opacity(0.85)
    }
}

struct AppRowView: View {
    let app: AudioApp
    let state: AppMixerState
    let devices: [OutputDevice]
    let selectedDeviceUID: String
    let peak: Float
    let onVolume: (Float) -> Void
    let onMute: () -> Void
    let onDevice: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !app.isRunningOutput {
                        Text("Inativo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button(action: onMute) {
                    Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.isMuted ? Color.red.opacity(0.9) : Color.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(state.isMuted ? "Ativar som" : "Mudo")
            }

            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { Double(state.volume) },
                        set: { onVolume(Float($0)) }
                    ),
                    in: 0...1.5
                )
                .disabled(state.isMuted)
                .opacity(state.isMuted ? 0.45 : 1)

                Text(volumeLabel)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            LevelMeterView(level: state.isMuted ? 0 : peak)

            Picker(
                "Saída",
                selection: Binding(
                    get: { selectedDeviceUID },
                    set: { newValue in
                        let defaultUID = devices.first(where: \.isDefault)?.uid
                        if newValue == defaultUID {
                            onDevice(nil)
                        } else {
                            onDevice(newValue)
                        }
                    }
                )
            ) {
                ForEach(devices) { device in
                    Text(device.isDefault ? "\(device.name) (Padrão)" : device.name)
                        .tag(device.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private var volumeLabel: String {
        "\(Int((state.volume * 100).rounded()))%"
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .cornerRadius(6)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "app.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

struct MixerPopoverView: View {
    @EnvironmentObject private var controller: MixerController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 360)
        .frame(maxHeight: 520)
        .onAppear {
            controller.refreshPermissionStatus(andRebuildIfGranted: true)
        }
    }

    private var header: some View {
        HStack {
            Text("WonderMix")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            Text("\(controller.apps.filter(\.isRunningOutput).count) ativos")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if !controller.hasPermission {
            PermissionView(
                status: controller.permissionStatus,
                isRequesting: controller.isRequestingPermission,
                onAllow: { controller.requestPermission() },
                onRecheck: { controller.refreshPermissionStatus(andRebuildIfGranted: true) }
            )
            .padding(14)
        } else if controller.apps.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "speaker.slash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Nenhum app reproduzindo áudio")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.apps) { app in
                        AppRowView(
                            app: app,
                            state: controller.state(for: app),
                            devices: controller.devices,
                            selectedDeviceUID: controller.selectedDeviceUID(for: app),
                            peak: controller.peaks[app.key] ?? 0,
                            onVolume: { controller.setVolume($0, for: app) },
                            onMute: { controller.toggleMute(for: app) },
                            onDevice: { controller.setOutputDevice(uid: $0, for: app) }
                        )
                        if app.key != controller.apps.last?.key {
                            Divider().padding(.leading, 38)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Configurações", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Sair") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
