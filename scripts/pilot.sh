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
# shellcheck disable=SC1091
. "$P/pilot.env"
: "${CRATE_NAME:?}" "${CRATE_URL:?}" "${CRATE_SHA:?}"
case "$STAGE" in 3a|3b) ;; *) echo "PILOT stage must be 3a or 3b"; exit 2 ;; esac
tsha="$(git -C "$TPL" rev-parse HEAD)"; tdirty="$(git -C "$TPL" status --porcelain --untracked-files=no | wc -l)"
W="$P/work/$CRATE_NAME"; rm -rf "$W"; mkdir -p "$P/work"
git clone -q "$CRATE_URL" "$W" || { echo "PILOT clone failed: $CRATE_URL"; exit 1; }
git -C "$W" checkout -q "$CRATE_SHA" || { echo "PILOT commit not found: $CRATE_SHA"; exit 1; }
[ "$(git -C "$W" rev-parse HEAD)" = "$CRATE_SHA" ] || { echo "PILOT checkout is not $CRATE_SHA"; exit 1; }
# 3a: configuration only. Anything else in overlay/ is refused, so a PASS cannot come from edited crate code.
CONFIG='^(Cargo\.lock|deny\.toml|mutants-exclusions\.tsv|supply-chain/[^/]+\.(toml|lock))$'
bad="$(cd "$P/overlay" && find . -type f | sed 's#^\./##' | grep -Ev "$CONFIG" || true)"
[ -z "$bad" ] || { echo "PILOT overlay holds non-configuration files: $bad"; exit 1; }
cp -r "$P/overlay/." "$W/"
overlay="$(git -C "$W" status --porcelain --ignored --untracked-files=all | sed 's/^/    /')"
spec=""
if [ "$STAGE" = 3b ]; then
  [ -d "$P/spec" ] || { echo "PILOT stage 3b needs a spec pack: $P/spec"; exit 1; }
  cp -r "$P/spec/." "$W/"
  spec="$(cd "$P/spec" && find . -type f | sed 's#^\./#    #' | sort)"
fi
mkdir -p "$W/scripts" && cp "$TPL"/scripts/*.sh "$W/scripts/"
echo "PILOT $CRATE_NAME stage $STAGE"
echo "  template: $tsha$([ "$tdirty" -gt 0 ] && echo " (+$tdirty uncommitted tracked changes)")"
echo "  crate:    $CRATE_URL @ $CRATE_SHA"
echo "  overlay (configuration):"; printf '%s\n' "$overlay"
[ -n "$spec" ] && { echo "  spec pack (verification code, 3b):"; printf '%s\n' "$spec"; }
log="$P/work/ci-local.log"
( cd "$W" && REQUIRE_LEAN="${REQUIRE_LEAN:-1}" bash scripts/ci-local.sh ) > "$log" 2>&1; rc=$?
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
    ( cd "$W" && bash scripts/fuzz-gate.sh canary . "$P/work/fuzz-canaries" && bash scripts/fuzz-gate.sh run . "$P/work/fuzz-run" ) > "$P/work/fuzz.log" 2>&1
    r=$?; echo "  fuzz-gate (canaries + run, exit $r): $(grep -E '^FUZZ' "$P/work/fuzz.log" | tail -3 | tr '\n' ' ')"
    printf 'fuzz:all\t%s\n' "$([ $r -eq 0 ] && echo PASS || echo FAIL)" >> "$st"; [ $r -eq 0 ] || s3b=1
  fi
  if [ -f "$W/kani-harnesses.tsv" ]; then
    ( cd "$W" && bash scripts/kani-gate.sh run . "$P/work/kani" && bash scripts/kani-gate.sh canary . "$P/work/kani-canaries" ) > "$P/work/kani.log" 2>&1
    r=$?; echo "  kani-gate (run + canaries, exit $r): $(grep -E '^KANI' "$P/work/kani.log" | tail -3 | tr '\n' ' ')"
    [ -f "$P/work/kani/kani-results.tsv" ] && awk -F'\t' 'NR>1 {print "kani:" $1 "\t" $2}' "$P/work/kani/kani-results.tsv" >> "$st"
    [ $r -eq 0 ] || s3b=1
  fi
fi
if [ -f "$P/claims.tsv" ]; then
  echo "  domain claims (claim-verdict, request: bounded):"
  awk -F'\t' '!/^#/ && NF {print $1}' "$P/claims.tsv" | while read -r c; do
    echo "    $(bash "$TPL/scripts/claim-verdict.sh" "$P/claims.tsv" "$st" "$c" bounded 2>&1 | head -1)"; done
fi
echo "  evidence: $ev"
echo "  log:      $log"
[ "$rc" -eq 0 ] && [ "$s3b" -eq 0 ] && { echo "PILOT $STAGE PASS"; exit 0; }
echo "PILOT $STAGE FAIL"; exit 1
