#!/usr/bin/env bash
# Instala o WonderMix a partir do release mais recente no GitHub.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/IgorYanko/WonderMix/main/scripts/install.sh | bash
#
# Opções (variáveis de ambiente):
#   PREFIX=/Applications   pasta de destino do .app
#   VERSION=v1.0.0         tag específica (padrão: latest)
#   REPO=IgorYanko/WonderMix

set -euo pipefail

REPO="${REPO:-IgorYanko/WonderMix}"
PREFIX="${PREFIX:-/Applications}"
VERSION="${VERSION:-latest}"
APP_NAME="WonderMix.app"
ASSET_NAME="WonderMix-macOS.zip"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    red "Precisa do comando '$1' instalado."
    exit 1
  fi
}

require curl
require unzip
require ditto

if [[ "$(uname -s)" != "Darwin" ]]; then
  red "WonderMix só roda em macOS 15+."
  exit 1
fi

os_major="$(sw_vers -productVersion | cut -d. -f1)"
if (( os_major < 15 )); then
  red "macOS 15.0 ou superior é necessário (você tem $(sw_vers -productVersion))."
  exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/wondermix.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

bold "→ Buscando release ${VERSION} em ${REPO}…"

api_url="https://api.github.com/repos/${REPO}/releases/${VERSION}"
if [[ "$VERSION" != "latest" && "$VERSION" != latest ]]; then
  # Aceita "1.0.0" ou "v1.0.0"
  tag="$VERSION"
  [[ "$tag" == v* ]] || tag="v${tag}"
  api_url="https://api.github.com/repos/${REPO}/releases/tags/${tag}"
fi

json="$(curl -fsSL "$api_url")" || {
  red "Não foi possível ler o release. Crie um release em https://github.com/${REPO}/releases"
  exit 1
}

download_url="$(
  printf '%s' "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for asset in data.get("assets", []):
    if asset.get("name") == "'"$ASSET_NAME"'":
        print(asset["browser_download_url"])
        break
' 2>/dev/null || true
)"

# Fallback sem python: extrai com sed/grep
if [[ -z "$download_url" ]]; then
  download_url="$(
    printf '%s' "$json" \
      | grep -o "\"browser_download_url\": *\"[^\"]*${ASSET_NAME}\"" \
      | head -1 \
      | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/'
  )"
fi

if [[ -z "$download_url" ]]; then
  red "Asset '${ASSET_NAME}' não encontrado no release."
  red "Publique um release com esse zip (veja scripts/package.sh)."
  exit 1
fi

tag_name="$(
  printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null \
    || printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
)"

bold "→ Baixando ${ASSET_NAME} (${tag_name:-$VERSION})…"
curl -fL --progress-bar -o "$tmp/$ASSET_NAME" "$download_url"

bold "→ Extraindo…"
unzip -q "$tmp/$ASSET_NAME" -d "$tmp/extract"

if [[ ! -d "$tmp/extract/$APP_NAME" ]]; then
  # Alguns zips embutem uma pasta pai
  found="$(find "$tmp/extract" -maxdepth 2 -name "$APP_NAME" -type d | head -1 || true)"
  if [[ -z "$found" ]]; then
    red "O zip não contém ${APP_NAME}."
    exit 1
  fi
  src="$found"
else
  src="$tmp/extract/$APP_NAME"
fi

dest="${PREFIX}/${APP_NAME}"
bold "→ Instalando em ${dest}…"

if [[ -d "$dest" ]]; then
  # Encerra instância antiga se estiver rodando
  pkill -x WonderMix 2>/dev/null || true
  rm -rf "$dest"
fi

# ditto preserva atributos do .app melhor que cp -R
mkdir -p "$PREFIX"
ditto "$src" "$dest"

# Remove a quarentena do Gatekeeper para apps baixados via curl/browser.
# Sem notarização Apple, isso é necessário para o app abrir sem atrito.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

green "✓ WonderMix ${tag_name:-} instalado em ${dest}"
echo
bold "Próximos passos:"
echo "  1. Abra o app:  open \"${dest}\""
echo "  2. Conceda 'Gravação de Tela e Áudio do Sistema' quando pedido"
echo "     (Ajustes → Privacidade e Segurança → Gravação de Tela e Áudio do Sistema)"
echo "  3. O ícone fica na barra de menu (sliders)."
echo
echo "Se o macOS bloquear na primeira abertura:"
echo "  Clique com o botão direito no app → Abrir → Abrir."
