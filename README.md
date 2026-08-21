# WonderMix

Mixer de áudio nativo para macOS — volume e dispositivo de saída **por aplicativo**.

Sem drivers virtuais. Usa [Core Audio Process Tap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap) (macOS 15+).

## Instalar

```bash
curl -fsSL https://raw.githubusercontent.com/IgorYanko/WonderMix/main/scripts/install.sh | bash
```

Isso baixa o `.zip` do [release mais recente](https://github.com/IgorYanko/WonderMix/releases/latest), instala em `/Applications/WonderMix.app` e remove a quarentena do Gatekeeper.

Versão específica:

```bash
VERSION=v1.0.0 curl -fsSL https://raw.githubusercontent.com/IgorYanko/WonderMix/main/scripts/install.sh | bash
```

### Depois de instalar

1. Abra o app: `open /Applications/WonderMix.app` (ícone de sliders na **barra de menu**).
2. Conceda **Gravação de Tela e Áudio do Sistema** quando pedido  
   (Ajustes → Privacidade e Segurança → Gravação de Tela e Áudio do Sistema).
3. Se o macOS bloquear na primeira abertura: botão direito no app → **Abrir** → Abrir.

> O binário do release ainda **não é notarizado** pela Apple. O script de install remove `com.apple.quarantine` para evitar o bloqueio automático; a confirmação “Abrir mesmo assim” pode aparecer uma vez.

### Desinstalar

```bash
pkill -x WonderMix 2>/dev/null || true
rm -rf /Applications/WonderMix.app
```

## Requisitos

- macOS 15.0+
- Permissão de captura de áudio do sistema (não é o microfone)

## O que faz

- Lista apps que estão tocando áudio
- Volume e mute por app (até 150%)
- Saída por app (fones, alto-falantes, etc.)
- Medidor de nível em tempo real
- Persistência de volume/roteamento por bundle ID
- Abrir ao iniciar sessão
- Painel de diagnóstico (Configurações → Diagnóstico) com dropouts, overloads e topologia

## Rodar a partir do código

1. Abra `WonderMix.xcodeproj` no [Xcode](https://developer.apple.com/xcode/) 16+.
2. Scheme **WonderMix** → Product → Run (⌘R).
3. Conceda a permissão de áudio na primeira execução.

## Publicar um release

Para quem mantém o projeto:

```bash
# Empacota dist/WonderMix-macOS.zip
./scripts/package.sh

# Ou empacota e sobe um release da tag (precisa do gh autenticado)
./scripts/package.sh --upload
```

Ou crie uma tag — o GitHub Actions empacota e publica sozinho:

```bash
git tag v1.0.0
git push origin v1.0.0
```

O asset publicado deve se chamar **`WonderMix-macOS.zip`** (é o que o `install.sh` procura).

## Arquitetura

- **SwiftUI** — menu bar (`MenuBarExtra`) + Settings
- **Um aggregate por dispositivo de saída** — N process taps misturados num único IOProc
- **Taps persistentes** — a lista de processos do app é atualizada in-place (sem destruir o tap a cada refresh)
- **RTMixer (C)** — ganho, soma e contadores RT-safe, sem alocação na thread do HAL

## Permissão

`NSAudioCaptureUsageDescription` está no `Info.plist`. Sem a permissão, o WonderMix não cria taps e o áudio do sistema segue normal.

## Licença

Uso pessoal / open source — veja o repositório para detalhes.
