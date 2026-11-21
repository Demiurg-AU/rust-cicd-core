# Pilot: humantime (ROADMAP criterion 3, owner decision 2026-11-21: 3a and 3b)

One command from a clean checkout of this repository:

```
eval "$(bash scripts/fetch-policy.sh Demiurg-AU/rust-cicd-core /tmp/rcc-policy | sed 's/^/export /')" \
  && bash scripts/pilot.sh pilots/humantime 3b
```

(`3a` instead of `3b` runs only the configuration-only stage.) Needs what the template's own run needs (rustup with
1.100.0, bubblewrap, cargo-nextest/llvm-cov/deny/audit/mutants/vet, elan for the Lean canaries) plus, for 3b,
`cargo-fuzz` and `nightly-2026-11-15` with `llvm-tools-preview`. Without `gh` access, `EXT_OFFLINE=1` skips the
live policy (T1/T3 then record it as unchecked).

| file | what it is |
|---|---|
| `pilot.env` | crate URL and pinned commit, profile (`REQUIRE_LEAN=0`: the crate has no Lean project) |
| `overlay/` | configuration only (pilot.sh refuses anything else): generated `Cargo.lock`, `cargo vet init` exemptions |
| `claims.tsv` | domain claims H1–H3 without evidence: in 3a they are ABSTAIN |
| `spec/` | 3b spec pack (verification code): 3 fuzz targets, canaries HF1–HF5, K5 coverage minimums, K4 spec mutants |
| `claims-3b.tsv` | H1–H3 as bounded claims with the spec pack's evidence |
| `spec-kani/` | Kani harness + canaries; not run by default (CBMC out of memory here, see its README) |

`cargo vet init` exempts every dependency present at the pinned commit: S2c then means "no dependency beyond these",
not "these were audited".
