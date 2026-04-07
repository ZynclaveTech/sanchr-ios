#!/usr/bin/env bash
#
# Regenerate Swift protobuf + grpc client files for the Sanchr iOS app.
#
# Requires:
#   - protoc (brew install protobuf)
#   - protoc-gen-swift (brew install swift-protobuf)
#   - protoc-gen-grpc-swift v1 (bundled at Scripts/bin/protoc-gen-grpc-swift-v1)
#
# Notes:
#   - Sanchr is pinned to grpc-swift 1.27.5 (v1 API: `import GRPC`).
#   - Homebrew only ships grpc-swift v2, which produces incompatible output.
#     The v1 plugin is built from the SPM checkout and committed at
#     Scripts/bin/protoc-gen-grpc-swift-v1 to keep regeneration reproducible.
#
# Drift caveat:
#   Running this will regenerate every .pb.swift / .grpc.swift under
#   SanchrShared/Generated/. In the current committed state, the method
#   descriptor `static let`s inside each `<Service>ClientMetadata.Methods`
#   enum are `internal` in the checked-in files but will come out as `public`
#   from regeneration (a historical hand-edit, non-functional). After running,
#   review the diff and revert any cosmetic drift you don't actually want,
#   or accept it wholesale — both work.
#   - Rebuild with:
#       cd <DerivedData>/.../SourcePackages/checkouts/grpc-swift
#       swift build -c release --product protoc-gen-grpc-swift
#       cp .build/release/protoc-gen-grpc-swift \
#          <repo>/ios/Sanchr-iOS/Scripts/bin/protoc-gen-grpc-swift-v1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROTO_DIR="${REPO_ROOT}/Proto"
OUT_DIR="${REPO_ROOT}/SanchrShared/Generated"

GRPC_PLUGIN="${SCRIPT_DIR}/bin/protoc-gen-grpc-swift-v1"

if ! command -v protoc >/dev/null 2>&1; then
    echo "error: protoc not found. Install with: brew install protobuf" >&2
    exit 1
fi

if ! command -v protoc-gen-swift >/dev/null 2>&1; then
    echo "error: protoc-gen-swift not found. Install with: brew install swift-protobuf" >&2
    exit 1
fi

if [[ ! -x "${GRPC_PLUGIN}" ]]; then
    echo "error: v1 grpc plugin missing at ${GRPC_PLUGIN}" >&2
    echo "       See header comment in this script for rebuild instructions." >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

# List of protos that have gRPC services. Protos without services only need .pb.swift.
SERVICE_PROTOS=(
    auth
    backup
    calling
    contacts
    discovery
    keys
    media
    messaging
    notifications
    settings
    vault
)

# Message-only protos (no service definitions).
MESSAGE_ONLY_PROTOS=(
    backup_payload
    ekf
)

echo "Generating SwiftProtobuf messages..."
for proto in "${SERVICE_PROTOS[@]}" "${MESSAGE_ONLY_PROTOS[@]}"; do
    protoc \
        --proto_path="${PROTO_DIR}" \
        --swift_out="${OUT_DIR}" \
        --swift_opt=Visibility=Public \
        "${PROTO_DIR}/${proto}.proto"
done

echo "Generating gRPC service clients (v1)..."
for proto in "${SERVICE_PROTOS[@]}"; do
    protoc \
        --proto_path="${PROTO_DIR}" \
        --plugin=protoc-gen-grpc-swift="${GRPC_PLUGIN}" \
        --grpc-swift_out="${OUT_DIR}" \
        --grpc-swift_opt=Visibility=Public,Client=true,Server=true \
        "${PROTO_DIR}/${proto}.proto"
done

echo "Done. Generated files in ${OUT_DIR}"
