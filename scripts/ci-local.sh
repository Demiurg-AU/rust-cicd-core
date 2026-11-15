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

# --- L: Lean stage (runs only if a lakefile.toml exists; skipped otherwise) ---
LF="$(find . -maxdepth 4 -name lakefile.toml -not -path '*/.lake/*' -not -path './evidence/*' -not -path './target/*' | head -1)"
if [ -n "$LF" ]; then
  LSRC="$(cd "$(dirname "$LF")" && pwd)"
  echo "lean_dir=${LSRC#$ROOT/}" >> "$EV/env.txt"
  # L0: toolchain must be pinned in-repo (lean-toolchain), else builds are not reproducible
  if [ -f "$LSRC/lean-toolchain" ]; then LTC="$(tr -d '[:space:]' < "$LSRC/lean-toolchain")"; else LTC=""; fi
  run L0 lean-toolchain-pinned pass - "$ROOT" test -n "$LTC"
  # LEAN_TOOLCHAIN (optional) = name of a pre-installed, digest-verified toolchain to RUN with;
  # the in-repo lean-toolchain stays the source of truth and L0b checks the versions agree.
  LTC_RUN="${LEAN_TOOLCHAIN:-$LTC}"
  LX=(); [ -n "$LTC_RUN" ] && LX=(elan run "$LTC_RUN")
  LVER="$("${LX[@]}" lean --version 2>&1 | head -1)"
  echo "lean: $LVER | pinned=${LTC:-NONE} | run_with=${LTC_RUN:-default}" >> "$EV/env.txt"
  if [ -n "$LTC" ]; then WANT="${LTC##*:v}"; run L0b lean-version-matches-pin pass - "$ROOT" bash -c "echo \"$LVER\" | grep -q \"version $WANT,\""; fi
  LW="$WORK/lean"; mkdir -p "$LW"; cp -r "$LSRC/." "$LW/"; rm -rf "$LW/.lake"
  run L1 lake-build pass - "$LW" "${LX[@]}" lake build
  # L2: axiom audit computed by Lean itself over every user theorem of the project's
  # lean_lib modules (attributes, namespaces included); Lean errors propagate; sorryAx = FAIL.
  lean_audit() { local d="$1" mods m
    mods="$(awk '/^\[\[lean_lib\]\]/{f=1;next} f&&/^name *=/{gsub(/.*= *"|".*/,"");print;f=0}' "$d/lakefile.toml")"
    [ -n "$mods" ] || { echo "audit: no lean_lib in lakefile.toml"; return 2; }
    { echo "import Lean"; for m in $mods; do echo "import $m"; done
      echo 'open Lean Elab Command'
      echo 'elab "#audit_axioms" : command => do'
      echo '  let env ← getEnv'
      printf '  let mods : Array Name := #[%s]\n' "$(for m in $mods; do printf '`%s, ' "$m"; done | sed 's/, $//')"
      cat <<'LEAN'
  let idxs := mods.filterMap env.getModuleIdx?
  if idxs.size != mods.size then throwError "AUDIT module not found"
  let mut bad : Array Name := #[]
  let mut n : Nat := 0
  for (name, ci) in env.constants.map₁.toList do
    let some mi := env.getModuleIdxFor? name | continue
    unless idxs.contains mi do continue
    let .thmInfo _ := ci | continue
    if name.isInternal then continue
    let some _ ← liftCoreM (findDeclarationRanges? name) | continue
    n := n + 1
    let axs ← liftCoreM (collectAxioms name)
    logInfo m!"AUDIT theorem {name} axioms {axs}"
    if axs.contains ``sorryAx then bad := bad.push name
  logInfo m!"AUDIT theorems={n}"
  if n == 0 then throwError "AUDIT found no theorems"
  unless bad.isEmpty do throwError m!"AUDIT sorryAx in {bad}"
#audit_axioms
LEAN
    } > "$d/ZzAudit.lean"
    ( cd "$d" && { "${LX[@]}" lake build || { echo "AUDIT build failed"; exit 3; }; } && "${LX[@]}" lake env lean ZzAudit.lean ) > "$d/axioms.out" 2>&1
    local rc=$?; cat "$d/axioms.out"; return $rc; }
  run L2 lean-axiom-audit pass - "$LW" bash -c "$(declare -f lean_audit); LX=(${LX[*]}); lean_audit $LW"
  grep -oE 'AUDIT theorem [^ ]+' "$LW/axioms.out" 2>/dev/null | awk '{print $3}' | sort -u > "$EV/lean-theorems.txt"
  run L3 lean-no-sorry-text pass - "$LW" bash -c "! grep -nE '\\b(sorry|admit)\\b' *.lean"
  # Rust<->Lean traceability: proof-map.tsv lines "lean_theorem<TAB>rust_test_path"
  if [ -f "$ROOT/proof-map.tsv" ]; then
    run X1 proof-map-covers-theorems pass - "$ROOT" bash -c "for t in \$(cat '$EV/lean-theorems.txt'); do grep -q \"^\$t\"\$'\\t' proof-map.tsv || { echo \"unmapped theorem: \$t\"; exit 1; }; done"
    run X2 proof-map-rust-tests-pass pass - "$ROOT" bash -c "grep -v '^#' proof-map.tsv | cut -f2 | while read -r t; do [ -z \"\$t\" ] && continue; out=\$(cargo test --locked --lib -- --exact \"\$t\" 2>&1); echo \"\$out\" | grep -q '1 passed' || { echo \"rust test missing/failed: \$t\"; echo \"\$out\" | tail -5; exit 1; }; echo \"ok \$t\"; done"
  fi
  # Lean canaries: gates must FAIL for the right reason.
  # Reason regexes must not match the echoed command line itself (run() logs "$ cmd").
  mkL() { mkdir -p "$CAN/$1"; cp -r "$LSRC/." "$CAN/$1/"; rm -rf "$CAN/$1/.lake"; }
  mkL lsorry; printf '\ntheorem canary_bad : False := by sorry\n' >> "$(ls "$CAN"/lsorry/*.lean | head -1)"
  run CL1 canary-lean-sorry fail "AUDIT sorryAx in \\[canary_bad" "$CAN/lsorry" bash -c "$(declare -f lean_audit); LX=(${LX[*]}); lean_audit $CAN/lsorry"
  mkL lwrong; printf '\ntheorem canary_wrong : (1 : Nat) = 2 := by rfl\n' >> "$(ls "$CAN"/lwrong/*.lean | head -1)"
  run CL2 canary-lean-false-proof fail 'canary_wrong|rfl. failed' "$CAN/lwrong" "${LX[@]}" lake build
  # CL3: an annotated theorem missing from proof-map.tsv must be reported (discovery covers @[attr])
  mkL lunmap; printf '\n@[simp] theorem canary_unmapped : (2 : Nat) + 2 = 4 := rfl\n' >> "$(ls "$CAN"/lunmap/*.lean | head -1)"
  if [ -f "$ROOT/proof-map.tsv" ]; then
    run CL3 canary-unmapped-annotated-theorem fail 'unmapped theorem: canary_unmapped' "$CAN/lunmap" bash -c "$(declare -f lean_audit); LX=(${LX[*]}); lean_audit $CAN/lunmap >/dev/null; for t in \$(grep -oE 'AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}'); do grep -q \"^\$t\"\$'\\t' '$ROOT/proof-map.tsv' || { echo \"unmapped theorem: \$t\"; exit 1; }; done"
  fi
  # CL4: a Lean error inside the audit itself must fail L2 (no silent pass)
  mkL lbroken; printf '\nnamespace Broken\ntheorem canary_broken : True := by exact (rfl : 1 = 2)\nend Broken\n' >> "$(ls "$CAN"/lbroken/*.lean | head -1)"
  run CL4 canary-audit-propagates-lean-error fail '^AUDIT build failed' "$CAN/lbroken" bash -c "$(declare -f lean_audit); LX=(${LX[*]}); lean_audit $CAN/lbroken"
fi

# --- summary ---
TOTAL=$(($(wc -l < "$RES") - 1)); OK=$(grep -c $'\tPASS$' "$RES" || true)
echo "PROGRESS=$OK/$TOTAL" | tee "$EV/summary.txt"
echo "evidence=$EV" | tee -a "$EV/summary.txt"
echo "build_dir=$WORK (outside repo, temporary)" | tee -a "$EV/summary.txt"
( cd "$EV" && sha256sum *.log env.txt results.tsv > SHA256SUMS )
[ "$OK" -eq "$TOTAL" ]
