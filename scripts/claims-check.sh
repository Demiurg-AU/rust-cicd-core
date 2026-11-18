#!/usr/bin/env bash
# claims-check.sh <claims.tsv> <evidence-dir> <kani-results.tsv> <out-dir>
# Builds the evidence status, runs the verdict canaries, then answers every claim for "any" and
# "bounded". Exit 1 if a canary fails or any claim is FAIL; ABSTAIN is reported, not failed.
set -uo pipefail
claims="$1" ev="$2" kani="$3" out="$4"; SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$out"; st="$out/status.tsv"; : > "$st"
res="$(find "$ev" -name results.tsv | head -1)"; [ -n "$res" ] || { echo "CLAIMS no results.tsv under $ev"; exit 2; }
awk -F'\t' 'NR>1 {print "gate:" $1 "\t" $6}' "$res" >> "$st"
[ -f "$kani" ] && awk -F'\t' 'NR>1 {print "kani:" $1 "\t" $2}' "$kani" >> "$st"
# canaries: every verdict must be reachable, for the right reason
c="$out/canary"; mkdir -p "$c"
printf 'X\tp\tcode\tall\tkani:a\nY\tp\tbounded\tsmall\tkani:a\nZ\tp\tcode\tall\tkani:b\nW\tp\tcode\tall\tkani:missing\nM\tp\tmodel\tlean\tkani:a\nV\tp\tbounded\tsmall\tgate:C5\n' > "$c/claims.tsv"
printf 'kani:a\tPASS\nkani:b\tFAIL\ngate:C5\tFAIL_GATE_DID_NOT_FIRE\n' > "$c/status.tsv"
rc=0
check() { local o; o="$(bash "$SD/claim-verdict.sh" "$c/claims.tsv" "$c/status.tsv" "$1" "$2")"
  [[ "$o" == "$3"* ]] && echo "CLAIM canary $1/$2 -> $3" || { echo "CLAIM canary $1/$2: got '$o', want $3"; rc=1; }; }
check X any PASS; check Y any ABSTAIN; check Y bounded PASS; check Z any FAIL; check W any ABSTAIN; check M any ABSTAIN; check NOPE any ABSTAIN; check V bounded FAIL
printf 'claim\tany input on the Rust code\twithin stated bounds\n' > "$out/verdicts.tsv"
for id in $(awk -F'\t' '!/^#/ && NF {print $1}' "$claims"); do
  a="$(bash "$SD/claim-verdict.sh" "$claims" "$st" "$id" any)"; b="$(bash "$SD/claim-verdict.sh" "$claims" "$st" "$id" bounded)"
  echo "$a"; echo "$b"; printf '%s\t%s\t%s\n' "$id" "${a%% *}" "${b%% *}" >> "$out/verdicts.tsv"
  [[ "$a" == FAIL* || "$b" == FAIL* ]] && rc=1
done
exit "$rc"
