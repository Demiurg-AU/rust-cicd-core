#!/usr/bin/env bash
# Run the template on an external crate (ROADMAP criterion 3, owner decision 2026-11-21: 3a and 3b).
#   scripts/pilot.sh pilots/<name> [3a|3b]
# 3a: the crate at its pinned commit + the pilot's overlay/ (configuration only: lockfile, supply-chain, deny/mutants
#     config) + the template's scripts, run through scripts/ci-local.sh unchanged. 3b: additionally the pilot's
#     spec/ pack (verification code: fuzz targets, Kani harnesses), run through scripts/fuzz-gate.sh / kani-gate.sh.
# Prints: template and crate commits, what the overlay changed, every gate that did not PASS with its reason, the
# verdict of every domain claim (claims.tsv) and where the evidence is. Exit 0 only if every stage PASSED.
set -uo pipefail
TPL="$(cd "$(dirname "$0")/.." && pwd)"
P="${1:?usage: scripts/pilot.sh pilots/<name> [3a|3b]}"; STAGE="${2:-3a}"
P="$(cd "$P" && pwd)" || exit 2
[ -f "$P/pilot.env" ] || { echo "PILOT no pilot.env in $P"; exit 2; }
# Parse only allowlisted literal values; caller-controlled profiles are never shell code.
profile=$(bash "$(dirname "$0")/pilot-config.sh" "$P/pilot.env") || exit 2
while IFS=$'\t' read -r key value; do
  printf -v "$key" '%s' "$value"
done <<< "$profile"
: "${CRATE_NAME:?}" "${CRATE_URL:?}" "${CRATE_SHA:?}"
case "$STAGE" in 3a|3b) ;; *) echo "PILOT stage must be 3a or 3b"; exit 2 ;; esac
# Keep build scratch on the workspace filesystem by default. A caller can choose another TMPDIR.
pilot_tmp_parent=${TMPDIR:-"$HOME/workspace"}
mkdir -p -- "$pilot_tmp_parent" || exit 1
pilot_tmp_parent="$(cd -- "$pilot_tmp_parent" && pwd -P)" || exit 1
pilot_tmp="$(mktemp -d -- "$pilot_tmp_parent/rcc.XXXXXX")" || exit 1
trap 'rm -rf -- "$pilot_tmp"' EXIT
export TMPDIR="$pilot_tmp"
printf 'PILOT TMPDIR=%s\n' "$TMPDIR"
df -hP -- "$TMPDIR" || exit 1
# checked before anything is cloned or copied:
# 3a: configuration only. Anything else in overlay/ is refused, so a PASS cannot come from edited crate code.
CONFIG='^(Cargo\.lock|deny\.toml|mutants-exclusions\.tsv|supply-chain/[^/]+\.(toml|lock))$'
# every entry counts, not only regular files: a symlink (overlay/src/lib.rs -> elsewhere) would replace crate code
# while validation saw nothing (Codex P2 on #56)
odd="$(cd "$P/overlay" && find . -mindepth 1 ! -type d ! -type f | sed 's#^\./##')"
[ -z "$odd" ] || { echo "PILOT overlay holds entries that are not regular files: $odd"; exit 1; }
bad="$(cd "$P/overlay" && find . -type f | sed 's#^\./##' | grep -Ev "$CONFIG" || true)"
[ -z "$bad" ] || { echo "PILOT overlay holds non-configuration files: $bad"; exit 1; }
if [ "$STAGE" = 3b ] && [ -d "$P/spec" ]; then
  odd="$(cd "$P/spec" && find . -mindepth 1 ! -type d ! -type f | sed 's#^\./##')"
  [ -z "$odd" ] || { echo "PILOT spec pack holds entries that are not regular files: $odd"; exit 1; }
fi
tsha="$(git -C "$TPL" rev-parse HEAD)"; tdirty="$(git -C "$TPL" status --porcelain --untracked-files=no | wc -l)"
# a fresh work dir: no result of an earlier run (Kani proofs, fuzz results, status rows) can be read as this run's
# (Codex P2 on #56)
W="$P/work/$CRATE_NAME"; rm -rf "$P/work"; mkdir -p "$P/work"
git clone -q "$CRATE_URL" "$W" || { echo "PILOT clone failed: $CRATE_URL"; exit 1; }
git -C "$W" checkout -q "$CRATE_SHA" || { echo "PILOT commit not found: $CRATE_SHA"; exit 1; }
[ "$(git -C "$W" rev-parse HEAD)" = "$CRATE_SHA" ] || { echo "PILOT checkout is not $CRATE_SHA"; exit 1; }
cp -r "$P/overlay/." "$W/"
overlay="$(git -C "$W" status --porcelain --ignored --untracked-files=all | sed 's/^/    /')"
spec=""
if [ "$STAGE" = 3b ]; then
  [ -d "$P/spec" ] || { echo "PILOT stage 3b needs a spec pack: $P/spec"; exit 1; }
  clash="$(cd "$P/spec" && find . -type f ! -name '*.append' | sed 's#^\./##' | while read -r f; do [ -e "$W/$f" ] && echo "$f"; done)"
  [ -z "$clash" ] || { echo "PILOT spec pack would overwrite the crate's own files: $clash"; exit 1; }
  cp -r "$P/spec/." "$W/"
  if [ "${PILOT_KANI_RUN:-0}" = 1 ] && [ -d "$P/spec-kani" ]; then cp -r "$P/spec-kani/src" "$P/spec-kani"/kani-*.tsv "$W/"; fi
  # <path>.append adds its lines to <path> (a module declaration for harnesses that must live in the crate)
  while IFS= read -r a; do cat "$a" >> "${a%.append}"; rm -f "$a"; done < <(find "$W" -name '*.append' -not -path '*/target/*')
  spec="$(cd "$P/spec" && find . -type f | sed 's#^\./#    #' | sort)"
fi
mkdir -p "$W/scripts" && cp "$TPL"/scripts/*.sh "$W/scripts/"
echo "PILOT $CRATE_NAME stage $STAGE"
echo "  template: $tsha$([ "$tdirty" -gt 0 ] && echo " (+$tdirty uncommitted tracked changes)")"
echo "  crate:    $CRATE_URL @ $CRATE_SHA"
echo "  judge registries: $TPL (threat-model.tsv, ext-controls.tsv, ruleset-snapshot.json of the template)"
echo "  overlay (configuration):"; printf '%s\n' "$overlay"
[ -n "$spec" ] && { echo "  spec pack (verification code, 3b):"; printf '%s\n' "$spec"; }
log="$P/work/ci-local.log"
( cd "$W" && RCC_REGISTRY_DIR="$TPL" REQUIRE_LEAN="${REQUIRE_LEAN:-1}" SEMVER_BASELINE="${SEMVER_BASELINE:-}" bash scripts/ci-local.sh ) > "$log" 2>&1; rc=$?
ev="$(sed -n 's/^evidence=//p' "$log" | tail -1)"; res="$ev/results.tsv"
[ -f "$res" ] || { echo "PILOT ci-local produced no results (exit $rc); log: $log"; tail -5 "$log"; exit 1; }
reason() { local f; f="$(ls "$ev/$1"-*.log 2>/dev/null | head -1)"; [ -n "$f" ] || { echo "(no log)"; return; }
  grep -vE '^\$ |^\s*$|^\s*(Compiling|Checking|Finished|Running|Downloaded|Downloading|Blocking|Locking|Updating)' "$f" |
    grep -m1 -iE 'error|FAIL|MISSED|denied|unmaintained|not |missing|below|reason' | cut -c1-160 || echo "(see $f)"; }
echo "  ci-local (exit $rc): $(awk -F'\t' 'NR>1 {n++; if ($6=="PASS") p++} END {printf "%d/%d PASS", p, n}' "$res")"
for grp in "core S[0-9]" "canaries C[0-9]" "evidence/judge [EMR][0-9]" "policy T[0-9]|A[0-9]" "lean L[0-9]|LSKIP|CL[0-9]|X[0-9]"; do
  name="${grp%% *}"; rx="^(${grp#* })"
  awk -F'\t' -v rx="$rx" -v g="$name" 'NR>1 && $1 ~ rx {n++; if ($6=="PASS") p++} END {if (n) printf "    %-15s %d/%d PASS\n", g, p, n}' "$res"
done
awk -F'\t' 'NR>1 && $6!="PASS" {print $1 "\t" $2 "\t" $6}' "$res" | while IFS=$'\t' read -r id name v; do
  echo "    NOT PASS $id $name: $v - $(reason "$id")"; done
# stage 3b: the spec pack's own gates (fuzz-gate / kani-gate), each with its own canaries
st="$P/work/status.tsv"; awk -F'\t' 'NR>1 {print "gate:" $1 "\t" $6 "\t" $3}' "$res" > "$st"
s3b=0
if [ "$STAGE" = 3b ]; then
  if [ -f "$W/fuzz/fuzz-targets.tsv" ]; then
    export RUSTUP_TOOLCHAIN="${FUZZ_TOOLCHAIN:-nightly-2026-11-15}"   # cargo-fuzz needs nightly (fuzz.yml pins the same)
    ( cd "$W" && bash scripts/fuzz-gate.sh canary . "$P/work/fuzz-canaries" && bash scripts/fuzz-gate.sh run . "$P/work/fuzz-run" ) > "$P/work/fuzz.log" 2>&1
    r=$?; echo "  fuzz-gate canaries + run (exit $r, budget ${FUZZ_SECONDS:-60}s per target):"
    grep -E '^FUZZ (PASS|FAIL|CANARY)' "$P/work/fuzz.log" | sed 's/^/    /'
    sed -nE 's/^FUZZ CANARY ([A-Za-z0-9_-]+) caught.*/fuzzc:\1\tPASS/p; s/^FUZZ CANARY ([A-Za-z0-9_-]+) (NOT caught|failed|cannot).*/fuzzc:\1\tFAIL/p' "$P/work/fuzz.log" >> "$st"
    [ -f "$P/work/fuzz-run/fuzz-results.tsv" ] && awk -F'\t' 'NR>1 {print "fuzz:" $1 "\t" $2}' "$P/work/fuzz-run/fuzz-results.tsv" >> "$st"
    [ $r -eq 0 ] || s3b=1
    # K5: the saved corpus replayed by a coverage build OUTSIDE the fuzzing session; the session's own "cov:" numbers
    # are not used. Canary: an empty corpus must fall below the first threshold.
    if [ -f "$W/fuzz/fuzz-coverage.tsv" ]; then
      # shellcheck source=sandbox.sh
      . "$TPL/scripts/sandbox.sh" || { echo "PILOT missing sandbox.sh (no unjailed mode)"; exit 1; }
      lc="$(find "$(rustc --print sysroot)" -name llvm-cov -type f | head -1)"
      cov_of() { # <target> <corpus dir> <file> -> line coverage % of that file
        # a fresh profile directory each time: cargo fuzz coverage merges every raw profile it finds there, so a
        # second measurement would include the first (the K5 canary showed it: 68.8% from one empty input)
        rm -rf "$W/fuzz/coverage/$1"; mkdir -p "$W/fuzz/coverage/$1" "$W/target"
        # the coverage build compiles and RUNS the crate, its build scripts and the target on the corpus: jailed like
        # every other run of code under test (Codex P1 on #56); writable: the coverage output and the build dir only
        ( cd "$W" && SANDBOX_WORK="$pilot_tmp" SANDBOX_RW="$W/fuzz/coverage/$1:$W/target" sandbox cargo fuzz coverage "$1" "$2" ) \
          > "$P/work/k5-$1-$(basename "$2").log" 2>&1 || { echo "ERR"; return; }
        # only files of the crate tree: a dependency may have a file of the same name (time's src/date.rs sorts before
        # the crate's and was matched first, E-7), so the report is restricted to sources under $W
        "$lc" report "$W/target/x86_64-unknown-linux-gnu/coverage/x86_64-unknown-linux-gnu/release/$1" \
          -instr-profile="$W/fuzz/coverage/$1/coverage.profdata" "$W" 2>/dev/null | awk -v f="$3" '$1 ~ ("(^|/)" f "$") {gsub("%","",$10); print $10; exit}'; }
      echo "  K5 corpus coverage, measured outside the fuzzer (cargo fuzz coverage + llvm-cov):"
      first=""
      while IFS=$'\t' read -r t f min; do [[ -z "$t" || "$t" == \#* ]] && continue; [ -n "$first" ] || first="$t $f $min"
        c="$(cov_of "$t" "fuzz/corpus/$t" "$f")"
        if [ "$c" != ERR ] && [ -n "$c" ] && awk -v c="$c" -v m="$min" 'BEGIN {exit !(c >= m)}'; then v=PASS; else v=FAIL; s3b=1; fi
        echo "    K5 $v $t: $f lines ${c:-?}% (min $min%)"; printf 'k5:%s\t%s\n' "$t" "$v" >> "$st"
      done < "$W/fuzz/fuzz-coverage.tsv"
      # canary: a corpus of one empty input (what a target that never explored would leave) must fall below the minimum
      # the canary corpus lives in the crate tree, which the jail shows; a dir under $HOME would be hidden by the jail
      # and the replay would measure nothing at all (Codex P2 on #56)
      read -r t f min <<< "$first"; rm -rf "$W/fuzz/k5-one"; mkdir -p "$W/fuzz/k5-one"; : > "$W/fuzz/k5-one/empty"
      c="$(cov_of "$t" "fuzz/k5-one" "$f")"
      grep -q 'Running 1 inputs\|Executed .*1 input\|1 files found' "$P/work/k5-$t-k5-one.log" 2>/dev/null || [ "$c" = ERR ] ||
        { echo "    K5 canary FAIL: the replay did not read its one input (log: $P/work/k5-$t-k5-one.log)"; c=ERR; }
      if [ "$c" != ERR ] && [ -n "$c" ] && awk -v c="$c" -v m="$min" 'BEGIN {exit !(c < m)}'; then echo "    K5 canary PASS: a one-empty-input corpus gives $c% < $min% for $t"; printf 'k5:canary\tPASS\n' >> "$st"
      else echo "    K5 canary FAIL: a one-empty-input corpus gave ${c:-?}% for $t (log: $P/work/k5-$t-k5-one.log)"; s3b=1
        printf 'k5:canary\tFAIL\n' >> "$st"; fi
    fi
    # K4: weaken one oracle at a time; the code canary it named must then escape, or that clause caught nothing
    if [ -f "$W/fuzz/spec-mutants.tsv" ]; then
      echo "  K4 spec mutants (weakened oracle -> the named code canary must escape):"
      while IFS=$'\t' read -r id t file exact repl can; do [[ -z "$id" || "$id" == \#* ]] && continue
        k="$P/work/k4-$id"; rm -rf "$k"; mkdir -p "$k"
        tar -C "$W" --exclude=./target --exclude=./fuzz/target --exclude=./evidence --exclude=./fuzz/coverage -cf - . | tar -C "$k" -xf -
        "${PY:-python3}" - "$k/$file" "$exact" "$repl" <<'PYK' || { echo "    K4 FAIL $id: spec text not found once in $file"; s3b=1; continue; }
import sys
p, a, b = sys.argv[1:4]; s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b.replace("\\n", "\n")))
PYK
        { head -1 "$W/fuzz/fuzz-canaries.tsv"; awk -F'\t' -v c="$can" '$1 == c' "$W/fuzz/fuzz-canaries.tsv"; } > "$k/fuzz/fuzz-canaries.tsv"
        out="$( cd "$k" && FUZZ_CANARY_SECONDS="${K4_SECONDS:-60}" bash scripts/fuzz-gate.sh canary . "$k/out" 2>&1 )"
        if grep -q "^FUZZ CANARY $can NOT caught" <<< "$out"; then v=PASS; else v=FAIL; s3b=1; fi
        echo "    K4 $v $id ($t): with the oracle weakened, $can $([ "$v" = PASS ] && echo "escaped (not caught)" || echo "was still caught or did not run")"
        printf 'k4:%s\t%s\n' "$id" "$v" >> "$st"
      done < "$W/fuzz/spec-mutants.tsv"
    fi
    unset RUSTUP_TOOLCHAIN
  fi
  if [ -f "$W/kani-harnesses.tsv" ]; then
    ( cd "$W" && bash scripts/kani-gate.sh run . "$P/work/kani" && bash scripts/kani-gate.sh canary . "$P/work/kani-canaries" ) > "$P/work/kani.log" 2>&1
    r=$?; echo "  kani-gate (run + canaries, exit $r): $(grep -E '^KANI' "$P/work/kani.log" | tail -3 | tr '\n' ' ')"
    [ -f "$P/work/kani/kani-results.tsv" ] && awk -F'\t' 'NR>1 {print "kani:" $1 "\t" $2}' "$P/work/kani/kani-results.tsv" >> "$st"
    # an optional Kani attempt (PILOT_KANI=abstain) that times out or runs out of memory is ABSTAIN, not a failed 3b
    # step (Codex P2 on #56); only a profile that requires Kani lets it fail 3b
    [ $r -eq 0 ] || [ "${PILOT_KANI:-abstain}" != required ] || s3b=1
  fi
fi
if [ "$STAGE" = 3a ] && [ -f "$P/claims.tsv" ]; then
  echo "  domain claims (claims.tsv, claim-verdict, request: bounded):"
  awk -F'\t' '!/^#/ && NF {print $1}' "$P/claims.tsv" | while read -r c; do
    echo "    $(bash "$TPL/scripts/claim-verdict.sh" "$P/claims.tsv" "$st" "$c" bounded 2>&1 | head -1)"; done
fi
echo "  evidence: $ev (ci-local), $P/work (spec pack logs, status.tsv)"
echo "  log:      $log"
echo "PILOT 3a core (ci-local): $([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
v3b=0
if [ "$STAGE" = 3b ]; then
  # the 3b verdict is computed from the saved results against the profile; recompute it any time with
  #   scripts/pilot-verdict.sh <pilot> <work dir>
  echo "  3b requirements (profile: ${PILOT_3B_REQUIRE:-none}; claims: ${PILOT_3B_CLAIMS:-none}):"
  # a 3b step that failed (fuzz-gate, K5, K4, Kani run) fails 3b even if its rows look complete: recorded for the verdict
  printf 'steps:3b\t%s\n' "$([ "$s3b" -eq 0 ] && echo PASS || echo FAIL)" >> "$st"
  bash "$TPL/scripts/pilot-verdict.sh" "$P" "$P/work"; v3b=$?
fi
[ "$rc" -eq 0 ] && [ "$v3b" -eq 0 ] && exit 0
exit 1
