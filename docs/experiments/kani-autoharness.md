# Experiment E-5: Kani autoharness vs the hand-written harness

Pre-registered 2026-11-26 before any run. ROADMAP plan improvement 5.

## Subject

Kani 0.68.0 (CBMC 6.11.0), `cargo kani autoharness` (experimental). Function: the template's
`checked_add(a: u32, b: u32) -> Option<u32>` (`src/lib.rs`), hand-written harness
`kani_proofs::kani_checked_add_matches_spec` (functional spec, two covers). Main `bd8454a`, scratch copy.

## Cases and expected results

| Case | Code | Hand harness | Autoharness |
|---|---|---|---|
| A0 | unchanged | PASS (2/2 covers) | PASS (no panic / UB for any input) |
| A1 | KC1: `Some(a.wrapping_add(b))` — wrong result, no panic | FAIL (spec violated) | **PASS — expected miss**: it checks only runtime errors, not the result |
| A2 | `Some(a + b)` — arithmetic overflow | FAIL | FAIL (overflow check) |

Measured: verdict, wall time, peak memory (`/usr/bin/time -v`). Fitness criterion (from the ROADMAP plan): the approach
is useful only if its property is meaningful and it detects a known control bug; A2 is that control for the panic
class, A1 shows what it cannot express.

## Results

(filled in after the runs)
