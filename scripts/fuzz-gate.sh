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
# env: FUZZ_SECONDS (default 60), FUZZ_CANARY_SECONDS (default 120), FUZZ_TARGET (default x86_64-unknown-linux-gnu),
#      FUZZ_INPUT_TIMEOUT (default 10 s per input), FUZZ_MIN_CPU_PERCENT (default 50)
# The session log is written by the target's own process (#45 item 7). What the host measures cannot be faked from
# inside: the wall clock (a clean run must last the budget), a per-input timeout (a target that sleeps or spins
# on one input is killed by libFuzzer: FC3), and the CPU time of the session (a target that idles below the
# timeout on every input leaves the CPU idle: FC4). Residual: a target that burns CPU without exercising the
# code (busy loop just under the timeout) - only the executions it reports, which it could forge, show that.
set -uo pipefail
die() { echo "FUZZ $*"; exit 2; }
SANDBOX_SH="$(dirname "${BASH_SOURCE[0]}")/sandbox.sh"
# shellcheck source=sandbox.sh
[ -f "$SANDBOX_SH" ] && . "$SANDBOX_SH" || die "missing $SANDBOX_SH (no unjailed mode)"
sandbox_enable
FWORK="$(mktemp -d "${TMPDIR:-/tmp}/fuzz-gate.XXXXXX")"; export SANDBOX_WORK="$FWORK"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$FWORK/target}"
FUZZ_TARGET="${FUZZ_TARGET:-x86_64-unknown-linux-gnu}"

session_cpu() { # <pid> <out-file>: while <pid> runs, sample the CPU seconds of its whole process tree from the
  # HOST's /proc every second; the last sample is the session's CPU time. (The jail's pid namespace hides the
  # tree from rusage accounting, so it is read live; the target cannot write the host's /proc.)
  local root="$1" out="$2" tot
  echo 0 > "$out"
  while kill -0 "$root" 2>/dev/null; do
    tot="$(ps -eo pid=,ppid=,times= | awk -v r="$root" '{ p[$1] = $2; t[$1] = $3 }
      END { for (x in p) { y = x; while (y in p && y != r && y != 1 && y != 0) y = p[y]; if (y == r) s += t[x] }; printf "%d", s }')"
    [ -n "$tot" ] && [ "$tot" -gt "$(cat "$out")" ] && echo "$tot" > "$out"
    sleep 1
  done
}

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
  # the jail has no network: download dependencies first (fetch runs no project code)
  cargo fetch --manifest-path "$d/fuzz/Cargo.toml" >/dev/null 2>&1 || { echo "FUZZ FAIL dependency fetch failed"; return 1; }
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
    # build first, so the timed part below is the fuzzing session alone
    ( cd "$d/fuzz" && cargo fuzz build --target "$FUZZ_TARGET" "$t" ) > "$out/$t.build.log" 2>&1 \
      || { echo "FUZZ FAIL $t: build failed"; tail -5 "$out/$t.build.log"; printf '%s\tFAIL\tbuild\n' "$t" >> "$out/fuzz-results.tsv"; rc=1; continue; }
    local t0 sp; t0="$(date +%s)"
    ( cd "$d/fuzz" && SANDBOX_RW="$d/fuzz/corpus/$t:$d/fuzz/artifacts/$t" \
        cargo fuzz run --target "$FUZZ_TARGET" "$t" "corpus/$t" -- -max_total_time="$secs" -timeout="${FUZZ_INPUT_TIMEOUT:-10}" ) > "$log" 2>&1 &
    sp=$!; session_cpu "$sp" "$FWORK/cpu.txt" & local mon=$!
    wait "$sp"; local frc=$? took=$(( $(date +%s) - t0 )); wait "$mon"; local cpu; cpu="$(cat "$FWORK/cpu.txt")"
    # the log is written by the fuzz target's own process: "Done N runs" and exit 0 can be faked (e.g. a raw
    # exit_group syscall after printing it). The host's clock cannot: a clean run must last the whole budget.
    if [ "$frc" -eq 0 ] && [ "$took" -lt $(( secs * 9 / 10 )) ]; then
      echo "FUZZ FAIL $t: clean exit after ${took}s of a ${secs}s budget (session did not run)"
      printf '%s\tFAIL\tshort session %ss\n' "$t" "$took" >> "$out/fuzz-results.tsv"; rc=1; continue
    fi
    if [ "$frc" -eq 0 ] && [ $(( cpu * 100 )) -lt $(( took * ${FUZZ_MIN_CPU_PERCENT:-50} )) ]; then
      echo "FUZZ FAIL $t: session idle (${cpu}s CPU in ${took}s, below ${FUZZ_MIN_CPU_PERCENT:-50}%)"
      printf '%s\tFAIL\tidle session %ss cpu\n' "$t" "$cpu" >> "$out/fuzz-results.tsv"; rc=1; continue
    fi
    local kept; kept="$(find "$d/fuzz/corpus/$t" -type f | wc -l)"
    if [ "$frc" -eq 0 ] && grep -q '^Done [0-9]* runs' "$log" && [ "$kept" -eq 0 ]; then
      echo "FUZZ FAIL $t: corpus not persisted (0 inputs in fuzz/corpus/$t after the run)"
      printf '%s\tFAIL\tcorpus not persisted\n' "$t" >> "$out/fuzz-results.tsv"; rc=1
    elif [ "$frc" -eq 0 ] && grep -q '^Done [0-9]* runs' "$log"; then
      echo "FUZZ PASS $t ($(grep -o '^Done [0-9]* runs' "$log" | tail -1), corpus $kept inputs, ${cpu}s CPU in ${took}s)"
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
  cargo fetch --manifest-path "$d/fuzz/Cargo.toml" >/dev/null 2>&1 || die "dependency fetch failed"
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
    if [[ "$want" == GATE:* ]]; then
      # a canary against the GATE itself (e.g. a target that fakes a finished session): run_gate must FAIL for the reason
      local g; g="$(FUZZ_SECONDS=20 run_gate "$tmp" "$out/canary-$id" 2>&1)"; local grc=$?
      if [ "$grc" -ne 0 ] && grep -Eq "${want#GATE:}" <<< "$g"; then echo "FUZZ CANARY $id caught"; printf '%s\tPASS\n' "$id" >> "$out/fuzz-canaries.tsv"
      else echo "FUZZ CANARY $id NOT caught by the gate (exit $grc):"; tail -5 <<< "$g"; printf '%s\tFAIL\n' "$id" >> "$out/fuzz-canaries.tsv"; rc=1; fi
      rm -rf "$tmp"; continue
    fi
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
