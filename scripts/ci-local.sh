#!/usr/bin/env bash
# Minimal Rust CI core, steps S0-S2 + gate self-test (canaries).
# Every step writes a log; results.tsv is the witness table. NO_WITNESS -> NO_CLOSE.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EV="$ROOT/evidence/$STAMP"
mkdir -p "$EV"
RES="$EV/results.tsv"
printf 'id\tstep\texpect\texit\treason_check\tverdict\n' > "$RES"
export CARGO_TERM_COLOR=never
# Build outputs live OUTSIDE the repo/evidence folder: evidence holds only logs,
# and the run does not depend on being allowed to delete files in the project folder.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rust-cicd-core.XXXXXX")"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$WORK/target}"

# --- environment witness ---
{
  echo "utc=$STAMP"; uname -a
  for t in cargo rustc cargo-clippy rustfmt cargo-nextest cargo-llvm-cov cargo-deny cargo-audit; do
    p="$(command -v "$t" || true)"
    if [ -z "$p" ]; then echo "$t: MISSING"; continue; fi
    # rustup installs identical proxy shims; hash the real toolchain binary instead
    real="$p"; command -v rustup >/dev/null && real="$(rustup which "$t" 2>/dev/null || echo "$p")"
    case "$t" in cargo-*) ver="$(cargo "${t#cargo-}" --version 2>&1 | head -1)";; *) ver="$("$t" --version 2>&1 | head -1)";; esac
    echo "$t: $ver | sha256=$(sha256sum "$real" | cut -c1-64)"
  done
  echo "git_head=$(git rev-parse HEAD 2>/dev/null || echo none)"
  echo "cargo_lock_sha256=$(sha256sum Cargo.lock 2>/dev/null | cut -c1-64)"
} > "$EV/env.txt" 2>&1

# run <id> <name> <expect:pass|fail> <reason-regex-or-dash> <workdir> <cmd...>
run() {
  local id="$1" name="$2" expect="$3" rx="$4" wd="$5"; shift 5
  local log="$EV/$id-$name.log"
  ( cd "$wd" && echo "\$ $*" && "$@" ) > "$log" 2>&1
  local code=$?
  local rc="n/a" verdict
  if [ "$expect" = pass ]; then
    [ $code -eq 0 ] && verdict=PASS || verdict=FAIL
  else
    if [ $code -ne 0 ] && grep -Eq "$rx" "$log"; then rc=matched; verdict=PASS
    elif [ $code -ne 0 ]; then rc=unmatched; verdict=FAIL_WRONG_REASON
    else verdict=FAIL_GATE_DID_NOT_FIRE; fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$expect" "$code" "$rc" "$verdict" >> "$RES"
  echo "[$verdict] $id $name (exit $code)"
}

# --- S0: skeleton builds with the locked graph ---
run S0a build pass - "$ROOT" cargo build --locked --all-targets
# --- S1: quality ---
run S1a fmt pass - "$ROOT" cargo fmt --all -- --check
run S1b clippy pass - "$ROOT" cargo clippy --locked --all-targets -- -D warnings
run S1c test-coverage pass - "$ROOT" cargo llvm-cov nextest --locked --fail-under-lines 80
# --- S2: supply chain ---
run S2a deny pass - "$ROOT" cargo deny --locked check
run S2b audit pass - "$ROOT" cargo audit

# --- A8: gate self-test. Each gate must FAIL on a known-bad input, for the RIGHT reason ---
CAN="$WORK/canaries"; mkdir -p "$CAN"
mk() { mkdir -p "$CAN/$1"; cp -r "$ROOT/Cargo.toml" "$ROOT/Cargo.lock" "$ROOT/src" "$ROOT/deny.toml" "$CAN/$1/"; }
mk fmt;    printf 'pub fn   ugly( ) {}\n' >> "$CAN/fmt/src/lib.rs"
CARGO_TARGET_DIR="$CAN/fmt/target" run C1 canary-fmt fail 'Diff in' "$CAN/fmt" cargo fmt --all -- --check
mk clippy; printf '\npub fn is_empty_vec(v: &[u32]) -> bool { v.len() == 0 }\n' >> "$CAN/clippy/src/lib.rs"
CARGO_TARGET_DIR="$CAN/clippy/target" run C2 canary-clippy fail 'len_zero' "$CAN/clippy" cargo clippy --all-targets -- -D warnings
mk test;   printf '\n#[test]\nfn canary_fails() { assert_eq!(1 + 1, 3); }\n' >> "$CAN/test/src/lib.rs"
CARGO_TARGET_DIR="$CAN/test/target" run C3 canary-test fail 'canary_fails' "$CAN/test" cargo nextest run
mk deny;   sed -i 's/^license = .*/license = "GPL-3.0-only"/' "$CAN/deny/Cargo.toml"
grep -q '^license = ' "$CAN/deny/Cargo.toml" || sed -i '/^\[package\]/a license = "GPL-3.0-only"' "$CAN/deny/Cargo.toml"
CARGO_TARGET_DIR="$CAN/deny/target" run C4 canary-deny-license fail 'GPL-3.0' "$CAN/deny" cargo deny check licenses

# --- summary ---
TOTAL=$(($(wc -l < "$RES") - 1)); OK=$(grep -c $'\tPASS$' "$RES" || true)
echo "PROGRESS=$OK/$TOTAL" | tee "$EV/summary.txt"
echo "evidence=$EV" | tee -a "$EV/summary.txt"
echo "build_dir=$WORK (outside repo, temporary)" | tee -a "$EV/summary.txt"
( cd "$EV" && sha256sum *.log env.txt results.tsv > SHA256SUMS )
[ "$OK" -eq "$TOTAL" ]
