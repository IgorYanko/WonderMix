#!/usr/bin/env bash
# Empacota WonderMix.app em dist/WonderMix-macOS.zip para publicar no GitHub Releases.
#
# Uso local:
#   ./scripts/package.sh
#   ./scripts/package.sh --upload   # cria/atualiza release da tag atual (precisa gh)
#
# O workflow .github/workflows/release.yml chama este script em tags v*.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
SCHEME="${SCHEME:-WonderMix}"
DERIVED="${DERIVED:-$ROOT/.build/package}"
DIST="${DIST:-$ROOT/dist}"
APP_NAME="WonderMix.app"
ZIP_NAME="WonderMix-macOS.zip"
UPLOAD=0

for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    *) echo "Opção desconhecida: $arg" >&2; exit 1 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Empacotamento só funciona em macOS." >&2
  exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode não encontrado em $DEVELOPER_DIR" >&2
  exit 1
fi

echo "→ Limpando…"
rm -rf "$DERIVED" "$DIST"
mkdir -p "$DERIVED" "$DIST"

echo "→ Compilando ${SCHEME} (${CONFIGURATION})…"
# Ad-hoc signing: suficiente para distribuição via curl + remoção de quarantine.
# Quando houver certificado Apple Developer, troque por assinatura + notarização.
xcodebuild \
  -project WonderMix.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  ONLY_ACTIVE_ARCH=NO \
  build \
  | awk '/error:|warning:|BUILD SUCCEEDED|BUILD FAILED|\*\*/ {print}'

APP_PATH="$DERIVED/Build/Products/${CONFIGURATION}/WonderMix.app"
if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(find "$DERIVED/Build/Products" -name "$APP_NAME" -type d | head -1 || true)"
fi
if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
  echo "Falha: ${APP_NAME} não encontrado após o build." >&2
  exit 1
fi
echo "  App: $APP_PATH"

echo "→ Empacotando ${ZIP_NAME}…"
(
  cd "$(dirname "$APP_PATH")"
  # --norsrc/--noextattr evita arquivos AppleDouble (._*) no zip.
  ditto -c -k --keepParent --norsrc --noextattr "$APP_NAME" "$DIST/$ZIP_NAME"
)

if ! unzip -l "$DIST/$ZIP_NAME" | grep -F "WonderMix.app/" >/dev/null; then
  echo "Zip inválido — ${APP_NAME} não encontrado dentro do arquivo." >&2
  unzip -l "$DIST/$ZIP_NAME" | head -20 >&2 || true
  exit 1
fi

VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0.0"
)"
BUILD="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0"
)"

echo
echo "✓ Pronto: $DIST/$ZIP_NAME"
echo "  Versão: ${VERSION} (${BUILD})"
ls -lh "$DIST/$ZIP_NAME"

if (( UPLOAD == 1 )); then
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI não encontrado — não deu para fazer upload." >&2
    exit 1
  fi

  TAG="${TAG:-v${VERSION}}"
  echo "→ Publicando release ${TAG}…"

  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DIST/$ZIP_NAME" --clobber
  else
    gh release create "$TAG" "$DIST/$ZIP_NAME" \
      --title "WonderMix ${VERSION}" \
      --notes "$(cat <<EOF
## WonderMix ${VERSION}

### Instalar
\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/IgorYanko/WonderMix/main/scripts/install.sh | bash
\`\`\`

Ou baixe \`WonderMix-macOS.zip\` e arraste \`WonderMix.app\` para \`/Applications\`.

### Após instalar
1. Abra o app (ícone na barra de menu).
2. Conceda **Gravação de Tela e Áudio do Sistema**.
EOF
)"
  fi
  echo "✓ Release ${TAG} publicado."
fi
