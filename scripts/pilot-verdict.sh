#!/usr/bin/env bash
# The stage-3b verdict of a pilot, computed from SAVED results, so it can be recomputed and checked after the run.
#   scripts/pilot-verdict.sh pilots/<name> [work dir, default pilots/<name>/work]
# What is required comes from the pilot's profile (pilot.env), not from which files happen to exist:
#   PILOT_3B_REQUIRE  items among: fuzz-targets fuzz-canaries k5 k4 claims
#   PILOT_3B_CLAIMS   claim ids that must be in claims-3b.tsv and must be PASS
#   PILOT_KANI        abstain (default): Kani is reported on its own line, PASS only with a finished proof and its
#                     canaries, otherwise ABSTAIN, and never decides 3b; required: Kani is a 3b requirement too
# Inputs: <work>/status.tsv (gate:, fuzz:, k5:, k4:, kani: rows written by pilot.sh), <work>/fuzz.log (fuzz-gate's
# canary lines), the manifests in <pilot>/spec/fuzz/, <pilot>/claims-3b.tsv.
# Output: one line per requirement, then "PILOT 3b PASS" (exit 0) or "PILOT 3b FAIL: <n> requirement(s) not met"
# (exit 1), then "PILOT Kani <verdict>: <why>". Exit 2: the profile itself is unusable.
set -uo pipefail
TPL="$(cd "$(dirname "$0")/.." && pwd)"
P="$(cd "${1:?usage: pilot-verdict.sh pilots/<name> [work dir]}" && pwd)" || exit 2
W="${2:-$P/work}"
[ -f "$P/pilot.env" ] || { echo "PILOT no pilot.env in $P"; exit 2; }
# Parse only allowlisted literal values; caller-controlled profiles are never shell code.
profile=$(bash "$(dirname "$0")/pilot-config.sh" "$P/pilot.env") || exit 2
while IFS=$'\t' read -r key value; do
  printf -v "$key" '%s' "$value"
done <<< "$profile"
REQ="${PILOT_3B_REQUIRE:-}"; [ -n "$REQ" ] || { echo "PILOT profile names no 3b requirements (PILOT_3B_REQUIRE)"; exit 2; }
st="$W/status.tsv"; S="$P/spec/fuzz"; bad=0
miss() { echo "  3b MISSING $1"; bad=$((bad + 1)); }
fail() { echo "  3b FAIL $1"; bad=$((bad + 1)); }
ok() { echo "  3b PASS $1"; }
val() { awk -F'\t' -v k="$1" '$1 == k {print $2; n++} END {if (n > 1) print "DUPLICATE"}' "$st" 2>/dev/null | tail -1; }
rows() { awk -F'\t' '!/^#/ && NF {print $1}' "$1"; }
# a required stage needs at least one entry: an empty (or comment-only) manifest proves nothing (Codex P2 on #56)
empty() { [ -z "$(rows "$1")" ]; }
[ -f "$st" ] || { echo "  3b MISSING status.tsv in $W: no saved results"; echo "PILOT 3b FAIL: no saved results"; exit 1; }
# a step pilot.sh saw fail (non-zero exit of fuzz-gate, K5, K4, Kani) fails 3b whatever its rows say
case "$(val steps:3b)" in FAIL) fail "a 3b step exited non-zero (see the pilot output)" ;; esac
for item in $REQ; do
  case "$item" in
    fuzz-targets)
      [ -f "$S/fuzz-targets.tsv" ] || { miss "fuzz-targets: manifest $S/fuzz-targets.tsv"; continue; }
      empty "$S/fuzz-targets.tsv" && { miss "fuzz-targets: manifest $S/fuzz-targets.tsv has no entries"; continue; }
      while read -r t; do v="$(val "fuzz:$t")"
        if [ "$v" = PASS ]; then ok "fuzz:$t"; elif [ -z "$v" ]; then miss "fuzz:$t: no result in status.tsv"; else fail "fuzz:$t: $v"; fi
      done < <(rows "$S/fuzz-targets.tsv") ;;
    fuzz-canaries)
      [ -f "$S/fuzz-canaries.tsv" ] || { miss "fuzz-canaries: manifest $S/fuzz-canaries.tsv"; continue; }
      empty "$S/fuzz-canaries.tsv" && { miss "fuzz-canaries: manifest $S/fuzz-canaries.tsv has no entries"; continue; }
      [ -f "$W/fuzz.log" ] || { miss "fuzz-canaries: fuzz-gate log $W/fuzz.log"; continue; }
      while read -r c; do
        if grep -q "^FUZZ CANARY $c caught" "$W/fuzz.log"; then ok "canary $c caught for its reason"
        elif grep -q "^FUZZ CANARY $c " "$W/fuzz.log"; then fail "canary $c: $(grep -m1 "^FUZZ CANARY $c " "$W/fuzz.log" | cut -c1-120)"
        else miss "canary $c: no line in fuzz.log"; fi
      done < <(rows "$S/fuzz-canaries.tsv") ;;
    k5)
      [ -f "$S/fuzz-coverage.tsv" ] || { miss "k5: manifest $S/fuzz-coverage.tsv (required by the profile)"; continue; }
      empty "$S/fuzz-coverage.tsv" && { miss "k5: manifest $S/fuzz-coverage.tsv has no entries"; continue; }
      for k in $(rows "$S/fuzz-coverage.tsv" | sed 's/^/k5:/') k5:canary; do v="$(val "$k")"
        if [ "$v" = PASS ]; then ok "$k"; elif [ -z "$v" ]; then miss "$k: no result in status.tsv"; else fail "$k: $v"; fi
      done ;;
    k4)
      [ -f "$S/spec-mutants.tsv" ] || { miss "k4: manifest $S/spec-mutants.tsv (required by the profile)"; continue; }
      empty "$S/spec-mutants.tsv" && { miss "k4: manifest $S/spec-mutants.tsv has no entries"; continue; }
      while read -r m; do v="$(val "k4:$m")"
        if [ "$v" = PASS ]; then ok "k4:$m"; elif [ -z "$v" ]; then miss "k4:$m: no result in status.tsv"; else fail "k4:$m: $v"; fi
      done < <(rows "$S/spec-mutants.tsv") ;;
    claims)
      cl="$P/claims-3b.tsv"; [ -f "$cl" ] || { miss "claims: $cl"; continue; }
      [ -n "${PILOT_3B_CLAIMS:-}" ] || { miss "claims: the profile names no required claims (PILOT_3B_CLAIMS)"; continue; }
      for c in $PILOT_3B_CLAIMS; do
        rows "$cl" | grep -qx "$c" || { miss "claim $c: not in claims-3b.tsv"; continue; }
        out="$(bash "$TPL/scripts/claim-verdict.sh" "$cl" "$st" "$c" bounded 2>&1 | head -1)"
        case "$out" in PASS*) ok "claim $out" ;; *) fail "claim $c: $out" ;; esac
      done ;;
    *) echo "PILOT unknown 3b requirement in the profile: $item"; exit 2 ;;
  esac
done
# Kani: on its own line; ABSTAIN unless a proof finished and every Kani canary failed for its reason
kv=ABSTAIN; kw="no Kani result saved (spec-kani not run: PILOT_KANI=${PILOT_KANI:-abstain}, see spec-kani/README.md)"
if [ -f "$W/kani/kani-results.tsv" ]; then
  if awk -F'\t' 'NR > 1 {n++; if ($2 != "PASS") f++} END {exit !(n > 0 && f == 0)}' "$W/kani/kani-results.tsv" &&
     awk -F'\t' 'NR > 1 && NF {n++; if ($2 != "PASS") f++} END {exit !(n > 0 && f == 0)}' "$W/kani-canaries/kani-canaries.tsv" 2>/dev/null
  then kv=PASS; kw="every harness proved, every Kani canary caught"
  else kw="no finished proof: $(grep -m1 -E '^KANI (FAIL|ERROR)' "$W/kani.log" 2>/dev/null | cut -c1-120)"; fi
fi
if [ "${PILOT_KANI:-abstain}" = required ] && [ "$kv" != PASS ]; then fail "kani (required by the profile): $kw"; fi
if [ "$bad" -eq 0 ]; then echo "PILOT 3b PASS"; r=0; else echo "PILOT 3b FAIL: $bad requirement(s) not met"; r=1; fi
echo "PILOT Kani $kv: $kw"
exit "$r"
