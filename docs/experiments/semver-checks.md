# Experiment E-2: cargo-semver-checks on a library

Pre-registered 2026-11-26 before any run. ROADMAP task: tool experiment.

## Existing equivalent in the template

None: `scripts/release-source-check.sh` checks only that a release ref is a strict `vX.Y.Z` tag; no gate
compares the public API with a released version (searched `scripts/`, `.github/`, `docs/`, registries).

## Subject

- Tool: cargo-semver-checks 0.51.0 (crates.io, `cargo install --locked`, built in 7 min 11 s on the 2-vCPU VM).
- Crate: humantime `76af473` (version 2.4.0) as the released baseline: `cargo semver-checks --baseline-rev 76af473`.
- Template: main `4aca02d`, `scripts/pilot.sh <pilot> 3a`, as in E-1. Baseline CI as in E-1.

## Cases and expected results

| Id | Change (one commit on `76af473`, version stays 2.4.0) | Baseline CI | Template 3a | cargo-semver-checks |
|---|---|---|---|---|
| S1 | compatible: new `pub fn format_rfc3339_secs_only` (alias of `format_rfc3339_seconds`) with a test | PASS | PASS | PASS (additive; a minor bump is advisable but not required by the default lints) |
| S2 | breaking: `pub fn format_rfc3339_micros` and its re-export removed, with the tests that used it | PASS | PASS (expected miss: no gate compares the API) | FAIL `function_missing` (major bump required) |

Acceptance for adoption: S2 caught by the tool and missed by every existing gate, S1 not blocked, cost of a run
small against the 3a run. Rejection: S2 already caught by an existing gate, or S1 falsely blocked.

## Results

(filled in after the runs)
