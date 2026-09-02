import AppKit
import SwiftUI

struct LevelMeterView: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            let width = max(0, min(1, CGFloat(level))) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WonderMixTheme.fill)
                Capsule()
                    .fill(WonderMixTheme.ink.opacity(level > 0.85 ? 1 : 0.9))
                    .frame(width: max(width, level > 0.001 ? 2 : 0))
            }
        }
        .frame(height: 4)
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
                        .foregroundStyle(WonderMixTheme.ink)
                        .lineLimit(1)
                    if !app.isRunningOutput {
                        Text("Inativo")
                            .font(.caption2)
                            .foregroundStyle(WonderMixTheme.inkFaint)
                    }
                }
                Spacer(minLength: 8)
                Button(action: onMute) {
                    Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.isMuted ? WonderMixTheme.inkFaint : WonderMixTheme.ink)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(state.isMuted ? "Ativar som" : "Mudo")
            }

            HStack(spacing: 8) {
                WhiteVolumeSlider(
                    value: Binding(
                        get: { Double(state.volume) },
                        set: { onVolume(Float($0)) }
                    ),
                    isEnabled: !state.isMuted
                )
                .opacity(state.isMuted ? 0.45 : 1)

                Text(volumeLabel)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(WonderMixTheme.inkMuted)
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
            .tint(WonderMixTheme.ink)
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
                .fill(WonderMixTheme.fill)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "app.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(WonderMixTheme.inkMuted)
                }
        }
    }
}

enum MixerPopoverTab: String, CaseIterable, Identifiable {
    case mixer = "Mixer"
    case equalizer = "Equalizador"
    case settings = "Ajustes"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .mixer: return "slider.horizontal.3"
        case .equalizer: return "waveform"
        case .settings: return "gearshape"
        }
    }
}

struct MixerPopoverView: View {
    @EnvironmentObject private var controller: MixerController
    @State private var currentTab: MixerPopoverTab = .mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(WonderMixTheme.hairline)
                .frame(height: 1)
            content
            Rectangle()
                .fill(WonderMixTheme.hairline)
                .frame(height: 1)
            footer
        }
        .frame(width: 360)
        .frame(maxHeight: 520)
        .foregroundStyle(WonderMixTheme.ink)
        .background(OrangeBlurBackground())
        .background(ClearPopoverWindow())
        .preferredColorScheme(.dark)
        .onAppear {
            controller.refreshPermissionStatus(andRebuildIfGranted: true)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if currentTab != .mixer {
                Button {
                    currentTab = .mixer
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WonderMixTheme.ink)
                }
                .buttonStyle(.plain)
                .help("Voltar ao mixer")

                Text(currentTab.rawValue)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(WonderMixTheme.ink)
                Spacer()

                if currentTab == .equalizer {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(controller.equalizerConfig.isEnabled ? WonderMixTheme.glow : WonderMixTheme.inkFaint)
                            .frame(width: 7, height: 7)
                        Text(controller.equalizerConfig.isEnabled ? "EQ Ativo" : "EQ Desligado")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(WonderMixTheme.inkMuted)
                    }
                }
            } else {
                Text("WonderMix")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(WonderMixTheme.ink)
                Spacer()
                Toggle("WonderMix ativo", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                ))
                .toggleStyle(WhiteSwitchStyle())
                .labelsHidden()
                .help(controller.isEnabled ? "Desativar WonderMix" : "Ativar WonderMix")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch currentTab {
        case .equalizer:
            ScrollView {
                EqualizerView()
            }
        case .settings:
            ScrollView {
                SettingsPanelView()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        case .mixer:
            mixerContent
        }
    }

    @ViewBuilder
    private var mixerContent: some View {
        if !controller.isEnabled {
            disabledState
        } else if !controller.hasPermission {
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
                    .foregroundStyle(WonderMixTheme.inkMuted)
                Text("Nenhum app reproduzindo áudio")
                    .font(.callout)
                    .foregroundStyle(WonderMixTheme.inkMuted)
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
                            Rectangle()
                                .fill(WonderMixTheme.hairline)
                                .frame(height: 1)
                                .padding(.leading, 38)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
        }
    }

    private var disabledState: some View {
        VStack(spacing: 12) {
            Image(systemName: "power.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(WonderMixTheme.inkMuted)
            Text("WonderMix desativado")
                .font(.callout.weight(.semibold))
                .foregroundStyle(WonderMixTheme.ink)
            Text("O áudio dos apps segue pelo macOS. Ative de novo para controlar volume e saída.")
                .font(.caption)
                .foregroundStyle(WonderMixTheme.inkMuted)
                .multilineTextAlignment(.center)
            Button("Ativar") {
                controller.setEnabled(true)
            }
            .buttonStyle(WhiteProminentButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(MixerPopoverTab.allCases) { tab in
                Button {
                    currentTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: currentTab == tab ? .bold : .medium))
                    }
                    .foregroundStyle(currentTab == tab ? WonderMixTheme.ink : WonderMixTheme.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(currentTab == tab ? WonderMixTheme.fill : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            Button("Sair") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(WonderMixTheme.inkFaint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
