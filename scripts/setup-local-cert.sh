#!/usr/bin/env bash
# Cria certificado self-signed estável no Keychain do usuário para assinar
# builds locais do tx. Assinar sempre com o mesmo certificado evita que o
# TCC invalide as permissões (Accessibility, Input Monitoring, Microphone)
# a cada rebuild.
#
# Rodar uma vez: ./scripts/setup-local-cert.sh
# Depois build-app.sh detecta automaticamente e usa a identidade estável.

set -euo pipefail

CERT_NAME="tx Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Já existe?
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$CERT_NAME"; then
    echo "==> Certificado '$CERT_NAME' já existe no keychain."
    security find-identity -v -p codesigning | grep -F "$CERT_NAME"
    exit 0
fi

echo "==> Gerando cert self-signed '$CERT_NAME' (válido por 10 anos)..."

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_req

[req_dn]
CN = $CERT_NAME
O = distuai local
OU = tx development
C = BR

[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem" \
    -config "$TMP/cert.cnf" 2>/dev/null

openssl pkcs12 -export \
    -out "$TMP/cert.p12" \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -passout pass:tx-dev \
    -legacy 2>/dev/null

echo "==> Importando no keychain 'login' (pode pedir senha do Keychain Access)..."
security import "$TMP/cert.p12" \
    -k "$KEYCHAIN" \
    -P "tx-dev" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo "==> Marcando cert como trusted para code signing..."
# Requer sudo (uma vez).
sudo security add-trusted-cert \
    -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain \
    "$TMP/cert.pem"

echo ""
echo "==> Pronto!"
echo "Identidades disponíveis para code signing:"
security find-identity -v -p codesigning | grep -F "$CERT_NAME" || true
echo ""
echo "Agora rode: ./scripts/build-app.sh release"
echo "As permissões TCC vão persistir entre builds."
