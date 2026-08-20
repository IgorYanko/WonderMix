import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: MixerController

    var body: some View {
        Form {
            Section("Geral") {
                Toggle("Abrir ao iniciar sessão", isOn: $controller.launchAtLogin)
                if let message = controller.loginItemMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Mostrar apps inativos", isOn: $controller.showInactiveApps)
            }

            Section("Permissão de áudio") {
                HStack {
                    Image(systemName: controller.hasPermission ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(controller.hasPermission ? .green : .orange)
                    Text(permissionLabel)
                    Spacer()
                }

                if !controller.hasPermission {
                    Button(controller.permissionStatus == .denied ? "Abrir Ajustes do Sistema" : "Permitir acesso") {
                        controller.requestPermission()
                    }
                    .disabled(controller.isRequestingPermission)

                    Button("Já autorizei — verificar de novo") {
                        controller.refreshPermissionStatus(andRebuildIfGranted: true)
                    }
                    .buttonStyle(.borderless)
                }

                Text("O WonderMix usa gravação de áudio do sistema (não o microfone). Em Ajustes → Privacidade e Segurança → Gravação de Tela e Áudio do Sistema, ative o WonderMix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnóstico") {
                DiagnosticsSection(controller: controller, diagnostics: controller.diagnostics)
            }

            Section("Dados") {
                Button("Redefinir volumes e roteamento salvos", role: .destructive) {
                    controller.resetAllStates()
                }
            }

            Section("Sobre") {
                LabeledContent("Versão", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Requisito", value: "macOS 15.0+")
                Text("Controle de volume e saída por aplicativo, sem drivers virtuais.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .padding()
        .onAppear {
            controller.refreshPermissionStatus(andRebuildIfGranted: true)
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
                    .foregroundStyle(.secondary)
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
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func deviceCard(_ device: DeviceDiagnostics) -> some View {
        let topology = device.topology
        let stats = topology.stats

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: device.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(device.isHealthy ? .green : .orange)
                Text(topology.deviceName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(topology.sampleRate)) Hz · \(topology.bufferFrameSize) fr")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(
                "dropouts \(stats.dropoutCount) · overloads \(stats.overloadCount) · silêncio \(stats.silentCycles) · clip \(stats.clipCycles)"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(stats.dropoutCount > 0 || stats.overloadCount > 0 ? .orange : .secondary)

            Text(
                "carga \(String(format: "%.1f", device.loadPercent))% · \(topology.inputChannelTotal) ch entrada / \(topology.outputChannelTotal) ch saída"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            if topology.deviceSampleRate > 0, topology.deviceSampleRate != topology.sampleRate {
                Text(
                    "atenção: dispositivo em \(Int(topology.deviceSampleRate)) Hz, agregado em \(Int(topology.sampleRate)) Hz"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }

            if let note = topology.mapNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            ForEach(Array(topology.slots.enumerated()), id: \.offset) { _, slot in
                Text(
                    "· \(slot.appName) — buffer \(slot.bufferIndex), canais \(slot.channelOffset)–\(slot.channelOffset + slot.channelCount - 1)"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
