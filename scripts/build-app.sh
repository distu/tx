#!/usr/bin/env bash
# Empacota tx como .app bundle assinado localmente (ad-hoc).
# Uso: ./scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
APP_NAME="tx"
BUNDLE_ID="dev.distuai.tx"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> Compilando ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG" --product tx

BIN_PATH="$(swift build -c "$CONFIG" --product tx --show-bin-path)/tx"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Binário não encontrado em $BIN_PATH" >&2
    exit 1
fi

echo "==> Montando bundle em $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Sources/TxApp/App/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copia ícone se existir
ICNS="$ROOT/Sources/TxApp/App/AppIcon.icns"
if [[ -f "$ICNS" ]]; then
    cp "$ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Copia bundles de recursos gerados pelo SwiftPM (ex: tx_TxApp.bundle com Resources/)
BIN_DIR="$(dirname "$BIN_PATH")"
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

# Copia frameworks dinâmicos (ex: Sparkle.framework) para Contents/Frameworks/
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
for framework in "$BIN_DIR"/*.framework; do
    [[ -e "$framework" ]] || continue
    cp -R "$framework" "$APP_BUNDLE/Contents/Frameworks/"
done

# Ajusta rpath do binário para encontrar frameworks em Contents/Frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Detecta identidade de assinatura estável (criada por setup-local-cert.sh).
# Sem ela, ad-hoc é usado, mas TCC invalida permissões a cada build.
ENTITLEMENTS="$ROOT/Sources/TxApp/App/tx.entitlements"
STABLE_CERT="tx Local Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$STABLE_CERT"; then
    SIGN_IDENTITY="$STABLE_CERT"
    echo "==> Assinando com identidade estável '$STABLE_CERT' (TCC preservado entre builds)"
else
    SIGN_IDENTITY="-"
    echo "==> Assinando ad-hoc (TCC será invalidado a cada build)"
    echo "    Para permissões persistentes rode uma vez: ./scripts/setup-local-cert.sh"
fi

codesign --force --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$APP_BUNDLE"

echo "==> Pronto: $APP_BUNDLE"
echo "Para executar: open $APP_BUNDLE"
