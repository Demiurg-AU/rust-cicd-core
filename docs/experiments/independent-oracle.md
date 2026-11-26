# Experiment E-6: an independent oracle for the parsers (proptest or the existing fuzz path)

Pre-registered 2026-11-26 before any run. ROADMAP task: evaluate proptest or a better-fitting tool for a concrete gap.

## The gap

Every fuzz target of the humantime pilot checks the parser against the formatter (`fuzz-targets.tsv`: "not an
independent reference"). A parser that accepts a non-existent date keeps the round trip consistent
(`2018-04-31` → instant of `2018-05-01` → formats as `2018-05-01` → parses to the same instant), so no target can
see it. Tests cover the date table only partly, and cargo-mutants does not mutate numeric literals, so S1d is
silent too. E-1 R9 was caught only because the change touched a guarded comparison.

## Regression and candidates

- **R10**: `days_since_epoch` gives April 31 days instead of 30 (`4 => (90, 30)` → `(90, 31)`); one commit on
  humantime `76af473`.
- **D (existing mechanism)**: a cargo-fuzz target in the spec pack comparing `parse_rfc3339` with the `time` crate
  (0.3, already a dev-dependency of humantime, i.e. an independent RFC 3339 implementation) on every
  `DDDD-DD-DDTDD:DD:DDZ`: if humantime accepts, `time` must accept with the same Unix second; if `time` accepts a
  year ≥ 1970, humantime must accept. Second 60 is skipped (humantime maps a leap second to :59 by design).
- **P (new tool)**: proptest 1.11.0 (docs.rs) with the same oracle, as a stable `cargo test`.

## Expected

| Run | R0 (clean) | R10 |
|---|---|---|
| baseline CI | PASS | missed |
| template 3a | PASS | missed (no surviving mutant on a literal) |
| existing target `rfc3339_shape`, 60 s | PASS | missed (round trip consistent) |
| D, 60 s | PASS (no false alarm) | caught |

**Decision rule, fixed now:** if D catches R10 within the 60 s PR budget and raises no alarm on R0, proptest is
**rejected** for this gap — it would close the same gap with the same oracle, adding a dependency tree and a second
generator to maintain; the value is in the oracle, not the generator. If D misses R10 or raises false alarms, P
is tried with the same oracle and adopted only if it catches R10 without false alarms.

## Results

(filled in after the runs)
