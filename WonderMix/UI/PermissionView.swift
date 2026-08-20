import SwiftUI

struct PermissionView: View {
    let status: AudioCapturePermission.Status
    let isRequesting: Bool
    let onAllow: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Permissão de áudio", systemImage: "lock.shield")
                .font(.headline)

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Button(action: onAllow) {
                    HStack {
                        if isRequesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(primaryButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequesting)
                .keyboardShortcut(.defaultAction)

                if status == .denied || status == .unknown {
                    Button("Já autorizei — verificar de novo", action: onRecheck)
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                }
            }

            Text("Em Ajustes, procure WonderMix em “Gravação de Tela e Áudio do Sistema” (ou “System Audio Recording”) e ative.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(4)
    }

    private var statusMessage: String {
        switch status {
        case .authorized:
            return "Permissão concedida."
        case .denied:
            return "O acesso foi negado. Ative o WonderMix nos Ajustes do Sistema — um toque no botão abre a tela certa."
        case .unknown:
            return "O WonderMix precisa de permissão para capturar o áudio de cada app e controlar volume/saída. Nada é gravado nem enviado."
        }
    }

    private var primaryButtonTitle: String {
        switch status {
        case .denied:
            return "Abrir Ajustes do Sistema"
        case .unknown:
            return isRequesting ? "Aguardando…" : "Permitir acesso"
        case .authorized:
            return "Continuar"
        }
    }
}
