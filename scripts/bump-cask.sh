#!/usr/bin/env bash
# Atualiza Casks/wondermix.rb com version + sha256 de um zip de release.
#
# Uso:
#   ./scripts/bump-cask.sh 1.0.1 dist/WonderMix-macOS.zip
#   ./scripts/bump-cask.sh 1.0.1   # baixa o asset do GitHub Releases

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASK="$ROOT/Casks/wondermix.rb"
REPO="${REPO:-IgorYanko/WonderMix}"

VERSION="${1:-}"
ZIP_PATH="${2:-}"

if [[ -z "$VERSION" ]]; then
  echo "Uso: $0 <version> [caminho-do-zip]" >&2
  echo "  ex: $0 1.0.1 dist/WonderMix-macOS.zip" >&2
  exit 1
fi

VERSION="${VERSION#v}"

if [[ -z "$ZIP_PATH" ]]; then
  ZIP_PATH="$(mktemp -t wondermix.XXXXXX).zip"
  trap 'rm -f "$ZIP_PATH"' EXIT
  echo "→ Baixando v${VERSION}…"
  curl -fL --progress-bar \
    -o "$ZIP_PATH" \
    "https://github.com/${REPO}/releases/download/v${VERSION}/WonderMix-macOS.zip"
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Zip não encontrado: $ZIP_PATH" >&2
  exit 1
fi

SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "  version: ${VERSION}"
echo "  sha256:  ${SHA}"

# macOS sed precisa de extensão em -i; usa arquivo temporário portátil
tmp="$(mktemp)"
awk -v ver="$VERSION" -v sha="$SHA" '
  /^  version "/ { print "  version \"" ver "\""; next }
  /^  sha256 "/  { print "  sha256 \"" sha "\""; next }
  { print }
' "$CASK" > "$tmp"
mv "$tmp" "$CASK"

echo "✓ Atualizado $CASK"
