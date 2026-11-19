#!/usr/bin/env bash
# Kani gate (threat CI-5), driven by configuration only:
#   kani-harnesses.tsv  fully qualified harness (module::fn) <TAB> extra cargo-kani flags or - <TAB> timeout s <TAB> covers that must be SATISFIED
#   kani-canaries.tsv   id <TAB> file <TAB> exact text <TAB> replacement (\n = newline) <TAB> reason ERE
# A harness passes only if Kani reports VERIFICATION:- SUCCESSFUL AND exactly the configured number
# of covers is SATISFIED (a proof whose covers are unreachable is vacuous). Every #[kani::proof] in
# the crate (found by `cargo kani list`, not by parsing source) must be listed (an unlisted harness is a silent skip).
#   kani-gate.sh run    <crate-dir> <out-dir>   prove every listed harness
#   kani-gate.sh canary <crate-dir> <out-dir>   every planted defect must make `run` fail for its reason
set -uo pipefail
die() { echo "KANI $*"; exit 2; }
# Harness code is PR code: every cargo kani call is jailed (threat CI-9) so it cannot rewrite
# kani-results.tsv, the logs, this script or the runner's command files. sandbox.sh sits next to this file.
SANDBOX_SH="$(dirname "${BASH_SOURCE[0]}")/sandbox.sh"
# shellcheck source=sandbox.sh
[ -f "$SANDBOX_SH" ] && . "$SANDBOX_SH" || die "missing $SANDBOX_SH (no unjailed mode)"
sandbox_enable
KWORK="$(mktemp -d "${TMPDIR:-/tmp}/kani-gate.XXXXXX")"; export SANDBOX_WORK="$KWORK"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$KWORK/target}"

harnesses_in_src() { # compiler-side discovery (cargo kani list): visibility, comments, macros and
  # cfg_attr cannot hide a harness from it; standard and contract harnesses, fully qualified names.
  # Any failure (build, missing or malformed JSON) returns non-zero: no inventory, no PASS.
  local d log rc
  d="$(cd "$1" && pwd -P)" || return 1   # absolute: SANDBOX_RW is resolved after the cd below
  rm -f "$d/kani-list.json"; : > "$d/kani-list.json"
  log="$( cd "$d" && SANDBOX_RW="$d/kani-list.json" cargo kani list --format json 2>&1 )" || { printf '%s\n' "$log" | tail -5 >&2; return 1; }
  python3 - "$d/kani-list.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("file-version") == "0.1", f"unknown kani list file-version {d.get('file-version')!r}"
for group in ("standard-harnesses", "contract-harnesses"):
    for names in d[group].values():
        for n in names:
            print(n)
PY
  rc=$?; rm -f "$d/kani-list.json"; return "$rc"
}

run_gate() { # <crate-dir> <out-dir>
  local d="$1" out="$2" cfg="$1/kani-harnesses.tsv" h flags secs covers rc=0 log line
  [ -f "$cfg" ] || die "missing $cfg"
  mkdir -p "$out"; printf 'harness\tverdict\treason\n' > "$out/kani-results.tsv"
  ( cd "$d" && cargo fetch ) >/dev/null 2>&1 || echo "KANI warning: cargo fetch failed (the jail has no network)"
  local listed; listed="$(awk -F'\t' '!/^#/ && NF {print $1}' "$cfg")"
  [ -n "$listed" ] || die "no harness listed in $cfg"
  local found
  if ! found="$(harnesses_in_src "$d")" || [ -z "$found" ]; then
    echo "KANI FAIL harness inventory unavailable (cargo kani list failed, returned bad JSON or found no harness)"
    printf 'inventory\tFAIL\tunavailable\n' >> "$out/kani-results.tsv"; return 1
  fi
  while read -r h; do
    grep -qx "$h" <<< "$listed" || { echo "KANI FAIL unlisted harness: $h"; printf '%s\tFAIL\tunlisted\n' "$h" >> "$out/kani-results.tsv"; rc=1; }
  done <<< "$found"
  while IFS=$'\t' read -r h flags secs covers || [ -n "$h" ]; do
    [[ -z "$h" || "$h" = \#* ]] && continue
    [[ "$secs" =~ ^[0-9]+$ && "$covers" =~ ^[0-9]+$ ]] || die "malformed row for $h in $cfg"
    log="$out/${h//::/__}.log"; local -a extra=(); [ "$flags" = "-" ] || read -ra extra <<< "$flags"
    ( cd "$d" && sandbox timeout "$secs" cargo kani "${extra[@]}" --harness "$h" --exact --output-format regular ) > "$log" 2>&1
    local krc=$? reason="" ok=1
    line="$(grep -oE '\*\* [0-9]+ of [0-9]+ cover properties satisfied' "$log" | tail -1)"
    local sat=0 tot=0; [ -n "$line" ] && { sat="$(awk '{print $2}' <<< "$line")"; tot="$(awk '{print $4}' <<< "$line")"; }
    if [ "$krc" -eq 124 ]; then reason="timeout after ${secs}s"
    elif [ "$krc" -ne 0 ] || ! grep -Fq 'VERIFICATION:- SUCCESSFUL' "$log"; then reason="verification failed"
    elif [ "$tot" -ne "$covers" ]; then reason="expected $covers covers, found $tot"
    elif [ "$sat" -ne "$tot" ]; then reason="$sat of $tot covers SATISFIED (vacuous or unreachable)"
    else ok=0; fi
    if [ "$ok" -eq 0 ]; then echo "KANI PASS $h ($sat/$tot covers)"; printf '%s\tPASS\t%s/%s covers\n' "$h" "$sat" "$tot" >> "$out/kani-results.tsv"
    else echo "KANI FAIL $h: $reason"; printf '%s\tFAIL\t%s\n' "$h" "$reason" >> "$out/kani-results.tsv"; grep -E 'Failed Checks|VERIFICATION' "$log" | head -5; rc=1; fi
  done < "$cfg"
  return "$rc"
}

run_canaries() { # <crate-dir> <out-dir>
  local d="$1" out="$2" cfg="$1/kani-canaries.tsv" id file old new want rc=0 n=0
  [ -f "$cfg" ] || die "missing $cfg"
  mkdir -p "$out"; printf 'canary\tverdict\n' > "$out/kani-canaries.tsv"
  while IFS=$'\t' read -r id file old new want || [ -n "$id" ]; do
    [[ -z "$id" || "$id" = \#* ]] && continue
    n=$((n + 1)); local tmp; tmp="$(mktemp -d "$KWORK/canary.XXXXXX")"
    ( cd "$d" && git ls-files -z --cached --others --exclude-standard | xargs -0 -I{} cp --parents {} "$tmp/" ) 2>/dev/null \
      || cp -r "$d/." "$tmp/"
    rm -rf "$tmp/target"
    if ! python3 - "$tmp/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
s = open(p).read()
if s.count(old) != 1: sys.exit(f"canary text found {s.count(old)} times in {p}")
open(p, "w").write(s.replace(old, new))
PY
    then echo "KANI CANARY $id cannot be planted"; printf '%s\tFAIL\n' "$id" >> "$out/kani-canaries.tsv"; rc=1; rm -rf "$tmp"; continue; fi
    local got; got="$(run_gate "$tmp" "$out/canary-$id" 2>&1)"; local grc=$?
    if [ "$grc" -ne 0 ] && grep -Eq "$want" <<< "$got"; then
      echo "KANI CANARY $id caught"; printf '%s\tPASS\n' "$id" >> "$out/kani-canaries.tsv"
    elif [ "$grc" -eq 0 ]; then
      echo "KANI CANARY $id NOT caught"; printf '%s\tFAIL\n' "$id" >> "$out/kani-canaries.tsv"; rc=1
    else
      echo "KANI CANARY $id failed for the wrong reason:"; printf '%s\n' "$got" | tail -12
      printf '%s\tFAIL\n' "$id" >> "$out/kani-canaries.tsv"; rc=1
    fi
    rm -rf "$tmp"
  done < "$cfg"
  [ "$n" -gt 0 ] || die "no canary listed in $cfg"
  return "$rc"
}

case "${1:-}" in
  run) run_gate "${2:?crate dir}" "${3:?out dir}" ;;
  canary) run_canaries "${2:?crate dir}" "${3:?out dir}" ;;
  *) echo "usage: kani-gate.sh run|canary <crate-dir> <out-dir>"; exit 2 ;;
esac
