#!/usr/bin/env bash
#
# puffin/mayhem/build.sh — build three sanitized libFuzzer targets, the project's own test
# suite, and the KAT probe used by mayhem/test.sh.
#
# Targets produced (one Mayhemfile each — names preserved from the prior mayhemheroes
# integration for run-history parity):
#   /mayhem/parse-stream         — mayhem/fuzz/fuzz_targets/parse_stream.rs: parses an untrusted
#                                  binary profiling stream (length-prefixed, nested scope frames)
#                                  via puffin::StreamInfo::parse — the real binary-format parser.
#   /mayhem/clean-function-name  — mayhem/fuzz/fuzz_targets/clean_function_name.rs:
#                                  puffin::clean_function_name(&str).
#   /mayhem/short-file-name      — mayhem/fuzz/fuzz_targets/short_file_name.rs:
#                                  puffin::short_file_name(&str).
#   /mayhem/kat                  — dynamically-linked known-answer probe used by mayhem/test.sh.
#
# mayhem/fuzz/ is an ADDITIVE crate (upstream ships no fuzz/ dir at all) recreated from a prior
# mayhemheroes integration's harnesses, with its own empty [workspace] table (see
# mayhem/fuzz/Cargo.toml) — so it is a SEPARATE cargo workspace from the repo root, and cargo-fuzz
# writes its release binaries under mayhem/fuzz/target/, not $SRC/target/ (SPEC brief §6:
# cargo-fuzz's output path depends on workspace membership — asserted below via `[ -x "$bin" ]`).
#
# TWO Rust toolchains are used (see mayhem/Dockerfile header for the full rationale): the pinned
# NIGHTLY builds the ASan-instrumented fuzz targets (nightly is required for
# -Zsanitizer=address); a separate pinned STABLE toolchain (>= puffin's own MSRV 1.92.0, edition
# 2024) builds the KAT probe and (in mayhem/test.sh) runs the oracle test suite, so a nightly
# regression can never take the oracle down with it. Both toolchains share the same $CARGO_HOME
# registry cache. EVERY cargo invocation below uses an explicit `+<toolchain>` — puffin's upstream
# root rust-toolchain.toml pins stable 1.92.0 (+ the wasm32 target), which would otherwise hijack
# a bare `cargo` call (SPEC brief §6).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs this script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME for BOTH
#     toolchains (the registry cache is not toolchain-specific).
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run, so we do NOT hard-code `--offline` here (that would
#     break this first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Hardcoded (not read from a Docker ARG): the offline PATCH re-run has no build ARGs, only the
# toolchains this same image already installed under $RUSTUP_HOME. Keep in sync with
# mayhem/Dockerfile's RUST_NIGHTLY_CHANNEL / RUST_STABLE_CHANNEL.
NIGHTLY="nightly-2026-03-05"
STABLE="1.94.1"

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# DWARF<4 gate workaround (SPEC §6.2 item 10; see mayhem/Dockerfile header for the full
# rationale): -Z dwarf-version=3 covers rustc's own CUs; -Clinker=<cc-wrapper> PREPENDS a
# hand-built DWARF3 anchor.o as the FIRST object in every link (the wrapper places it before
# "$@") so it becomes the first CU verify-repo's `-m1` check reads, even though the precompiled
# ASan runtime stays DWARF5 deeper in the binary. Only the fuzz harnesses need this — the KAT
# probe and the oracle test suite below keep normal flags.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/toolchains/rust/dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we pin it
# explicitly. --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids ASan backtraces.
# Rust instrumentation goes through RUSTFLAGS -Zsanitizer=address (rustc ignores the clang-style
# $SANITIZER_FLAGS/$CFLAGS the C/C++ path uses); it still flows through as a build ARG (see
# mayhem/Dockerfile) for parity with the org contract even though cargo-fuzz doesn't consume it
# directly.
: "${SANITIZER_FLAGS:=}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"

TRIPLE="x86_64-unknown-linux-gnu"

echo "=== cargo +$NIGHTLY fuzz build (ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# build_fuzz_target <target-name>
#
# mayhem/fuzz is its OWN cargo workspace (empty [workspace] table in mayhem/fuzz/Cargo.toml,
# deliberately not a member of the upstream root Cargo.toml's `members = [...]`), so cargo-fuzz
# writes the release binary under mayhem/fuzz/target/, not $SRC/target/.
build_fuzz_target() {
  local target="$1"
  echo "--- building fuzz target: $target ---"
  cargo "+$NIGHTLY" fuzz build --fuzz-dir mayhem/fuzz -O --debug-assertions "$target"
  local bin="$SRC/mayhem/fuzz/target/$TRIPLE/release/$target"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$target"
  echo "built /mayhem/$target"
}

# Target names preserve the prior mayhemheroes integration's exact (hyphenated) names.
build_fuzz_target "parse-stream"
build_fuzz_target "clean-function-name"
build_fuzz_target "short-file-name"

# ── The KAT probe used by mayhem/test.sh (STABLE toolchain, NORMAL flags — it is a functional
#    oracle, not a triage artifact, so no sanitizer/fuzz instrumentation and no DWARF3 anchor
#    here). ───────────────────────────────────────────────────────────────────────────────────
echo "=== building /mayhem/kat (KAT probe, stable toolchain, normal flags) ==="
(
  unset RUSTFLAGS
  cd "$SRC/mayhem/kat"
  cargo "+$STABLE" build --release
)
cp "$SRC/mayhem/kat/target/release/kat" /mayhem/kat
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

# ── The project's own test suite (STABLE toolchain, NORMAL flags, no RUSTFLAGS/sanitizer) —
#    build only, so mayhem/test.sh just RUNS it. The whole upstream workspace suite (puffin,
#    puffin_egui, puffin_http, puffin_viewer) with all features + all targets, exactly what
#    upstream's own check.sh tests. ─────────────────────────────────────────────────────────────
echo "=== building the project's own test suite (stable toolchain, normal flags, full workspace) ==="
(
  unset RUSTFLAGS
  cargo "+$STABLE" test --no-run --workspace --all-targets --all-features
)

echo "build.sh complete:"
ls -la /mayhem/parse-stream /mayhem/clean-function-name /mayhem/short-file-name /mayhem/kat
