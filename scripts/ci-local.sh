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

lean_project() {
  find "$1" -maxdepth 4 -name lakefile.toml -not -path '*/.lake/*' -not -path '*/evidence/*' -not -path '*/target/*' | head -1
}
lean_text() {
  ( cd "$1" && ! grep -nE '\b(sorry|admit)\b' *.lean )
}
lean_modules() {
  awk '/^\[\[lean_lib\]\]/{f=1;next} f&&/^name *=/{gsub(/.*= *"|".*/,"");print;f=0}' "$1/lakefile.toml"
}
lean_version() {
  local version
  version="$("${LX[@]}" lean --version 2>&1 | head -1)"
  echo "$version" | grep -q "version ${1##*:v},"
}
pm_tests() {
  test -f "$1" || { echo 'proof-map missing'; return 1; }
  grep -v '^#' "$1" | awk -F'\t' 'NF' | while IFS=$'\t' read -r th t; do
    [ -z "$t" ] && { echo "empty rust test for theorem: $th"; exit 1; }
    out=$(cargo test --locked --lib -- --exact "$t" 2>&1)
    echo "$out" | grep -q '1 passed' || { echo "rust test missing/failed: $t"; echo "$out" | tail -5; exit 1; }
    echo "ok $th -> $t"
  done
}
witness_check() {
  local res="$1"; shift
  local total ok
  total=$(($(wc -l < "$res") - 1)); ok=$(grep -c $'\tPASS$' "$res" || true)
  [ "$ok" -eq "$total" ]
}
seal_evidence() {
  ( cd "$1" && sha256sum ./*.log env.txt results.tsv > SHA256SUMS )
  witness_check "$1/results.tsv"
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
LF="$(lean_project "$ROOT")"
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
    mods="$(lean_modules "$d")"
    [ -n "$mods" ] || { echo "audit: no lean_lib in lakefile.toml"; return 2; }
    { echo "import Lean"; for m in $mods; do echo "import $m"; done
      echo 'open Lean Elab Command'
      echo 'elab "#audit_axioms" : command => do'
      echo '  let env ← getEnv'
      printf '  let mods : Array Name := #[%s]\n' "$(for m in $mods; do printf '`%s, ' "$m"; done | sed 's/, $//')"
      cat <<'LEAN'
  -- lean_lib roots AND their submodules (Root.Sub...), so imported project files are audited too
  let inProject (m : Name) : Bool := mods.any (fun r => r == m || r.isPrefixOf m)
  if (mods.filterMap env.getModuleIdx?).size != mods.size then throwError "AUDIT module not found"
  let mut bad : Array Name := #[]
  let mut n : Nat := 0
  for (name, ci) in env.constants.map₁.toList do
    let some mi := env.getModuleIdxFor? name | continue
    unless inProject (env.header.moduleNames[mi.toNat]!) do continue
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
  run L2 lean-axiom-audit pass - "$LW" bash -c "$(declare -f lean_audit lean_modules); LX=(${LX[*]}); lean_audit $LW"
  grep -oE 'AUDIT theorem [^ ]+' "$LW/axioms.out" 2>/dev/null | awk '{print $3}' | sort -u > "$EV/lean-theorems.txt"
  run L3 lean-no-sorry-text pass - "$LW" bash -c "$(declare -f lean_text); lean_text '$LW'"
  # Rust<->Lean traceability: proof-map.tsv lines "lean_theorem<TAB>rust_test_path"
  # proof-map check: each theorem needs a row whose Rust-test column is non-empty
  pm_check() { local th="$1" pm="$2" rc=0 t
    [ -f "$pm" ] || { echo "proof-map missing: $pm"; return 1; }
    while read -r t; do [ -z "$t" ] && continue
      awk -F'\t' -v t="$t" '$1==t && $2 ~ /[^[:space:]]/ {f=1} END{exit !f}' "$pm" || { echo "unmapped theorem: $t"; rc=1; }
    done < "$th"; return $rc; }
  # X1/X2 are mandatory whenever the Lean stage runs: a missing proof-map.tsv is a FAIL, not a skip.
  run X1 proof-map-covers-theorems pass - "$ROOT" bash -c "$(declare -f pm_check); pm_check '$EV/lean-theorems.txt' proof-map.tsv"
  run X2 proof-map-rust-tests-pass pass - "$ROOT" bash -c "$(declare -f pm_tests); pm_tests proof-map.tsv"
  # Lean canaries: gates must FAIL for the right reason.
  # Reason regexes must not match the echoed command line itself (run() logs "$ cmd").
  mkL() { mkdir -p "$CAN/$1"; cp -r "$LSRC/." "$CAN/$1/"; rm -rf "$CAN/$1/.lake"; }
  mkL lsorry; printf '\ntheorem canary_bad : False := by sorry\n' >> "$(ls "$CAN"/lsorry/*.lean | head -1)"
  run CL1 canary-lean-sorry fail "AUDIT sorryAx in \\[canary_bad" "$CAN/lsorry" bash -c "$(declare -f lean_audit lean_modules); LX=(${LX[*]}); lean_audit $CAN/lsorry"
  mkL lwrong; printf '\ntheorem canary_wrong : (1 : Nat) = 2 := by rfl\n' >> "$(ls "$CAN"/lwrong/*.lean | head -1)"
  run CL2 canary-lean-false-proof fail 'canary_wrong|rfl. failed' "$CAN/lwrong" "${LX[@]}" lake build
  # CL3: an annotated theorem missing from proof-map.tsv must be reported (discovery covers @[attr])
  mkL lunmap; printf '\n@[simp] theorem canary_unmapped : (2 : Nat) + 2 = 4 := rfl\n' >> "$(ls "$CAN"/lunmap/*.lean | head -1)"
  if [ -f "$ROOT/proof-map.tsv" ]; then
    run CL3 canary-unmapped-annotated-theorem fail '^unmapped theorem: canary_unmapped' "$CAN/lunmap" bash -c "$(declare -f lean_audit lean_modules pm_check); LX=(${LX[*]}); lean_audit $CAN/lunmap >/dev/null; grep -oE 'AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt '$ROOT/proof-map.tsv'"
  fi
  # CL5: a theorem in an imported project submodule must be discovered (X1 must report it)
  mkL lsub; ROOTMOD="$(awk '/^\[\[lean_lib\]\]/{f=1;next} f&&/^name *=/{gsub(/.*= *"|".*/,"");print;f=0}' "$CAN/lsub/lakefile.toml" | head -1)"
  mkdir -p "$CAN/lsub/$ROOTMOD"; printf 'theorem canary_submodule : True := trivial\n' > "$CAN/lsub/$ROOTMOD/CanarySub.lean"
  sed -i "1i import $ROOTMOD.CanarySub" "$CAN/lsub/$ROOTMOD.lean"
  if [ -f "$ROOT/proof-map.tsv" ]; then
    run CL5 canary-submodule-theorem-discovered fail '^unmapped theorem: canary_submodule' "$CAN/lsub" bash -c "$(declare -f lean_audit lean_modules pm_check); LX=(${LX[*]}); lean_audit $CAN/lsub >/dev/null; grep -oE 'AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt '$ROOT/proof-map.tsv'"
  fi
  # CL6: a proof-map row with an empty Rust-test column must not satisfy X1
  if [ -f "$ROOT/proof-map.tsv" ]; then
    mkdir -p "$CAN/pmempty"; awk -F'\t' 'BEGIN{OFS="\t"} /^#/||!NF{print;next} !d{$2="";d=1} {print}' "$ROOT/proof-map.tsv" > "$CAN/pmempty/proof-map.tsv"
    run CL6 canary-empty-rust-column fail '^unmapped theorem: ' "$CAN/pmempty" bash -c "$(declare -f pm_check); pm_check '$EV/lean-theorems.txt' proof-map.tsv"
  fi
  # CL7: with no proof-map.tsv at all, X1 must fail (no silent skip)
  mkdir -p "$CAN/pmmissing"
  run CL7 canary-missing-proof-map fail '^proof-map missing' "$CAN/pmmissing" bash -c "$(declare -f pm_check); pm_check '$EV/lean-theorems.txt' proof-map.tsv"
  # CL4: a Lean error inside the audit itself must fail L2 (no silent pass)
  mkL lbroken; printf '\nnamespace Broken\ntheorem canary_broken : True := by exact (rfl : 1 = 2)\nend Broken\n' >> "$(ls "$CAN"/lbroken/*.lean | head -1)"
  run CL4 canary-audit-propagates-lean-error fail '^AUDIT build failed' "$CAN/lbroken" bash -c "$(declare -f lean_audit lean_modules); LX=(${LX[*]}); lean_audit $CAN/lbroken"

  # Audit regressions: missing inputs, empty loops, hidden statuses and evidence.
  mkdir -p "$CAN/discovery" "$CAN/text/Sub" "$CAN/maps" "$CAN/witness"
  run CL8 canary-missing-lean-project fail '^LEAN project missing' "$ROOT" lean_project "$CAN/discovery"
  mkdir -p "$CAN/discovery/a" "$CAN/discovery/b"
  touch "$CAN/discovery/a/lakefile.toml" "$CAN/discovery/b/lakefile.toml"
  run CL9 canary-multiple-lean-projects fail '^LEAN multiple projects' "$ROOT" lean_project "$CAN/discovery"
  run CL10 canary-missing-lean-sources fail '^LEAN sources missing' "$ROOT" lean_text "$CAN/text"
  printf '%s\n' '-- clean root' > "$CAN/text/Root.lean"
  printf '%s\n' '-- sorry in a nested source' > "$CAN/text/Sub/Nested.lean"
  run CL11 canary-nested-sorry-text fail '^LEAN forbidden proof text' "$ROOT" lean_text "$CAN/text"
  printf 'mapped\n' > "$CAN/maps/theorems"
  printf 'mapped\ttests::adds\n' > "$CAN/maps/valid.tsv"
  : > "$CAN/maps/empty"
  run CL12 canary-missing-theorem-list fail '^theorem inventory missing' "$ROOT" pm_check "$CAN/maps/missing" "$CAN/maps/valid.tsv"
  run CL13 canary-empty-theorem-list fail '^theorem inventory empty' "$ROOT" pm_check "$CAN/maps/empty" "$CAN/maps/valid.tsv"
  printf 'unmapped_final_line' > "$CAN/maps/no-newline"
  run CL14 canary-unterminated-theorem fail '^unmapped theorem: unmapped_final_line' "$ROOT" pm_check "$CAN/maps/no-newline" "$CAN/maps/valid.tsv"
  printf '# comment-only map\n' > "$CAN/maps/comments.tsv"
  run CL15 canary-empty-proof-map fail '^proof-map has no test rows' "$ROOT" bash -c "$(declare -f pm_tests); pm_tests '$CAN/maps/comments.tsv'"
  # Shell functions stand in for Cargo only in these status/output regression fixtures.
  cargo() { printf 'fixture text: 1 passed\n\ntest result: ok. 0 passed; 0 failed;\n'; }
  run CL16 canary-test-output-is-not-summary fail '^rust test missing/failed: tests::adds' "$ROOT" pm_tests "$CAN/maps/valid.tsv"
  cargo() { printf 'test result: ok. 1 passed; 0 failed; 0 ignored;\n'; return 1; }
  run CL17 canary-cargo-status fail '^rust test missing/failed: tests::adds' "$ROOT" pm_tests "$CAN/maps/valid.tsv"
  cargo() { printf 'test result: ok. 11 passed; 0 failed; 0 ignored;\n'; }
  run CL18 canary-exact-test-count fail '^rust test missing/failed: tests::adds' "$ROOT" pm_tests "$CAN/maps/valid.tsv"
  unset -f cargo
  run CL19 canary-command-is-not-output fail '^reason absent from tool output' "$ROOT" bash -c "
    $(declare -f run)
    EV='$CAN/witness'; RES='$CAN/witness/inner.tsv'
    run inner command-reason fail COMMAND_ONLY_REASON '$ROOT' bash -c 'exit 1' COMMAND_ONLY_REASON
    if grep -q FAIL_WRONG_REASON \"\$RES\"; then echo 'reason absent from tool output'; exit 1; fi"
  printf 'id\tstep\texpect\texit\treason_check\tverdict\n' > "$CAN/witness/results.tsv"
  run CL20 canary-missing-witness-row fail '^witness missing gate: L2' "$ROOT" witness_check "$CAN/witness/results.tsv" L2
  run CL21 canary-checksum-failure fail '^witness checksum failed' "$ROOT" seal_evidence "$CAN/witness"
  mkL lroots
  sed -i '/^name = "CheckedAdd"/a roots = ["Other"]' "$CAN/lroots/lakefile.toml"
  printf 'theorem canary_custom_root : True := trivial\n' > "$CAN/lroots/Other.lean"
  run CL22 canary-custom-library-root fail '^unmapped theorem: canary_custom_root' "$CAN/lroots" bash -c "$(declare -f lean_audit lean_modules pm_check); LX=(${LX[*]}); lean_audit '$CAN/lroots' >/dev/null; grep -oE 'AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt '$ROOT/proof-map.tsv'"
  mkL lorphan
  mkdir -p "$CAN/lorphan/CheckedAdd"
  printf 'theorem canary_orphan : False := by sorry\n' > "$CAN/lorphan/CheckedAdd/Orphan.lean"
  run CL23 canary-unimported-submodule fail 'AUDIT sorryAx in .*canary_orphan' "$CAN/lorphan" bash -c "$(declare -f lean_audit lean_modules); LX=(${LX[*]}); lean_audit '$CAN/lorphan'"
  mkL ltoml
  printf '\n[[ lean_lib ]]\nname = "Extra"\n' >> "$CAN/ltoml/lakefile.toml"
  printf 'theorem canary_extra_library : True := trivial\n' > "$CAN/ltoml/Extra.lean"
  run CL24 canary-toml-library-discovery fail '^unmapped theorem: canary_extra_library' "$CAN/ltoml" bash -c "$(declare -f lean_audit lean_modules pm_check); LX=(${LX[*]}); lean_audit '$CAN/ltoml' >/dev/null; grep -oE 'AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt '$ROOT/proof-map.tsv'"
  elan() { printf 'Lean (version 4.35.0, fixture)\n'; return 1; }
  run CL25 canary-version-command-status fail '^LEAN version command failed' "$ROOT" lean_version 'leanprover/lean4:v4.35.0'
  unset -f elan
fi

# --- summary ---
TOTAL=$(($(wc -l < "$RES") - 1)); OK=$(grep -c $'\tPASS$' "$RES" || true)
echo "PROGRESS=$OK/$TOTAL" | tee "$EV/summary.txt"
echo "evidence=$EV" | tee -a "$EV/summary.txt"
echo "build_dir=$WORK (outside repo, temporary)" | tee -a "$EV/summary.txt"
seal_evidence "$EV"
