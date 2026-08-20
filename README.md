# WonderMix

Mixer de áudio nativo para macOS — volume e dispositivo de saída por aplicativo.

## Requisitos

- macOS 15.0+
- [Xcode](https://developer.apple.com/xcode/) 16+ (o Command Line Tools sozinho não basta para apps SwiftUI)

## Como abrir e rodar

1. Abra `WonderMix.xcodeproj` no Xcode.
2. Selecione o scheme **WonderMix**.
3. Product → Run (⌘R).
4. Na primeira execução, conceda **Screen & System Audio Recording** quando o sistema pedir (ou em Ajustes → Privacidade e Segurança).

O app aparece na **menu bar** (ícone de sliders). Configurações ficam em WonderMix → Configurações (ou SettingsLink no rodapé do popover).

## O que faz

- Lista apps que estão tocando áudio
- Slider de volume e mute por app (até 150%)
- Escolha de saída por app (fones, monitor, speakers, etc.)
- Medidor de nível em tempo real
- Persistência de volume/roteamento por bundle ID
- Opção de abrir ao iniciar sessão

## Arquitetura

- **SwiftUI** — menu bar (`MenuBarExtra`) + janela de Settings
- **Core Audio Process Tap** — captura por processo sem driver virtual
- **RTMixer (C)** — ganho e peak no callback real-time (sem alocações)

## Permissão

`NSAudioCaptureUsageDescription` está no Info.plist. Sem a permissão, o WonderMix não cria taps e o áudio do sistema continua normal.
