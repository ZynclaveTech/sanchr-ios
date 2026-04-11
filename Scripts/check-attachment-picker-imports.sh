#!/usr/bin/env bash
set -euo pipefail

# Forbidden imports inside Features/Chats/Presentation/AttachmentPicker/
# - MapKit / CoreLocation reverse-geocoding (privacy contract)
# - GRPC / proto types (presentation layer must not depend on transport)
# - MediaEncryptor / SignalProtocolManager (presentation must not touch crypto directly)
#
# Swift line comments (// and ///) are stripped before grepping so doc-comments
# referencing forbidden symbols don't trip the check. Block comments are out of
# scope (Sanchr uses /// doc comments throughout).

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="$ROOT_DIR/Features/Chats/Presentation/AttachmentPicker"

if [ ! -d "$TARGET_DIR" ]; then
    echo "error: $TARGET_DIR not found"
    exit 1
fi

FORBIDDEN_PATTERNS=(
    '^import MapKit$'
    '^import GRPC$'
    '^import NIO'
    'CLGeocoder'
    'MKMapSnapshotter'
    'MKMapView'
    'SignalProtocolManager'
    'MediaEncryptor'
    'Sanchr_Messaging_'
)

EXIT_CODE=0

check_pattern() {
    local pattern="$1"
    local hit=0
    while IFS= read -r -d '' file; do
        local stripped
        stripped=$(sed 's://.*::' "$file")
        local matches
        matches=$(printf '%s\n' "$stripped" | grep -nE "$pattern" || true)
        if [ -n "$matches" ]; then
            if [ $hit -eq 0 ]; then
                echo "FORBIDDEN: $pattern"
            fi
            while IFS= read -r line; do
                echo "  $file:$line"
            done <<< "$matches"
            hit=1
        fi
    done < <(find "$TARGET_DIR" -name '*.swift' -print0)
    return $hit
}

for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    if ! check_pattern "$pattern"; then
        EXIT_CODE=1
    fi
done

# Allow CoreLocation only in LocationSource.swift (one-shot fix, no geocoding)
check_corelocation() {
    local hit=0
    while IFS= read -r -d '' file; do
        case "$(basename "$file")" in
            LocationSource.swift) continue ;;
        esac
        local stripped
        stripped=$(sed 's://.*::' "$file")
        local matches
        matches=$(printf '%s\n' "$stripped" | grep -nE '^import CoreLocation$' || true)
        if [ -n "$matches" ]; then
            if [ $hit -eq 0 ]; then
                echo "FORBIDDEN: import CoreLocation outside LocationSource.swift"
            fi
            while IFS= read -r line; do
                echo "  $file:$line"
            done <<< "$matches"
            hit=1
        fi
    done < <(find "$TARGET_DIR" -name '*.swift' -print0)
    return $hit
}

if ! check_corelocation; then
    EXIT_CODE=1
fi

if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ AttachmentPicker import hygiene OK"
fi

exit $EXIT_CODE
