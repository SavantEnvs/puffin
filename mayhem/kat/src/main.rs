//! puffin-mayhem-kat — the known-answer probe used by mayhem/test.sh.
//!
//! Why this exists (SPEC §6.3 / the anti-reward-hacking oracle): `cargo test` ALONE
//! is not an acceptable oracle (SPEC brief §4) — its test binaries can dodge the
//! sabotage shim. This probe is a small, purpose-built, DYNAMICALLY linked binary
//! (build.sh asserts `file` reports "dynamically linked") that exercises the exact
//! same public API surface the three fuzz targets fuzz, and asserts EXACT values:
//!
//!  1. Writer/reader round trip through `puffin::Stream` / `puffin::StreamInfo::parse`
//!     (what `parse-stream` fuzzes) — builds the identical fixed profile puffin's own
//!     `data.rs::test_profile_data` unit test uses, and asserts the parsed scope
//!     count, max depth, top-level scope name, its duration, and the stream's overall
//!     time range.
//!  2. `puffin::clean_function_name` (what `clean-function-name` fuzzes) on a fixed
//!     mangled Rust symbol, asserting the exact cleaned name.
//!  3. `puffin::short_file_name` (what `short-file-name` fuzzes) on a fixed path,
//!     asserting the exact shortened path.
//!
//! A neutered binary (the verify-repo LD_PRELOAD sabotage shim `_exit(0)`s it before
//! any of this runs) prints nothing, so every `grep -qxF` in test.sh fails; a patch
//! that stubs a function without literally no-op'ing the whole binary still fails
//! one of the `assert_eq!`s below.
use std::num::NonZeroU32;

use puffin::{clean_function_name, short_file_name, ScopeId, Stream, StreamInfo};

fn sid(n: u32) -> ScopeId {
    ScopeId(NonZeroU32::new(n).expect("KAT: fixed scope ids are always non-zero"))
}

fn main() {
    // ── 1) Stream writer/reader round trip (parse-stream) ──────────────────────
    // Identical construction to puffin's own `data.rs::test_profile_data` test:
    // one top-level scope "data_top" [100,400) containing two middle scopes.
    let stream = {
        let mut stream = Stream::default();
        let (t0, _) = stream.begin_scope(|| 100, sid(1), "data_top");
        let (m1, _) = stream.begin_scope(|| 200, sid(2), "data_middle_0");
        stream.end_scope(m1, 300);
        let (m1, _) = stream.begin_scope(|| 300, sid(3), "data_middle_1");
        stream.end_scope(m1, 400);
        stream.end_scope(t0, 400);
        stream
    };

    let info = StreamInfo::parse(stream.clone()).expect("KAT: failed to parse fixed stream");
    assert_eq!(info.num_scopes, 3, "KAT: expected 3 scopes in the fixed stream");
    assert_eq!(info.depth, 2, "KAT: expected max depth 2 in the fixed stream");
    assert_eq!(
        info.range_ns,
        (100, 400),
        "KAT: expected time range (100, 400) in the fixed stream"
    );

    let top_scopes = puffin::Reader::from_start(&stream)
        .read_top_scopes()
        .expect("KAT: failed to read top-level scopes");
    assert_eq!(top_scopes.len(), 1, "KAT: expected exactly 1 top-level scope");
    assert_eq!(
        top_scopes[0].record.data, "data_top",
        "KAT: expected top-level scope data \"data_top\""
    );
    assert_eq!(
        top_scopes[0].record.duration_ns, 300,
        "KAT: expected top-level scope duration 300ns"
    );

    println!("KAT_PARSE_NUM_SCOPES={}", info.num_scopes);
    println!("KAT_PARSE_DEPTH={}", info.depth);
    println!("KAT_PARSE_RANGE_NS={},{}", info.range_ns.0, info.range_ns.1);
    println!("KAT_PARSE_TOP_DATA={}", top_scopes[0].record.data);
    println!("KAT_PARSE_TOP_DURATION_NS={}", top_scopes[0].record.duration_ns);

    // ── 2) clean_function_name (clean-function-name) ───────────────────────────
    // Fixed input lifted straight from puffin's own `utils.rs::test_clean_function_name`.
    let cleaned = clean_function_name("foo::bar::baz::f");
    assert_eq!(
        cleaned, "bar::baz",
        "KAT: clean_function_name(\"foo::bar::baz::f\") must equal \"bar::baz\""
    );
    println!("KAT_CLEAN_FN={cleaned}");

    // ── 3) short_file_name (short-file-name) ────────────────────────────────────
    // Fixed input lifted straight from puffin's own `utils.rs::test_short_file_name`.
    let shortened = short_file_name("crates/cratename/src/module/lib.rs");
    assert_eq!(
        shortened, "cratename/…/module/lib.rs",
        "KAT: short_file_name(...) must equal \"cratename/…/module/lib.rs\""
    );
    println!("KAT_SHORT_FILE={shortened}");
}
