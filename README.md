# WonderMix

Mixer de áudio nativo para macOS — volume e dispositivo de saída **por aplicativo**.

Sem drivers virtuais. Usa [Core Audio Process Tap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap) (macOS 15+).

## Instalar (Homebrew)

```bash
brew tap IgorYanko/wondermix https://github.com/IgorYanko/WonderMix
brew install --cask wondermix
```

### Atualizar

```bash
brew update
brew upgrade --cask wondermix
```

### Desinstalar

```bash
brew uninstall --cask wondermix
# opcional — apaga preferências salvas:
# brew uninstall --cask --zap wondermix
```

### Depois de instalar

1. Abra o app: `open /Applications/WonderMix.app` (ícone de sliders na **barra de menu**).
2. Conceda **Gravação de Tela e Áudio do Sistema** quando pedido  
   (Ajustes → Privacidade e Segurança → Gravação de Tela e Áudio do Sistema).
3. Se o macOS bloquear na primeira abertura: botão direito no app → **Abrir** → Abrir.

> O binário ainda **não é notarizado** pela Apple. Homebrew (e o script curl) removem a quarentena; o aviso “Abrir mesmo assim” pode aparecer uma vez.

## Alternativa (curl)

Sem Homebrew, o mesmo release instala com:

```bash
curl -fsSL https://raw.githubusercontent.com/IgorYanko/WonderMix/main/scripts/install.sh | bash
```

Para **atualizar** via curl, rode o mesmo comando de novo — ele substitui `/Applications/WonderMix.app`. Não há checagem automática de versão; por isso o Homebrew é o caminho recomendado.

Versão específica:

```bash
VERSION=v1.0.0 curl -fsSL https://raw.githubusercontent.com/IgorYanko/WonderMix/main/scripts/install.sh | bash
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
- Ativar/desativar o mixer sem sair do app (taps são derrubados; o áudio volta ao macOS)
- Configurações no próprio popover da barra de menu (sem janela separada)
- Abrir ao iniciar sessão
- Painel de diagnóstico (Configurações → Diagnóstico) com dropouts, overloads e topologia

## Rodar a partir do código

1. Abra `WonderMix.xcodeproj` no [Xcode](https://developer.apple.com/xcode/) 16+.
2. Scheme **WonderMix** → Product → Run (⌘R).
3. Conceda a permissão de áudio na primeira execução.

### Testes

```bash
xcodebuild test \
  -project WonderMix.xcodeproj \
  -scheme WonderMix \
  -destination 'platform=macOS' \
  -enableCodeCoverage YES
```

No Xcode: Product → Test (⌘U). A cobertura cobre preferências, política de runtime (enable/permissão/visibilidade) e serialização de estado.

## Publicar um release

Para quem mantém o projeto:

```bash
# Empacota dist/WonderMix-macOS.zip
./scripts/package.sh

# Empacota, sobe o release e atualiza o cask do Homebrew
./scripts/package.sh --upload
```

Ou crie uma tag — o GitHub Actions empacota, publica o release e atualiza `Casks/wondermix.rb`:

```bash
git tag v1.0.1
git push origin v1.0.1
```

O asset publicado deve se chamar **`WonderMix-macOS.zip`**. O cask em `Casks/wondermix.rb` precisa do `version` + `sha256` corretos para o `brew upgrade` funcionar.

## Arquitetura

- **SwiftUI** — menu bar (`MenuBarExtra`) com mixer e configurações no mesmo popover
- **Um aggregate por dispositivo de saída** — N process taps misturados num único IOProc
- **Taps persistentes** — a lista de processos do app é atualizada in-place (sem destruir o tap a cada refresh)
- **Soft power** — desativar faz `teardownAll()` sem terminar o processo
- **RTMixer (C)** — ganho, soma e contadores RT-safe, sem alocação na thread do HAL

## Permissão

`NSAudioCaptureUsageDescription` está no `Info.plist`. Sem a permissão, o WonderMix não cria taps e o áudio do sistema segue normal.

## Licença

Uso pessoal / open source — veja o repositório para detalhes.
