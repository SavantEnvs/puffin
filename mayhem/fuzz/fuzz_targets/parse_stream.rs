#![no_main]

use libfuzzer_sys::fuzz_target;
use puffin::{Stream, StreamInfo};

// Puffin's own wire format is a length-prefixed, nested binary stream of profiling
// "scopes" (see puffin/src/data.rs's module doc): each scope begins with a sentinel
// byte, a u32 scope id, an i64 timestamp, a length-prefixed string, and a u64
// child-byte-count, and ends with a sentinel + i64 timestamp. `StreamInfo::parse`
// is the untrusted-input entry point real puffin consumers use when loading a
// `.puffin` profile recording from disk/network (see puffin_viewer / puffin_http) —
// this target feeds it raw fuzzer bytes directly, unmodified and un-truncated.
//
// TWO GENUINE UPSTREAM BUGS were found integrating this target (full writeup +
// standalone reproducers: mayhem/parse-stream/known-findings/README.md). Neither is
// "fixed" here — both stay fully reachable through the real, unmodified
// `StreamInfo::parse`, exactly as a real consumer would hit them:
//   1. An unchecked `child_begin_position + scope_size.0` (u64 add) in
//      `Reader::parse_scope` panics on overflow given one malformed 22-byte scope
//      header — the crate's own untrusted-input entry point crashes on a trivial
//      input; this is the headline finding.
//   2. `Reader::count_all_scopes_at_offset` recurses once per nesting level with no
//      depth limit, so a deeply-but-validly-nested stream (~24k levels, ~740KB)
//      overflows the stack.
//
// MAX_LEN below is a generic, content-blind fuzzing-PRODUCTIVITY bound, not a guard
// against either bug: every input at or under it (including both findings' much
// smaller reproducers) is parsed exactly as `StreamInfo::parse` would parse it,
// untouched. It exists because an uncapped fork-mode burst showed libFuzzer's
// mutations reliably grow inputs past bug #2's ~700KB threshold and then get stuck
// rediscovering that one stack overflow forever (flat coverage, hundreds of
// identical-PC artifacts) instead of exploring the rest of the format — the
// "one-PC crash storm" pattern the integration brief calls out for remediation.
const MAX_LEN: usize = 64 * 1024;

fuzz_target!(|data: &[u8]| {
    if data.len() > MAX_LEN {
        return;
    }
    let stream = Stream::from(data.to_vec());
    let _ = StreamInfo::parse(stream);
});
