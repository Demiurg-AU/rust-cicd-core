#!/usr/bin/env bash
# claims-check.sh <claims.tsv> <evidence-dir> <kani-results.tsv> <out-dir> <assumptions.tsv> [kani-canaries.tsv]
# Builds the evidence status, runs the verdict canaries, then answers every claim for "any" and
# "bounded". Exit 1 if a canary fails or any claim is FAIL; ABSTAIN is reported, not failed.
set -uo pipefail
claims="$1" ev="$2" kani="$3" out="$4" asm="${5:?assumptions.tsv (Assumption Breaker Gate)}" kc="${6:-}"; SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$out"; st="$out/status.tsv"; : > "$st"
res="$(find "$ev" -name results.tsv | head -1)"; [ -n "$res" ] || { echo "CLAIMS no results.tsv under $ev"; exit 2; }
awk -F'\t' 'NR>1 {print "gate:" $1 "\t" $6 "\t" $3}' "$res" >> "$st"
# recorded check signatures (sealed with the results): a breaker must run its guard gate's check (#45 item 4)
[ -f "$(dirname "$res")/signatures.tsv" ] && awk -F'\t' 'NF==2 {print "sig:" $1 "\t" $2}' "$(dirname "$res")/signatures.tsv" >> "$st"
[ -f "$kani" ] && awk -F'\t' 'NR>1 {print "kani:" $1 "\t" $2}' "$kani" >> "$st"
[ -n "$kc" ] && [ -f "$kc" ] && awk -F'\t' 'NR>1 {print "kcanary:" $1 "\t" $2 "\tfail"}' "$kc" >> "$st"
# canaries: every verdict must be reachable, for the right reason
c="$out/canary"; mkdir -p "$c"
printf 'X\tp\tcode\tall\tkani:a\nY\tp\tbounded\tsmall\tkani:a\nZ\tp\tcode\tall\tkani:b\nW\tp\tcode\tall\tkani:missing\nM\tp\tmodel\tlean\tkani:a\nV\tp\tbounded\tsmall\tgate:C5\n' > "$c/claims.tsv"
printf 'kani:a\tPASS\nkani:b\tFAIL\ngate:C5\tFAIL_GATE_DID_NOT_FIRE\n' > "$c/status.tsv"
rc=0
check() { local o; o="$(bash "$SD/claim-verdict.sh" "$c/claims.tsv" "$c/status.tsv" "$1" "$2")"
  [[ "$o" == "$3"* ]] && echo "CLAIM canary $1/$2 -> $3" || { echo "CLAIM canary $1/$2: got '$o', want $3"; rc=1; }; }
# Assumption Breaker Gate canaries: no assumptions -> ABSTAIN; a breaker that did not fire -> FAIL;
# a breaker that is not a canary -> evaluator error; trusted assumptions are printed with the PASS.
printf 'X\tA1\tnon-vacuous\tgate:K1@G1\nX\tA2\tintended property\ttrusted:same author\nZ\tA1\tx\tgate:K2@G1\nY\tA1\tx\tgate:K3@G1\n' > "$c/asm.tsv"
printf 'gate:K1\tPASS\tfail\ngate:K2\tFAIL_GATE_DID_NOT_FIRE\tfail\ngate:K3\tPASS\tpass\ngate:K4\tPASS\tfail\ngate:G1\tPASS\tpass\ngate:G2\tFAIL\tpass\n' >> "$c/status.tsv"
printf 'sig:G1\taa bb\nsig:G2\taa bb\nsig:K1\taa bb cc\nsig:K2\taa bb\nsig:K3\taa bb\nsig:K4\taa zz\n' >> "$c/status.tsv"
abg() { local o r; o="$(bash "$SD/claim-verdict.sh" "$c/claims.tsv" "$c/status.tsv" "$1" "$2" "$c/asm.tsv")"; r=$?
  if [ "$r" -eq "$3" ] && [[ "$o" =~ $4 ]]; then echo "ABG canary $1/$2 -> $4"; else echo "ABG canary $1/$2: got rc=$r '$o', want rc=$3 /$4/"; rc=1; fi; }
check X any PASS; check Y any ABSTAIN; check Y bounded PASS; check Z any FAIL; check W any ABSTAIN; check M any ABSTAIN; check NOPE any ABSTAIN; check V bounded FAIL
abg X any 0 '^PASS X .*trusting: A2 \(same author\)$'; abg W any 0 '^ABSTAIN W: evidence not run'; abg M bounded 0 '^ABSTAIN M: no assumptions declared'
printf 'M\tA1\tx\tgate:K2@G1\n' >> "$c/asm.tsv"; abg M bounded 0 '^FAIL M: breaker gate:K2'
abg Y bounded 2 'is not a canary'
printf 'Z2\tp\tbounded\tsmall\tkani:a\n' >> "$c/claims.tsv"; printf 'Z2\tA1\tx\tgate:K9@G1\nZ2\tA2\tx\tgate:K2@G1\n' >> "$c/asm.tsv"
abg Z2 bounded 0 '^FAIL Z2: breaker gate:K2'   # missing K9 first, failed K2 second: FAIL, not ABSTAIN
printf 'T\tp\tbounded\tsmall\tkani:a\n' >> "$c/claims.tsv"; printf 'T\tA1\tx\ttrusted:a\nT\tA2\tx\ttrusted:b\n' >> "$c/asm.tsv"
abg T bounded 0 '^ABSTAIN T: every assumption is trusted'
printf 'U\tp\tcode\tall\tkani:a,gate:K1\n' >> "$c/claims.tsv"; printf 'U\tA1\tx\tgate:K1@G1\n' >> "$c/asm.tsv"
abg U any 0 '^ABSTAIN U: evidence gate:K1 does not speak for every input'   # scope=code on bounded evidence
# breaker link (#45 item 4): the canary must run its guard's check, the guard must pass, every gate breaker names a guard,
# a kcanary breaks only a claim with Kani evidence
printf 'R\tp\tbounded\tsmall\tkani:a\nQ\tp\tbounded\tsmall\tkani:a\nN\tp\tbounded\tsmall\tkani:a\nV2\tp\tbounded\tsmall\tgate:G1\n' >> "$c/claims.tsv"
printf 'R\tA1\tx\tgate:K4@G1\nQ\tA1\tx\tgate:K1@G2\nN\tA1\tx\tgate:K1\nV2\tA1\tx\tkcanary:K1\n' >> "$c/asm.tsv"
abg R bounded 2 'does not run the check of its guard gate:G1'
abg Q bounded 0 '^FAIL Q: guard gate:G2 of gate:K1 for A1 did not pass'
abg N bounded 2 'names no guard'
abg V2 bounded 2 'without kani: evidence'
printf 'B\tp\tcdoe\tall\tkani:a\nD\tp\tcode\tall\tkani:a\nD\tp\tcode\tall\tkani:a\n' > "$c/bad.tsv"
for id in B D; do bash "$SD/claim-verdict.sh" "$c/bad.tsv" "$c/status.tsv" "$id" any >/dev/null; r=$?
  [ "$r" -eq 2 ] && echo "CLAIM canary $id malformed -> evaluator error" || { echo "CLAIM canary $id malformed: exit $r, want 2"; rc=1; }; done
printf 'claim\tany input on the Rust code\twithin stated bounds\ttrusted assumptions (not broken by any canary)\n' > "$out/verdicts.tsv"
for id in $(awk -F'\t' '!/^#/ && NF {print $1}' "$claims"); do
  a="$(bash "$SD/claim-verdict.sh" "$claims" "$st" "$id" any "$asm")"; ra=$?
  b="$(bash "$SD/claim-verdict.sh" "$claims" "$st" "$id" bounded "$asm")"; rb=$?
  echo "$a"; echo "$b"
  # an evaluator error (bad scope, duplicate id, ...) or any answer outside PASS/FAIL/ABSTAIN fails the job
  for p in "$ra:$a" "$rb:$b"; do
    if [ "${p%%:*}" -ne 0 ] || [[ ! "${p#*:}" =~ ^(PASS|FAIL|ABSTAIN)\  ]]; then echo "CLAIMS evaluator error for $id: ${p#*:}"; rc=1; fi
  done
  tr="-"; [[ "$b" == *"; trusting: "* ]] && tr="${b##*; trusting: }"
  printf '%s\t%s\t%s\t%s\n' "$id" "${a%% *}" "${b%% *}" "$tr" >> "$out/verdicts.tsv"
  [[ "$a" == FAIL* || "$b" == FAIL* ]] && rc=1
done
exit "$rc"
