#!/usr/bin/env bash
# claim-verdict.sh <claims.tsv> <status.tsv> <claim-id> <any|bounded>
# Does the claim hold for the requested domain?
#   FAIL     some evidence for the claim failed
#   ABSTAIN  claim unknown, evidence missing, or its scope does not cover the request
#   PASS     every evidence item passed AND the scope covers the request
# status.tsv: "<evidence-id>\t<PASS|FAIL>" lines.
set -uo pipefail
[ $# -eq 4 ] || { echo "usage: claim-verdict.sh <claims.tsv> <status.tsv> <claim-id> <any|bounded>"; exit 2; }
claims="$1" status="$2" id="$3" want="$4"
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
    FAIL) echo "FAIL $id: evidence $e failed"; exit 0 ;;
    *) missing="$missing $e" ;;
  esac
done
[ -z "$missing" ] || { echo "ABSTAIN $id: evidence not run:$missing"; exit 0; }
if [ "$want" = any ] && [ "$scope" != code ]; then
  echo "ABSTAIN $id: proved only as $scope ($bounds); not for every input on the Rust code"; exit 0
fi
echo "PASS $id ($scope: $bounds)"
