# Experiment E-4: a second external crate of another structure

Pre-registered 2026-11-26 before any run. ROADMAP plan improvement 4 (portability after the four criteria).

## Subject

- Crate: `dtolnay/semver` at `280ebcb6edac3aa4cdc545dbff8a26c5ac4861fe` (2026-06-23). Structure unlike humantime:
  `build.rs` that runs `rustc --version` and emits a `rustc-check-cfg`; features (`std` default, optional `serde`
  through `serde_core`); 49 `unsafe` occurrences (43 in `identifier.rs`, a packed-pointer representation); a large
  dev-dependency tree (`criterion`); integration tests with shared modules; its own `fuzz/`.
- Template: main `4aca02d`, `scripts/pilot.sh pilots/semver 3a`, configuration only (pilot.env, overlay lockfile and
  cargo-vet store); no spec pack (3b not attempted).

## Expected 3a verdicts (registered)

| Gate | Expected | Why |
|---|---|---|
| S1i no-unsafe-code | FAIL | `unsafe` is part of the design, not a defect |
| S1e no-panic-lints | FAIL | indexing and arithmetic in a parser, unchecked by design |
| S1g no-judge-forks | PASS | no `cfg(test)`/`debug_assertions` branches found in `src/` by grep |
| S1d mutation | UNDERDETERMINED | large test suite; not predicted |
| S2a/S2b/S2c | PASS after configuration | dev-dependency tree needs cargo-vet exemptions (configuration) |
| everything else | PASS | — |

Measured: time to connect (configuration written by hand), size of the configuration, core changes needed, and
the verdict of every gate not PASS with its reason.

## Results

(filled in after the run)
