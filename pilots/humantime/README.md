# Pilot: humantime (ROADMAP criterion 3, owner decision 2026-11-21: 3a and 3b)

From a clean checkout of this repository (Ubuntu; the policy fetch needs `gh` logged in):

```
if bash scripts/fetch-policy.sh Demiurg-AU/rust-cicd-core /tmp/rcc-policy; then
  EXT_RULES=/tmp/rcc-policy/rules.json EXT_RULESETS=/tmp/rcc-policy/rulesets.json \
    bash scripts/pilot.sh pilots/humantime 3b 2>&1 | tee /tmp/pilot-humantime.log
  echo "pilot exit=${PIPESTATUS[0]}"
else
  echo "policy fetch failed: online run not started"
fi
```

The last lines are the verdicts: `PILOT 3a core (ci-local): PASS|FAIL`, `PILOT 3b PASS|FAIL: ...` and
`PILOT Kani PASS|ABSTAIN: ...`; exit 0 only if 3a and 3b both PASS. The 3b verdict can be recomputed from the saved
results at any time: `bash scripts/pilot-verdict.sh pilots/humantime` (requirements come from `pilot.env`).

(`3a` instead of `3b` runs only the configuration-only stage.) Needs what the template's own run needs (rustup with
1.100.0, bubblewrap, cargo-nextest/llvm-cov/deny/audit/mutants/vet, elan for the Lean canaries) plus, for 3b,
`cargo-fuzz` and `nightly-2026-11-15` with `llvm-tools-preview`. Without `gh` access, `EXT_OFFLINE=1` skips the
live policy (T1/T3 then record it as unchecked).

| file | what it is |
|---|---|
| `pilot.env` | crate URL and pinned commit, profile (`REQUIRE_LEAN=0`: the crate has no Lean project) |
| `overlay/` | configuration only (pilot.sh refuses anything else): generated `Cargo.lock`, `cargo vet init` exemptions |
| `claims.tsv` | domain claims H1–H3 without evidence: in 3a they are ABSTAIN |
| `spec/` | 3b spec pack (verification code): 4 fuzz targets (one with an independent oracle, the `time` crate: E-6/E-7), canaries HF1–HF6, K5 coverage minimums, K4 spec mutants SM1–SM4 |
| `claims-3b.tsv` | H1–H4 as bounded claims with the spec pack's evidence |
| `spec-kani/` | Kani harness + canaries; not run by default (CBMC out of memory here, see its README) |

Canary validity on this crate: C26 (planted indexing) is **not confirmed** here, because the unmodified crate
already fails S1e with the same reason ("indexing may panic", 25 times); the other canaries whose guard fails on the
crate (C4 for S2a, C33 for S1e, C5/C6 for S1d) report reasons the unmodified crate does not produce.

`cargo vet init` exempts every dependency present at the pinned commit: S2c then means "no dependency beyond these",
not "these were audited".
