import AppKit
import SwiftUI

/// Settings content embedded in the menu-bar popover (panel swap, no separate window).
struct SettingsPanelView: View {
    @EnvironmentObject private var controller: MixerController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSection("Geral") {
                Toggle("Abrir ao iniciar sessão", isOn: $controller.launchAtLogin)
                    .toggleStyle(WhiteSwitchStyle(stretch: true))
                if let message = controller.loginItemMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(WonderMixTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Mostrar apps inativos", isOn: $controller.showInactiveApps)
                    .toggleStyle(WhiteSwitchStyle(stretch: true))
                Toggle("WonderMix ativo", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                ))
                .toggleStyle(WhiteSwitchStyle(stretch: true))
            }

            settingsSection("Permissão de áudio") {
                HStack {
                    Image(systemName: controller.hasPermission ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(WonderMixTheme.ink)
                    Text(permissionLabel)
                    Spacer()
                }

                if !controller.hasPermission {
                    Button(controller.permissionStatus == .denied ? "Abrir Ajustes do Sistema" : "Permitir acesso") {
                        controller.requestPermission()
                    }
                    .buttonStyle(WhiteProminentButtonStyle())
                    .disabled(controller.isRequestingPermission)

                    Button("Já autorizei — verificar de novo") {
                        controller.refreshPermissionStatus(andRebuildIfGranted: true)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WonderMixTheme.ink)
                }

                Text("O WonderMix usa gravação de áudio do sistema (não o microfone). Em Ajustes → Privacidade e Segurança → Gravação de Tela e Áudio do Sistema, ative o WonderMix.")
                    .font(.caption)
                    .foregroundStyle(WonderMixTheme.inkMuted)
            }

            settingsSection("Diagnóstico") {
                DiagnosticsSection(controller: controller, diagnostics: controller.diagnostics)
            }

            settingsSection("Dados") {
                Button("Redefinir volumes e roteamento salvos") {
                    controller.resetAllStates()
                }
                .buttonStyle(.plain)
                .foregroundStyle(WonderMixTheme.ink)
            }

            settingsSection("Sobre") {
                LabeledContent("Versão", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Requisito", value: "macOS 15.0+")
                Text("Controle de volume e saída por aplicativo, sem drivers virtuais.")
                    .font(.caption)
                    .foregroundStyle(WonderMixTheme.inkMuted)
            }
        }
        .padding(8)
        .tint(WonderMixTheme.ink)
        .foregroundStyle(WonderMixTheme.ink)
        .onAppear {
            controller.refreshPermissionStatus(andRebuildIfGranted: true)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WonderMixTheme.inkFaint)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WonderMixTheme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var permissionLabel: String {
        switch controller.permissionStatus {
        case .authorized: return "Permissão concedida"
        case .denied: return "Permissão negada"
        case .unknown: return "Permissão pendente"
        }
    }
}

/// Live view of the audio topology plus the real-time counters. This is what turns
/// "I think it stuttered" into a number.
private struct DiagnosticsSection: View {
    @ObservedObject var controller: MixerController
    @ObservedObject var diagnostics: AudioDiagnostics
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if diagnostics.devices.isEmpty {
                Text("Nenhuma saída ativa.")
                    .font(.caption)
                    .foregroundStyle(WonderMixTheme.inkMuted)
            } else {
                ForEach(diagnostics.devices) { device in
                    deviceCard(device)
                }
            }

            HStack {
                Button(didCopy ? "Copiado" : "Copiar diagnóstico") {
                    let report = controller.diagnosticsReport()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        didCopy = false
                    }
                }
                Button("Zerar contadores") {
                    controller.resetDiagnostics()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(WonderMixTheme.ink)
            .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private func deviceCard(_ device: DeviceDiagnostics) -> some View {
        let topology = device.topology
        let stats = topology.stats

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: device.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(WonderMixTheme.ink)
                Text(topology.deviceName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WonderMixTheme.ink)
                Spacer()
                Text("\(Int(topology.sampleRate)) Hz · \(topology.bufferFrameSize) fr")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(WonderMixTheme.inkMuted)
            }

            Text(
                "dropouts \(stats.dropoutCount) · overloads \(stats.overloadCount) · silêncio \(stats.silentCycles) · clip \(stats.clipCycles)"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(stats.dropoutCount > 0 || stats.overloadCount > 0 ? WonderMixTheme.ink : WonderMixTheme.inkMuted)

            Text(
                "carga \(String(format: "%.1f", device.loadPercent))% · \(topology.inputChannelTotal) ch entrada / \(topology.outputChannelTotal) ch saída"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(WonderMixTheme.inkMuted)

            if topology.deviceSampleRate > 0, topology.deviceSampleRate != topology.sampleRate {
                Text(
                    "atenção: dispositivo em \(Int(topology.deviceSampleRate)) Hz, agregado em \(Int(topology.sampleRate)) Hz"
                )
                .font(.caption2)
                .foregroundStyle(WonderMixTheme.ink)
            }

            if let note = topology.mapNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(WonderMixTheme.ink)
            }

            ForEach(Array(topology.slots.enumerated()), id: \.offset) { _, slot in
                Text(
                    "· \(slot.appName) — buffer \(slot.bufferIndex), canais \(slot.channelOffset)–\(slot.channelOffset + slot.channelCount - 1)"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(WonderMixTheme.inkMuted)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WonderMixTheme.fill, in: RoundedRectangle(cornerRadius: 6))
    }
}
