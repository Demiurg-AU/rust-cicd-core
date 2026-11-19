#!/usr/bin/env bash
# Fuzz gate (threat CI-8, ROADMAP P5), driven by configuration only:
#   fuzz/fuzz-targets.tsv   target <TAB> oracle (what independent reference the target compares the code with)
#   fuzz/fuzz-canaries.tsv  id <TAB> target <TAB> file (repo-relative) <TAB> exact text <TAB> replacement (\n = newline) <TAB> reason ERE
# Every target is a differential "code vs reference" check. A canary plants a bug in the REAL code and
# runs the REAL target: it must crash for its reason, or the oracle (or the fuzzer) is blind.
# Every target `cargo fuzz list` reports must be listed (an unlisted target is a silent skip).
# All cargo-fuzz calls run jailed (sandbox.sh, threat CI-9): fuzz code cannot touch results or scripts.
#   fuzz-gate.sh run    <repo-dir> <out-dir>   fuzz every listed target for $FUZZ_SECONDS (corpus: <repo>/fuzz/corpus/<t>)
#   fuzz-gate.sh canary <repo-dir> <out-dir>   every planted bug must be found
# env: FUZZ_SECONDS (default 60), FUZZ_CANARY_SECONDS (default 120), FUZZ_TARGET (default x86_64-unknown-linux-gnu)
set -uo pipefail
die() { echo "FUZZ $*"; exit 2; }
SANDBOX_SH="$(dirname "${BASH_SOURCE[0]}")/sandbox.sh"
# shellcheck source=sandbox.sh
[ -f "$SANDBOX_SH" ] && . "$SANDBOX_SH" || die "missing $SANDBOX_SH (no unjailed mode)"
sandbox_enable
FWORK="$(mktemp -d "${TMPDIR:-/tmp}/fuzz-gate.XXXXXX")"; export SANDBOX_WORK="$FWORK"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$FWORK/target}"
FUZZ_TARGET="${FUZZ_TARGET:-x86_64-unknown-linux-gnu}"

listed_targets() { awk -F'\t' '!/^#/ && NF {print $1}' "$1/fuzz/fuzz-targets.tsv"; }

inventory() { # <repo-dir>: targets cargo-fuzz itself knows (Cargo.toml [[bin]]), one per line
  ( cd "$1/fuzz" && cargo fuzz list 2>&1 ) || return 1
}

run_gate() { # <repo-dir> <out-dir>
  local d out="$2" t secs="${FUZZ_SECONDS:-60}" rc=0 log found listed
  d="$(cd "$1" && pwd -P)" || die "no repo dir $1"
  [ -f "$d/fuzz/fuzz-targets.tsv" ] || die "missing $d/fuzz/fuzz-targets.tsv"
  mkdir -p "$out"; printf 'target\tverdict\treason\n' > "$out/fuzz-results.tsv"
  listed="$(listed_targets "$d")"; [ -n "$listed" ] || die "no target listed"
  if ! found="$(inventory "$d")" || [ -z "$found" ]; then
    echo "FUZZ FAIL target inventory unavailable (cargo fuzz list failed or found nothing)"
    printf 'inventory\tFAIL\tunavailable\n' >> "$out/fuzz-results.tsv"; return 1
  fi
  while read -r t || [ -n "$t" ]; do
    [ -n "$t" ] || continue
    grep -qx "$t" <<< "$listed" || { echo "FUZZ FAIL unlisted target: $t"; printf '%s\tFAIL\tunlisted\n' "$t" >> "$out/fuzz-results.tsv"; rc=1; }
  done <<< "$found"
  while read -r t || [ -n "$t" ]; do
    [ -n "$t" ] || continue
    grep -qx "$t" <<< "$found" || { echo "FUZZ FAIL listed target does not exist: $t"; printf '%s\tFAIL\tmissing\n' "$t" >> "$out/fuzz-results.tsv"; rc=1; continue; }
    mkdir -p "$d/fuzz/corpus/$t" "$d/fuzz/artifacts/$t"; log="$out/$t.log"
    ( cd "$d/fuzz" && SANDBOX_RW="$d/fuzz/corpus/$t:$d/fuzz/artifacts/$t" \
        cargo fuzz run --target "$FUZZ_TARGET" "$t" "corpus/$t" -- -max_total_time="$secs" ) > "$log" 2>&1
    local frc=$?
    local kept; kept="$(find "$d/fuzz/corpus/$t" -type f | wc -l)"
    if [ "$frc" -eq 0 ] && grep -q '^Done [0-9]* runs' "$log" && [ "$kept" -eq 0 ]; then
      echo "FUZZ FAIL $t: corpus not persisted (0 inputs in fuzz/corpus/$t after the run)"
      printf '%s\tFAIL\tcorpus not persisted\n' "$t" >> "$out/fuzz-results.tsv"; rc=1
    elif [ "$frc" -eq 0 ] && grep -q '^Done [0-9]* runs' "$log"; then
      echo "FUZZ PASS $t ($(grep -o '^Done [0-9]* runs' "$log" | tail -1), corpus $kept inputs)"
      printf '%s\tPASS\t%ss\n' "$t" "$secs" >> "$out/fuzz-results.tsv"
    else
      echo "FUZZ FAIL $t (exit $frc)"; grep -E 'FUZZ-ORACLE|panicked|deadly signal|ERROR:' "$log" | head -5
      printf '%s\tFAIL\texit %s\n' "$t" "$frc" >> "$out/fuzz-results.tsv"; rc=1
    fi
  done <<< "$listed"
  return "$rc"
}

run_canaries() { # <repo-dir> <out-dir>
  local d out="$2" cfg id t file old new want rc=0 n=0 secs="${FUZZ_CANARY_SECONDS:-120}"
  d="$(cd "$1" && pwd -P)" || die "no repo dir $1"; cfg="$d/fuzz/fuzz-canaries.tsv"
  [ -f "$cfg" ] || die "missing $cfg"
  mkdir -p "$out"; printf 'canary\tverdict\n' > "$out/fuzz-canaries.tsv"
  while IFS=$'\t' read -r id t file old new want || [ -n "$id" ]; do
    [[ -z "$id" || "$id" = \#* ]] && continue
    n=$((n + 1)); local tmp; tmp="$(mktemp -d "$FWORK/canary.XXXXXX")"
    ( cd "$d" && git ls-files -z --cached --others --exclude-standard | xargs -0 -I{} cp --parents {} "$tmp/" ) 2>/dev/null \
      || cp -r "$d/." "$tmp/"
    rm -rf "$tmp/target" "$tmp/fuzz/target" "$tmp/fuzz/corpus" "$tmp/fuzz/artifacts"
    if ! python3 - "$tmp/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
s = open(p).read()
if s.count(old) != 1: sys.exit(f"canary text found {s.count(old)} times in {p}")
open(p, "w").write(s.replace(old, new))
PY
    then echo "FUZZ CANARY $id cannot be planted"; printf '%s\tFAIL\n' "$id" >> "$out/fuzz-canaries.tsv"; rc=1; rm -rf "$tmp"; continue; fi
    local log="$out/canary-$id.log"
    ( cd "$tmp/fuzz" && cargo fuzz run --target "$FUZZ_TARGET" "$t" -- -seed=1 -max_total_time="$secs" ) > "$log" 2>&1
    local frc=$?
    if [ "$frc" -ne 0 ] && grep -Eq "$want" "$log"; then
      echo "FUZZ CANARY $id caught"; printf '%s\tPASS\n' "$id" >> "$out/fuzz-canaries.tsv"
    elif [ "$frc" -eq 0 ]; then
      echo "FUZZ CANARY $id NOT caught in ${secs}s"; printf '%s\tFAIL\n' "$id" >> "$out/fuzz-canaries.tsv"; rc=1
    else
      echo "FUZZ CANARY $id failed for the wrong reason (exit $frc):"; tail -15 "$log"
      printf '%s\tFAIL\n' "$id" >> "$out/fuzz-canaries.tsv"; rc=1
    fi
    rm -rf "$tmp"
  done < "$cfg"
  [ "$n" -gt 0 ] || die "no canary listed in $cfg"
  return "$rc"
}

case "${1:-}" in
  run) run_gate "${2:?repo dir}" "${3:?out dir}" ;;
  canary) run_canaries "${2:?repo dir}" "${3:?out dir}" ;;
  *) echo "usage: fuzz-gate.sh run|canary <repo-dir> <out-dir>"; exit 2 ;;
esac
