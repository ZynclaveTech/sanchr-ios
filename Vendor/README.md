# Vendored static libraries

Four `.a` files under `Vendor/` are **not in git** — about 514 MB, well past
GitHub's 100 MB per-file limit. Everything else here (Swift sources, headers,
modulemap) is tracked.

That means **a fresh clone will not link.** You will get undefined symbols for
`signal_*` or `sanchr_oprf_*` until you rebuild or copy the binaries in. This
file exists because nothing previously recorded how.

| File | Arch | Rebuildable from |
|---|---|---|
| `LibSignal/device/libsignal_ffi.a` | `arm64` | signalapp/libsignal **v0.88.1** |
| `LibSignal/simulator/libsignal_ffi.a` | `x86_64 arm64` | same |
| `SanchrPSI/device/libsanchr_psi.a` | `arm64` | `backend/crates/sanchr-psi` |
| `SanchrPSI/simulator/libsanchr_psi.a` | `arm64` | same |

If you already have a working checkout, copying these four files across is
faster and safer than rebuilding, and guarantees an identical ABI.

## SanchrPSI

Built from `sanchr-psi` in the backend repo, which declares
`crate-type = ["lib", "staticlib"]`. The Swift side calls it through the
hand-written header at `Platform/Crypto/SanchrOPRF/sanchr_oprf.h`, which
declares exactly two functions — `sanchr_oprf_blind` and `sanchr_oprf_unblind`.

```bash
cd <backend-repo>
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

cargo build --release -p sanchr-psi --target aarch64-apple-ios
cargo build --release -p sanchr-psi --target aarch64-apple-ios-sim

cp target/aarch64-apple-ios/release/libsanchr_psi.a      <ios-repo>/Vendor/SanchrPSI/device/
cp target/aarch64-apple-ios-sim/release/libsanchr_psi.a  <ios-repo>/Vendor/SanchrPSI/simulator/
```

Verify before committing to a rebuild:

```bash
lipo -info Vendor/SanchrPSI/device/libsanchr_psi.a          # expect: arm64
nm -gU Vendor/SanchrPSI/device/libsanchr_psi.a | grep sanchr_oprf
                                                            # expect both symbols
```

The simulator slice is **arm64 only**. An Intel Mac cannot run the simulator
build against it; add `x86_64-apple-ios` and `lipo -create` the slices if you
need one.

## LibSignal

Version **0.88.1**, from commit `b3c3852` ("Integrate Signal Protocol E2EE with
libsignal v0.88.1"). There is no version marker inside `Vendor/LibSignal` — this
is the only record, which is why it is written down here.

Getting the version wrong is the real hazard. The Swift sources and
`Headers/signal_ffi.h` in this directory are pinned to 0.88.1's ABI; a binary
built from a different tag will usually still link and then misbehave at
runtime, which is far worse than a build failure. Build from the matching tag,
or copy the existing `.a` files.

```bash
git clone https://github.com/signalapp/libsignal.git
cd libsignal && git checkout v0.88.1

cargo build --release -p libsignal-ffi --target aarch64-apple-ios
cargo build --release -p libsignal-ffi --target aarch64-apple-ios-sim
cargo build --release -p libsignal-ffi --target x86_64-apple-ios

cp target/aarch64-apple-ios/release/libsignal_ffi.a <ios-repo>/Vendor/LibSignal/device/

# The vendored simulator slice is universal, so combine both simulator arches:
lipo -create \
  target/aarch64-apple-ios-sim/release/libsignal_ffi.a \
  target/x86_64-apple-ios/release/libsignal_ffi.a \
  -output <ios-repo>/Vendor/LibSignal/simulator/libsignal_ffi.a
```

After replacing the binaries, regenerate the headers from the same checkout if
you changed versions — `Headers/signal_ffi.h` and the modulemap must come from
the same tag as the `.a`, or the mismatch reappears in a different place.

## How these are linked

Set in `project.yml`, not in Xcode, so `xcodegen generate` reapplies it. The
flags are per-target rather than one combined line:

| Target | `OTHER_LDFLAGS` |
|---|---|
| `LibSignalClient`, `SanchrShared`, `SanchrShareExtension`, `SanchrTests` | `-lsignal_ffi -lc++` |
| `Sanchr` (the app) | `-lsanchr_psi -lc++` |

`LIBRARY_SEARCH_PATHS` is split by SDK, pointing at `device/` for `iphoneos*`
and `simulator/` for `iphonesimulator*`.

A missing `.a` shows up as a link error naming the symbol, not the file, so
check this directory first when symbols go missing after a clone. Which target
fails also tells you which library is missing.

## Worth fixing properly

Storing 514 MB of build output outside version control is a known trade-off, not
a good arrangement. Two ways out, either better than the status quo:

- **Git LFS** for the four `.a` files, so a clone is self-sufficient.
- **Build them in CI** from the pinned sources and publish as release artifacts,
  which also proves the pinned version still builds.

Until then, treat this file as the pin: if libsignal is upgraded, change the
version here in the same commit.
