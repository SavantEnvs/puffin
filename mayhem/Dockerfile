# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — RUST target (cargo / cargo-fuzz). Builds ON TOP of the org base
# (ghcr.io/savantenvs/base), adding a pinned Rust nightly + cargo-fuzz under
# /opt/toolchains/rust, then runs mayhem/build.sh.
#
# puffin is a Rust instrumentation profiler for games. Upstream ships NO fuzz/ crate of its own;
# a PRIOR (mayhemheroes) integration added one, and this port recreates it as the additive
# mayhem/fuzz/ crate (see its Cargo.toml for why it must be its own workspace). Three targets,
# preserving the prior integration's exact (hyphenated) target names for run-history parity:
#   - parse-stream         — puffin::StreamInfo::parse(Stream) on raw fuzzer bytes: the real
#                            binary-format parser (a length-prefixed, nested scope stream — see
#                            puffin/src/data.rs's module doc) that decodes an untrusted `.puffin`
#                            profile recording.
#   - clean-function-name  — puffin::clean_function_name(&str), a pure string-processing helper.
#   - short-file-name      — puffin::short_file_name(&str), ditto.
#
# TWO toolchains (SPEC brief §6): nightly is required for `-Zsanitizer=address` on the fuzz
# targets; a SEPARATE pinned STABLE toolchain builds the KAT probe and runs the oracle test suite
# (`cargo test --workspace`), so an unrelated nightly regression can never take the oracle down
# with it. Both share the same $CARGO_HOME registry cache. The stable channel must be >= puffin's
# own MSRV (workspace.package.rust-version = "1.92.0", edition 2024) — 1.94.1 clears that.
#
# DWARF<4 (SPEC §6.2 item 10): cargo-fuzz links Rust nightly's ASan runtime archive
# (librustc-nightly_rt.asan.a) via --whole-archive; those precompiled objects carry DWARF5 and
# land FIRST in .debug_info, so the `-Z dwarf-version=3` RUSTFLAG (which only affects rustc's OWN
# compilation units) can't lower them. Fix: prepend a hand-compiled `clang -gdwarf-3` anchor.o as
# the FIRST object in every link via a `-Clinker=<cc-wrapper>` RUSTFLAG -- .debug_info CUs appear
# in linker-argument order, so the anchor's DWARF3 CU lands at offset 0, which is what
# verify-repo's `-m1` (first-CU) check reads. Only the fuzz harnesses need this; the KAT probe and
# the oracle test suite keep normal flags -- they are functional oracles, not triage artifacts.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t puffin-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS

# ── Rust toolchains @ a FIXED, lockable, $HOME-independent prefix ──────────────────────────────
# Nightly: required for -Zsanitizer=address (the OSS-Fuzz Rust ASan path) and -Z dwarf-version=3.
# Stable: a second, independent toolchain for the KAT probe + the oracle test suite (see header).
ARG RUST_NIGHTLY_CHANNEL=nightly-2026-03-05
ARG RUST_STABLE_CHANNEL=1.94.1
ARG CARGO_FUZZ_VERSION=0.13.2

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root

RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_NIGHTLY_CHANNEL}" \
 && rustup toolchain install "${RUST_STABLE_CHANNEL}" --profile minimal \
 && rustup component add rust-src --toolchain "${RUST_NIGHTLY_CHANNEL}" \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must read the
 # toolchain and read/refresh the cargo registry cache, so hand the whole prefix to 2000.
 && chown -R 2000:2000 /opt/toolchains/rust

# DWARF3 anchor object + cc-wrapper (see header). Lives under /opt/toolchains/rust alongside the
# rest of the Rust build tooling (it's a link-time helper for the Rust build, not a language
# toolchain cache, so it doesn't need the chown-2000 write access the registry needs).
RUN set -eux; \
    mkdir -p /opt/toolchains/rust/dwarf3-anchor; \
    printf 'void __mayhem_dwarf3_anchor(void) __attribute__((visibility("hidden"),used));\nvoid __mayhem_dwarf3_anchor(void) {}\n' \
      > /opt/toolchains/rust/dwarf3-anchor/anchor.c; \
    clang -g -gdwarf-3 -c /opt/toolchains/rust/dwarf3-anchor/anchor.c \
      -o /opt/toolchains/rust/dwarf3-anchor/anchor.o; \
    printf '#!/bin/bash\nexec cc /opt/toolchains/rust/dwarf3-anchor/anchor.o "$@"\n' \
      > /opt/toolchains/rust/dwarf3-anchor/cc-wrapper.sh; \
    chmod +x /opt/toolchains/rust/dwarf3-anchor/cc-wrapper.sh; \
    chmod a+rX /opt/toolchains/rust/dwarf3-anchor /opt/toolchains/rust/dwarf3-anchor/anchor.o \
               /opt/toolchains/rust/dwarf3-anchor/cc-wrapper.sh; \
    echo "DWARF3 anchor ready: $(readelf --debug-dump=info /opt/toolchains/rust/dwarf3-anchor/anchor.o | grep -m1 Version:)"

USER mayhem

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git history) → /mayhem.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz targets + KAT probe.
RUN bash mayhem/build.sh

# Run the project's functional suite + the KAT probe at build time (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
