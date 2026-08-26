# Proto source of truth

The `.proto` files in this directory are **generated artifacts**, not
hand-maintained. The canonical source lives in the backend crate:

    backend/crates/sanchr-proto/proto/

Running `Scripts/generate-protos.sh` will:

1. `rsync` every `*.proto` from `backend/crates/sanchr-proto/proto/` into
   this directory (with `--delete`, so removals propagate).
2. Run `protoc-gen-swift` and `protoc-gen-grpc-swift-v1` to regenerate
   `SanchrShared/Generated/*.pb.swift` and `*.grpc.swift`.

## Do not hand-edit files in this directory

Any local change to `*.proto` here will be wiped on the next generator
run. If you need a schema change, edit the file in
`backend/crates/sanchr-proto/proto/`, run `cargo build` from the
backend, then run `Scripts/generate-protos.sh` from the iOS repo to
pull the change in.

## Override for local experimentation

If you need to point the generator at a different proto source (e.g. a
fork), set `CANONICAL_PROTO_SRC` before invoking the script:

    CANONICAL_PROTO_SRC=/abs/path/to/protos ./Scripts/generate-protos.sh
