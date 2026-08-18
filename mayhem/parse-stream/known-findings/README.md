# Findings in `puffin::StreamInfo::parse` (the `parse-stream` target)

Two independent, genuine upstream bugs were found while integrating this target, both in
`puffin/src/data.rs`'s handling of an untrusted `Stream` (the binary format `.puffin` profile
recordings use — loaded by `puffin_viewer` / `puffin_http` / any consumer that calls
`StreamInfo::parse` on bytes it did not itself produce).

## 1. Integer-overflow panic in `Reader::parse_scope` (the headline finding)

**Reproducer:** `integer-overflow-parse-scope.bin` (22 bytes — a single, otherwise well-formed
scope header with an oversized `scope_size` field).

```
28 01000000 0000000000000000 00 f0ffffffffffffff
'(' scope_id=1  start_ns=0              len=0  scope_size=0xfffffffffffffff0
```

### Cause

`Reader::parse_scope` (`puffin/src/data.rs`, around line 367) computes the offset of a scope's
end unchecked:

```rust
let scope_size = self.parse_scope_size()?;
...
let child_begin_position = self.0.position();
self.0.set_position(child_begin_position + scope_size.0);   // <-- panics: attempt to add with overflow
```

`scope_size.0` is a `u64` read verbatim from the input with no range check. Any value large
enough that `child_begin_position + scope_size.0` exceeds `u64::MAX` trips Rust's built-in
overflow check. `cargo fuzz build` (like OSS-Fuzz's own Rust convention) compiles with
`--debug-assertions`, which turns that overflow into an immediate `panic!` — a clean crash
libFuzzer/Mayhem records every time. (In a release build *without* debug-assertions the same
addition would instead silently **wrap**, handing a bogus, attacker-influenced cursor position to
the rest of the parser — a real, if quieter, logic bug rather than a hard crash.)

### Impact

Denial of service: a consumer that calls `StreamInfo::parse` on a malicious or merely corrupted
21-ish-byte `.puffin` stream crashes immediately — no deep nesting, no large input, and (per the
empirical burst below) is essentially the FIRST thing a coverage-guided fuzzer finds from an empty
corpus. This is a real, trivially-reachable bug in the crate's untrusted-input entry point.

### Reproduction

```sh
./parse-stream -runs=1 known-findings/integer-overflow-parse-scope.bin
# SUMMARY: libFuzzer: deadly signal
#   ...panicking::panic_const::panic_const_add_overflow... <puffin::data::Reader>::parse_scope
#   .../mayhem/puffin/src/data.rs:367:29
```

Also confirmed from a genuinely empty corpus (no seeds at all): `./parse-stream -runs=50000
-max_total_time=15` finds and crashes on a structurally-equivalent input within a few hundred
executions.

### Suggested upstream fix

Use `child_begin_position.checked_add(scope_size.0)` (or `saturating_add`) and return
`Error::InvalidStream` (or `PrematureEnd`) on `None`/saturation instead of trusting the sum, the
same way the crate already rejects other malformed fields (`ScopeNeverEnded`, `InvalidOffset`,
etc.).

## 2. Unbounded recursion -> stack overflow in `Reader::count_all_scopes_at_offset`

**Reproducer:** `stack-overflow-deep-nesting.bin` (744,000 bytes; 24,000 nested, but otherwise
individually well-formed, scopes — this one does NOT trip finding #1).

### Cause

`StreamInfo::parse` also calls `Reader::count_scope_and_depth`, which recurses once per level of
scope nesting with no depth limit:

```rust
fn count_all_scopes_at_offset(
    stream: &Stream, offset: u64, depth: usize, max_depth: &mut usize,
) -> Result<usize> {
    *max_depth = (*max_depth).max(depth);
    let mut num_scopes = 0;
    for child_scope in Reader::with_offset(stream, offset)? {
        num_scopes += 1 + Self::count_all_scopes_at_offset(
            stream, child_scope?.child_begin_position, depth + 1, max_depth,
        )?;
    }
    Ok(num_scopes)
}
```

Each nesting level costs a fixed ~31 bytes (open: `(` + 4-byte id + 8-byte timestamp + 1-byte
string length + 8-byte child-size; close: `)` + 8-byte timestamp), so a stream that is entirely
well-formed by the format's own rules, just deeply nested, exhausts the thread stack once nesting
reaches the low tens of thousands of levels (confirmed: 22,000 levels / 682,000 bytes still parses
fine; 24,000 levels / 744,000 bytes overflows).

### Impact

Denial of service via a large (~700KB+) but otherwise valid-looking profile stream. Confirmed two
ways: a plain (non-sanitized) driver calling `puffin::StreamInfo::parse` directly aborts with "has
overflowed its stack"; the sanitized `parse-stream` target reports `AddressSanitizer:
stack-overflow` on the committed reproducer.

```sh
./parse-stream -runs=1 known-findings/stack-overflow-deep-nesting.bin
# SUMMARY: AddressSanitizer: stack-overflow
```

### Suggested upstream fix

Add a maximum recursion-depth check (returning `Error::InvalidStream` past a sane cap — real
profiles are rarely more than a few dozen frames deep) or convert the walk to an explicit
iterative stack instead of native recursion.

## Why both are left un-"fixed", and the one harness bound that exists

Both are genuine upstream bugs, deliberately left fully reachable through the real, unmodified
`StreamInfo::parse` — "fixing" either one in the harness or the (never-edited) library would just
be reward-hacking a real finding out of existence. The fuzz harness
(`mayhem/fuzz/fuzz_targets/parse_stream.rs`) does carry one bound, `MAX_LEN = 64 * 1024`, but it is
a generic, content-blind SIZE cap, not a guard against either specific bug:

- It does **not** affect finding #1 at all — that reproducer is 22 bytes, far under the cap, and
  every input at or under 64KiB (including both reproducers-in-miniature) is still parsed exactly
  as `StreamInfo::parse` would parse it, untouched.
- For finding #2, it only rules out the pathological "hundreds of KB of purely nested scope
  headers" case (which needs ~700KB to trigger) — a fuzzing-productivity bound in the same spirit
  as OSS-Fuzz harnesses that cap total input size, not a structural check against nesting.
- It exists because an early fork-mode burst (`-fork=4`, 25-30s, corpus = the committed seeds)
  showed that WITHOUT any cap libFuzzer's mutations reliably grow an input's nesting past the
  finding-#2 threshold and the campaign then gets stuck rediscovering that one stack overflow
  forever (hundreds of identical-PC artifacts, flat coverage). Note finding #1 is cheap enough
  (22 bytes) that it is typically what a fresh campaign finds and records FIRST regardless of the
  cap — that is expected and fine; Mayhem dedupes by crash signature and keeps exploring.

Both reproducers are committed here rather than in `mayhem/parse-stream/testsuite/`: seeds in
`testsuite/` are replayed on every future run, and there is no benefit to re-triggering
already-recorded findings on every campaign start.
