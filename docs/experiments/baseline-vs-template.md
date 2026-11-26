# Experiment E-1: baseline Rust CI vs the template on one pinned crate

Pre-registered 2026-11-26 before any run (this file's commit time is the registration time). ROADMAP plan,
improvement 1.

## Subject and conditions

- Crate: humantime `76af4738e7ddbab884b68c46ee82a0810adc3506` (the accepted pilot crate). Every variant is one
  commit on top of it; R0 is that commit itself.
- Template: `rust-cicd-core` main `4aca02d`, `scripts/pilot.sh pilots/<variant> 3a` (core gates S0-S2, T1-T3 on the
  crate), with the humantime pilot configuration (overlay, spec) unchanged except `CRATE_URL`/`CRATE_SHA`; for R6
  the overlay lockfile gains the added dependency (configuration). 3b only where named below.
- Baseline: the common minimal Rust CI, same toolchain (1.100.0), same lockfile:
  `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test --all-targets && cargo test --doc`.
- Machine: one cloud VM, 2 vCPU, 7 GB. Cargo registry warm for both; `target/` fresh for every run of both
  variants. Cost = wall clock and CPU seconds (`/usr/bin/time`) of each run on this VM — local minutes, not GitHub
  runner minutes.
- A variant is "caught" when the run exits non-zero and the first failing gate names the regression; a non-zero
  exit for another reason is a false block (and on R0 any non-zero exit is a false block).

## Sample and expected results

| Id | Regression (planted) | Baseline expected | Template 3a expected (gate) |
|---|---|---|---|
| R0 | none (clean control) | PASS | PASS |
| R1 | formatting violation in `src/lib.rs` | caught (fmt) | caught (S1a) |
| R2 | clippy warning (`needless_return`) in `src/duration.rs` | caught (clippy) | caught (S1b) |
| R3 | week = 604 801 s instead of 604 800 (covered by a test) | caught (test) | caught (S0a/S1c tests) |
| R4 | `tests/behavior.rs` deleted (test removal, no code change) | missed | caught (S1d surviving mutants) |
| R5 | new panic path: an `.expect()` in library code on a branch no test reaches | missed | caught (S1e expect_used) |
| R6 | unmaintained dependency re-added (`chrono` dev-dependency, RUSTSEC-2026-0543) | missed | caught (S2a) |
| R7 | `unsafe` block (`get_unchecked`) with unchanged behaviour | missed | caught (S1i) |
| R8 | judge-vs-ship fork: leap-second handling only under `cfg!(debug_assertions)` | missed | caught (S1g; S1f) |
| R9 | `parse_rfc3339` accepts minute 60 (no test, round-trip-consistent) | missed | missed (3a); 3b also expected to miss: `rfc3339_shape` checks only the round trip |

| R7b | (added 2026-11-26 after R7, see Results) `#![forbid(unsafe_code)]` removed from `src/lib.rs` and the R7 `unsafe` block added | caught (clippy default: no; build passes) - expected **missed** | caught (S1i) |

R9 is included to measure a known blind spot, not to be caught. 3b is run for R9 only (R0's 3b result is the
acceptance run on the same crate SHA: 18/18).

## Results

(filled in after the runs; raw lines and commands in the evidence package)
