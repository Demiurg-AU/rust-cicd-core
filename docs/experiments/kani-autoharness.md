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

## Results (2026-11-26, 14:36-14:50 UTC)

Template function `checked_add`, `cargo kani --harness …` vs `cargo kani autoharness -Z autoharness
--include-pattern checked_add` (the autoharness run also re-runs the hand harness; its own verdict is the
"Autoharness Summary" row).

| Case | Hand harness | Autoharness (own row) | Wall / peak RSS (auto) |
|---|---|---|---|
| A0 unchanged | PASS (17 s incl. build, 122 MB) | Success | 0.5 s / 126 MB |
| A1 `wrapping_add` | FAIL `assertion failed: wide <= … && u64::from(s) == wide` | **Success — missed, as registered** | 0.4 s / 125 MB |
| A2 `a + b` | FAIL | **Failure** `attempt to add with overflow` | 0.5 s / 125 MB |

**Where the hand harness ran out of memory (humantime, CBMC OOM at 7 GB on the string parsers):**

| Run (humantime `76af473`) | Result | Wall / peak RSS |
|---|---|---|
| autoharness on `two_digits`, `days_since_epoch`, `civil_from_unix`, `is_leap_year` | 4/4 Success: no panic or UB for **every** input of these helpers | 5.3 s / 239 MB |
| control: `days_since_epoch` with `year - 1970` instead of `checked_sub` | Failure `attempt to subtract with overflow` | 1.1 s / 152 MB |
| `parse_rfc3339_weak`, `parse_duration` (`&str`) | skipped: `Requires --bounded-arguments` | — |
| `--bounded-arguments` on `parse_duration` | **"Failure" = `CBMC timed out`** (default 60 s, unwind 20), not a finding | 63 s / 1.36 GB |

**Verdict.** Useful, in a narrow role: unbounded no-panic / no-UB proofs for small functions with numeric or
fixed-size arguments, seconds and a few hundred MB each, catching the panic-class control in both crates. It cannot
state a functional property (A1 passed) and checks each function without its callers' preconditions: the control
above is unreachable in the crate (its caller rejects years before 1970), so on code that relies on such
preconditions it raises false alarms unless function contracts are written. For the `&str` parsers it gives at
most a bounded result, and there it timed out; Kani for humantime stays **ABSTAIN**. A gate using it must map a
timeout to ABSTAIN, not FAIL — the tool reports both as "Failure".

Not adopted as a gate in this round: no claim of the pilots is about the helper functions alone. Candidate for a
later profile: "autoharness no-panic for numeric helpers", with timeouts as ABSTAIN and a planted control like the
one above.
