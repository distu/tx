#!/usr/bin/env bash
# Compila release, empacota e instala tx em /Applications/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$ROOT/.build/tx.app"
INSTALL_PATH="/Applications/tx.app"

echo "==> Encerrando instancia anterior (se houver)..."
pkill -x tx 2>/dev/null || true
sleep 0.5

echo "==> Build release..."
"$ROOT/scripts/build-app.sh" release

echo "==> Instalando em ${INSTALL_PATH}..."
rm -rf "${INSTALL_PATH}"
cp -R "${APP_BUNDLE}" "${INSTALL_PATH}"

echo "==> Limpando quarantine (ad-hoc sig)..."
xattr -cr "${INSTALL_PATH}" 2>/dev/null || true

echo "==> Lancando tx..."
open "${INSTALL_PATH}"

echo ""
echo "Instalado: ${INSTALL_PATH}"
sleep 1
echo "PID: $(pgrep -x tx || echo 'aguardando...')"
