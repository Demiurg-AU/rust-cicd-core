#!/usr/bin/env bash
# evidence-verdict.sh <results>
# <results> = the comma-joined, de-duplicated predicate.result values of every attestation that
# verified (signer = ci.yml on main, source = the released commit). Only an unanimous PASSED releases.
set -euo pipefail
r="${1-}"
[ -n "$r" ] || { echo "EVIDENCE no attestation"; exit 1; }
[ "$r" = PASSED ] || { echo "EVIDENCE result not PASSED: $r"; exit 1; }
echo "EVIDENCE verified: PASSED"
