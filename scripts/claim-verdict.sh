#!/usr/bin/env bash
# claim-verdict.sh <claims.tsv> <status.tsv> <claim-id> <any|bounded> [assumptions.tsv]
# Does the claim hold for the requested domain?
#   FAIL     some evidence for the claim failed
#   ABSTAIN  claim unknown, evidence missing, or its scope does not cover the request
#   PASS     every evidence item passed AND the scope covers the request
# status.tsv: "<evidence-id>\t<verdict>" lines. Only PASS passes; ANY other recorded verdict
# (FAIL, FAIL_WRONG_REASON, FAIL_GATE_DID_NOT_FIRE, ...) is FAIL; only an absent row is ABSTAIN.
set -uo pipefail
[ $# -eq 4 ] || [ $# -eq 5 ] || { echo "usage: claim-verdict.sh <claims.tsv> <status.tsv> <claim-id> <any|bounded> [assumptions.tsv]"; exit 2; }
claims="$1" status="$2" id="$3" want="$4" assumptions="${5:-}"
[[ "$want" = any || "$want" = bounded ]] || { echo "VERDICT bad request: $want"; exit 2; }
row="$(awk -F'\t' -v id="$id" '!/^#/ && $1==id' "$claims")"
[ -n "$row" ] || { echo "ABSTAIN $id: no such claim"; exit 0; }
[ "$(grep -c '' <<< "$row")" -eq 1 ] || { echo "VERDICT duplicate claim: $id"; exit 2; }
IFS=$'\t' read -r _ _ scope bounds evidence <<< "$row"
[[ "$scope" = code || "$scope" = model || "$scope" = bounded ]] || { echo "VERDICT bad scope for $id: $scope"; exit 2; }
[ -n "$evidence" ] || { echo "ABSTAIN $id: no evidence listed"; exit 0; }
missing=""
IFS=',' read -ra items <<< "$evidence"
for e in "${items[@]}"; do
  v="$(awk -F'\t' -v e="$e" '$1==e {print $2}' "$status" | tail -1)"
  case "$v" in
    PASS) ;;
    "") missing="$missing $e" ;;
    *) echo "FAIL $id: evidence $e failed ($v)"; exit 0 ;;
  esac
done
[ -z "$missing" ] || { echo "ABSTAIN $id: evidence not run:$missing"; exit 0; }
# Assumption Breaker Gate (ROADMAP O4a): a claim states its assumptions; each is either broken on purpose by a
# CANARY (breaker:gate:<id> with expect=fail, or breaker:kcanary:<id>) that must have fired for its reason, or
# declared trusted:<reason> and then printed with every PASS. No assumption listed -> ABSTAIN.
trusting="" bmissing=""
if [ -n "$assumptions" ]; then
  arows="$(awk -F'\t' -v id="$id" '!/^#/ && $1==id' "$assumptions")"
  [ -n "$arows" ] || { echo "ABSTAIN $id: no assumptions declared (Assumption Breaker Gate)"; exit 0; }
  while IFS=$'\t' read -r _ aid _ breaker; do
    case "$breaker" in
      trusted:?*) trusting="$trusting $aid (${breaker#trusted:});" ;;
      gate:?*|kcanary:?*)
        line="$(awk -F'\t' -v e="$breaker" '$1==e' "$status" | tail -1)"
        v="$(cut -f2 <<< "$line")"; ex="$(cut -f3 <<< "$line")"
        [ -n "$line" ] || { bmissing="$bmissing $breaker($aid)"; continue; }
        [[ "$breaker" == gate:* && "$ex" != fail ]] && { echo "VERDICT breaker $breaker for $aid is not a canary (expect=$ex)"; exit 2; }
        [ "$v" = PASS ] || { echo "FAIL $id: breaker $breaker for $aid did not fire for its reason ($v)"; exit 0; } ;;
      *) echo "VERDICT bad breaker for $id/$aid: '$breaker' (gate:<canary> | kcanary:<id> | trusted:<reason>)"; exit 2 ;;
    esac
  done <<< "$arows"
  # missing breakers are reported only after every present one was checked: a known failure must not hide behind ABSTAIN
  [ -z "$bmissing" ] || { echo "ABSTAIN $id: breaker not run:$bmissing"; exit 0; }
  # at least one assumption must actually be broken by a canary: a claim resting only on trusted: lines has no
  # demonstrated way to fail
  awk -F'\t' '$4 !~ /^trusted:/' <<< "$arows" | grep -q . || { echo "ABSTAIN $id: every assumption is trusted - none is broken by a canary"; exit 0; }
fi
if [ "$want" = any ] && [ "$scope" != code ]; then
  echo "ABSTAIN $id: proved only as $scope ($bounds); not for every input on the Rust code"; exit 0
fi
# scope=code is not taken on the claim's word: every evidence item must be of a kind that speaks for EVERY input
# of the Rust code (a Kani proof, the no-panic lint gate and its canary). Tests, coverage, mutants, Lean models
# cannot carry an any-input PASS, whatever claims.tsv says.
UNIVERSAL='^(kani:.+|gate:S1e|gate:C26|gate:C33)$'
if [ "$want" = any ]; then
  IFS=',' read -ra ev <<< "$evidence"
  for e in "${ev[@]}"; do [[ "$e" =~ $UNIVERSAL ]] || { echo "ABSTAIN $id: evidence $e does not speak for every input (scope=code needs Kani or the no-panic lint gate)"; exit 0; }; done
fi
echo "PASS $id ($scope: $bounds)${trusting:+; trusting:${trusting%;}}"
