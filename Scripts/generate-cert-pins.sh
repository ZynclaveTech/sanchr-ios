#!/usr/bin/env bash
#
# Print the SPKI pins for a host's TLS chain, ready to paste into
# AppConfiguration's grpcCertificatePins / callCertificatePins.
#
#   ./Scripts/generate-cert-pins.sh api.sanchr.com
#   ./Scripts/generate-cert-pins.sh api.sanchr.com 443
#
# A pin is base64(SHA-256(SubjectPublicKeyInfo)) — the public key, not the
# certificate. The API is served through cert-manager with Let's Encrypt, which
# renews roughly every 60 days. A certificate pin would break every installed
# client on the first renewal; a key pin survives it, because cert-manager reuses
# the private key unless rotationPolicy is set to Always.
#
# Ship at least two pins. The leaf alone means a server key rotation cannot
# happen until every client has updated. Adding the intermediate as a backup
# means a rotation degrades to "still pinned, less tightly" rather than taking
# the app offline.

set -euo pipefail

HOST="${1:-}"
PORT="${2:-443}"

if [[ -z "$HOST" ]]; then
    echo "usage: $0 <host> [port]" >&2
    exit 64
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "error: openssl not found" >&2
    exit 69
fi

chain=$(openssl s_client -servername "$HOST" -connect "${HOST}:${PORT}" \
    -showcerts </dev/null 2>/dev/null || true)

if [[ -z "$chain" ]] || ! grep -q "BEGIN CERTIFICATE" <<<"$chain"; then
    echo "error: could not retrieve a certificate chain from ${HOST}:${PORT}" >&2
    exit 68
fi

echo "SPKI pins for ${HOST}:${PORT}"
echo "Order is leaf first, then intermediates toward the root."
echo

index=0
# Split the chain into individual certificates and pin each one.
while IFS= read -r line; do
    buffer+="$line"$'\n'
    if [[ "$line" == "-----END CERTIFICATE-----" ]]; then
        subject=$(openssl x509 -noout -subject <<<"$buffer" 2>/dev/null | sed 's/^subject=//')
        pin=$(openssl x509 -pubkey -noout <<<"$buffer" 2>/dev/null \
            | openssl pkey -pubin -outform der 2>/dev/null \
            | openssl dgst -sha256 -binary \
            | openssl base64)
        label=$([[ $index -eq 0 ]] && echo "leaf" || echo "intermediate #$index")
        printf '  %-16s %s\n' "$label" "$pin"
        printf '  %-16s %s\n\n' "" "$subject"
        buffer=""
        ((index++))
    fi
done <<<"$chain"

cat <<'EOF'
Paste into SanchrShared/Config/AppConfiguration.swift, e.g.:

    grpcCertificatePins: [
        "<leaf pin>",          // current server key
        "<intermediate pin>",  // backup, survives leaf key rotation
    ],

Re-run and update before the pinned keys change. Shipping a build whose pins no
longer match the server makes the app unable to connect at all.
EOF
