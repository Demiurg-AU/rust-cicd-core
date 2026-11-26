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

## Results (2026-11-26, 13:15-13:43 UTC)

Variant commits: S1 `63bdc95`, S2 `0276c8d` (S2 also drops `Precision::Micros`, the `Display` branch and the
tests that used the removed function, so that no warning or failing test reveals the removal).

| Id | Baseline CI | Template 3a | cargo-semver-checks `--baseline-rev 76af473` |
|---|---|---|---|
| R0 (no change) | — | — | PASS: 229 checks pass, 31 skip, 1.02 s |
| S1 compatible | PASS (43 s) | PASS 146/146 (535 s) | PASS: no semver update required (0.95 s) |
| S2 removed pub fn | **PASS - missed** (42 s) | **PASS 146/146 - missed** (536 s) | **FAIL** `function_missing: pub fn removed or renamed`, "semver requires new major version", exit 100 (1.00 s) |

Each tool run built the rustdoc JSON of both revisions in a fresh `target/` (0.27 s each: humantime has no
dependencies); cost grows with the crate and its dependency graph.

**Verdict: adopt** as a profile for published libraries — the registered adoption criterion holds (S2 caught only
by the new tool, S1 not blocked, cost about 1 s against 535 s for 3a). Not applicable to binaries or to crates with
`publish = false` (no downstream API contract), the template's own crate among them. Known limits of the tool
(its own documentation): no type-level checks, e.g. a changed argument type of a public function is not reported.
