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

## Results (runs 2026-11-26 11:44-13:14 UTC)

Template main `4aca02d`, live policy (T3 MATCH). Variant commits in a local clone of the crate repository; commit
ids below. "Wall" = seconds; "CPU" = CPU-seconds of the whole VM over the run (`/proc/stat`), nothing else running.

| Id | Variant commit | Baseline | Wall / CPU | Template 3a (first gates not PASS) | Wall / CPU | vs pre-registration |
|---|---|---|---|---|---|---|
| R0 | `76af473` | PASS | 50 / 59 | PASS 146/146 | 499 / 781 | as expected; no false block on either side |
| R1 | `77a7823` | caught: fmt | 0 / 0 | caught: S1a fmt | 489 / 768 | as expected |
| R2 | `6d6c58c` | caught: clippy | 4 / 7 | caught: S1b clippy (S1e repeats it) | 501 / 788 | as expected |
| R3 | `e87ee63` | caught: test | 11 / 19 | caught: S1c, S1f `week_month_year_lengths` | 144 / 233 | as expected; 5 canaries report FAIL_WRONG_REASON because the tests are red |
| R4 | `855269e` | **missed** | 45 / 53 | caught: S1d `MISSED src/date.rs:43:9` (Display of Error) | 485 / 738 | as expected |
| R5 | `dc6f163` | **missed** | 41 / 49 | caught: S1e `expect_used` | 503 / 792 | as expected |
| R6 | `4e975a7` | **missed** | 48 / 57 | caught: S2a deny (RUSTSEC-2026-0543) | 530 / 833 | as expected |
| R7 | `e812b8d` | caught: clippy (compile error) | 4 / 7 | caught: S0a build | 122 / 197 | **registration error**: the crate has `#![forbid(unsafe_code)]`, so R7 does not reach S1i; excluded from scoring |
| R7b | `b3ccc03` | **missed** | 53 / 60 | caught: S1i no-unsafe-code | 511 / 784 | as expected (registered after R7) |
| R8 | `be42dd2` | **missed** | 45 / 53 | caught: S1g no-judge-forks, S1f | 525 / 823 | as expected |
| R9 | `c92cfb6` | **missed** | 43 / 52 | caught (indirect): S1d `MISSED src/date.rs:172:43: replace > with >=` - the changed comparison has no boundary test | 512 / 807 | **better than registered** (3a expected to miss). The gate names the untested changed line, not the accepted minute 60 |

**Scored sample: 9 regressions** (R1-R6, R7b, R8, R9). Baseline caught 3 (R1-R3), missed 6. Template 3a caught 9
(R9 indirectly). False blocks on the clean control: 0 for both. 3b was not run for R9 (deviation: 3a already
blocked it); the fuzz oracle's blind spot for wrongly accepted inputs is examined in the tool experiment instead.

**Cost.** On this VM the template's 3a takes about 8.5 min wall and 13x the baseline's CPU on a clean change
(499 s vs 50 s; 781 vs 59 CPU-s). It does not stop at the first failure: R1 (a formatting error the baseline reports
in 0.05 s) still costs the full run. On GitHub the template's own PR CI costs 28.7 runner-minutes without fuzzing
(PR #67, final attempts: core 303 s, base judge 301 s, lean-rich 353 s, kani 273 s, spec epoch 277 s, codeql
176 s, rest under 15 s each) plus 434 s for `fuzz`; a baseline job was not measured on GitHub.

**Scope of the conclusion.** One crate (humantime, a small pure-Rust library with no runtime dependencies), one
VM, one run per variant, a sample designed by the template's author. The template's extra catches come from gates
that target exactly these regression classes (mutation, panic lints, advisories, unsafe, judge forks); the sample
says nothing about regression classes outside it.

Raw lines: `/root/e1/<id>.{base,tmpl}.txt` in the agent workspace (evidence package below).
