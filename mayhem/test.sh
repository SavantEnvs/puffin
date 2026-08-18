#!/usr/bin/env bash
#
# puffin/mayhem/test.sh — RUN the project's own cargo test suite AND the KAT probe, and emit a
# CTRF summary. exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) The crate's own genuine test suite (built by build.sh on the STABLE toolchain, normal
#     flags): puffin's own Stream/StreamInfo round-trip tests, clean_function_name /
#     short_file_name table tests, plus the rest of the workspace (puffin_egui, puffin_http,
#     puffin_viewer) — real `#[test]`s asserting exact values, not just "did it exit 0".
#
#  2) The KAT probe /mayhem/kat — SPEC brief §4 forbids relying on `cargo test` ALONE as the
#     oracle. /mayhem/kat is a small, purpose-built, DYNAMICALLY linked binary (build.sh asserts
#     `file` reports "dynamically linked", failing the build otherwise) that exercises the exact
#     same public API the three fuzz targets fuzz (Stream/StreamInfo round trip,
#     clean_function_name, short_file_name) and asserts EXACT values via `assert_eq!` — see
#     mayhem/kat/src/main.rs. A neutered binary (verify-repo's LD_PRELOAD sabotage shim `_exit(0)`s
#     it before any of this runs) prints nothing, so every `grep -qxF` below fails; a patch that
#     stubs a parsing/helper function without literally no-op'ing the whole binary still fails one
#     of the probe's internal `assert_eq!` panics.
#
# This script only RUNS things; mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Keep in sync with mayhem/build.sh — the STABLE toolchain that built the test suite + KAT probe.
STABLE="1.94.1"

export RUSTUP_HOME="${RUSTUP_HOME:-/opt/toolchains/rust/rustup}"
export CARGO_HOME="${CARGO_HOME:-/opt/toolchains/rust/cargo}"
export PATH="$CARGO_HOME/bin:$PATH"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) the project's own cargo test suite (whole workspace, all targets + features; see build.sh) ──
if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test+kat" 0 1 0; exit 2
fi

echo "=== running: cargo +$STABLE test --workspace --all-targets --all-features ==="
OUT="$SRC/mayhem-build-test.log"
mkdir -p "$(dirname "$OUT")"
cargo "+$STABLE" test --workspace --all-targets --all-features > "$OUT" 2>&1; rc1=$?
cargo "+$STABLE" test --workspace --doc --all-features >> "$OUT" 2>&1; rc2=$?
rc=$(( rc1 > rc2 ? rc1 : rc2 ))
tail -100 "$OUT" || true

# Every `test result: ok/FAILED. P passed; F failed; I ignored; ...` line (one per test binary +
# doctest run) reports real counts; sum them.
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); SKIPPED=$(( SKIPPED + i ))
done < <(grep -E '^test result:' "$OUT" | sed -E 's/^test result: [a-zA-Z]+\. ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored;.*/\1 \2 \3/')

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no 'test result:' lines parsed — the suite did not run (cargo exit $rc)" >&2
  emit_ctrf "cargo-test+kat" 0 1 0; exit 1
fi
# A non-zero cargo exit with zero counted failures means a build/harness error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A `[ -x ... ]` guard here
# is how a probe silently stops running and the oracle quietly degrades.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed/computed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

# Expected values, lifted directly from puffin's OWN unit tests (data.rs::test_profile_data,
# utils.rs::test_clean_function_name / test_short_file_name) via mayhem/kat/src/main.rs's fixed
# construction:
kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or parser/helper broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "stream round trip: scope count"     'KAT_PARSE_NUM_SCOPES=3'
kat_expect "stream round trip: max depth"       'KAT_PARSE_DEPTH=2'
kat_expect "stream round trip: time range"      'KAT_PARSE_RANGE_NS=100,400'
kat_expect "stream round trip: top scope data"  'KAT_PARSE_TOP_DATA=data_top'
kat_expect "stream round trip: top scope dur"   'KAT_PARSE_TOP_DURATION_NS=300'
kat_expect "clean_function_name(...)"           'KAT_CLEAN_FN=bar::baz'
kat_expect "short_file_name(...)"               'KAT_SHORT_FILE=cratename/…/module/lib.rs'

emit_ctrf "cargo-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
