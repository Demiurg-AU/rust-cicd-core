#!/usr/bin/env bash
# evidence-predicate.sh <evidence-dir> <run-url>
# Prints an in-toto test-result v0.1 predicate (https://in-toto.io/attestation/test-result/v0.1)
# for a SEALED evidence directory. Refuses unsealed, tampered or empty evidence: a signature over
# unverified bytes would only make a forgery look official.
set -euo pipefail
ev="${1:?evidence dir}" url="${2:?run url}"
[ -f "$ev/results.tsv" ] && [ -f "$ev/SHA256SUMS" ] || { echo "EVIDENCE incomplete: $ev" >&2; exit 1; }
( cd "$ev" && sha256sum -c --quiet --strict SHA256SUMS ) > /dev/null 2>&1 || { echo "EVIDENCE checksum mismatch: $ev" >&2; exit 1; }
grep -Eq '[ *](\./)?results\.tsv$' "$ev/SHA256SUMS" || { echo "EVIDENCE results not sealed: $ev" >&2; exit 1; }
rd=$(sha256sum "$ev/results.tsv" | cut -c1-64)
sd=$(sha256sum "$ev/SHA256SUMS" | cut -c1-64)
awk -F'\t' -v url="$url" -v rd="$rd" -v sd="$sd" '
  NR == 1 { next }
  NF >= 6 { n++; t = "\"" $1 "\""; if ($6 == "PASS") p = p (p ? "," : "") t; else f = f (f ? "," : "") t }
  END {
    if (!n) { print "EVIDENCE has no gate rows" > "/dev/stderr"; exit 1 }
    printf "{\"result\":\"%s\",\"configuration\":[{\"name\":\"results.tsv\",\"digest\":{\"sha256\":\"%s\"}},{\"name\":\"SHA256SUMS\",\"digest\":{\"sha256\":\"%s\"}}],\"url\":\"%s\",\"passedTests\":[%s],\"warnedTests\":[],\"failedTests\":[%s]}\n", (f == "" ? "PASSED" : "FAILED"), rd, sd, url, p, f
  }' "$ev/results.tsv"
