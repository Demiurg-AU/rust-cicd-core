# Experiment E-3: a fuzz finding becomes a regression test

2026-11-26, ROADMAP plan improvement 2. Crate humantime `76af473`, pilot spec `pilots/humantime/spec/fuzz`,
nightly-2026-11-15, cargo-fuzz 0.13.2; 2-vCPU VM. Known safe bug: canary HF1 (one hour = 3601 s), planted in a scratch
copy only.

| Step | Command | Result | Wall |
|---|---|---|---|
| build target | `cargo fuzz build -O duration_roundtrip` | built | 58 s |
| find | `cargo fuzz run -O duration_roundtrip -- -max_total_time=300` | crash, `FUZZ-ORACLE roundtrip 590766370586.294967051s -> "18720years 3months 2days 9h …"`, artifact `crash-4723bb578ed66904dd37539e0e22383124bc564c` | 1.1 s |
| replay | `cargo fuzz run -O duration_roundtrip artifacts/duration_roundtrip/crash-4723bb57…` | same assertion, same value (deterministic) | 0.5 s |
| minimize | `cargo fuzz tmin …` | no smaller file written (the input is two integers; nothing to shrink) | 0.6 s |
| regression test | the target's oracle on the printed value, as a stable `#[test]` in `tests/behavior.rs` (below) | with HF1: FAILED, `left: Ok(590766370595.294967051s) right: Ok(590766370586.294967051s)`; without HF1: ok | 0.00 s test, 0.24 s with cargo |

```rust
#[test]
fn fuzz_regression_duration_roundtrip_590766370586s() {
    // Found by fuzz target duration_roundtrip (artifact crash-4723bb57…) while canary HF1 was planted.
    let d = StdDuration::new(590_766_370_586, 294_967_051);
    assert_eq!(parse_duration(&format_duration(d).to_string()), Ok(d));
}
```

**Result.** The path from a saved input to a test that fails before the fix and passes after takes one replay and
one test; the test then runs in every PR inside the existing gates (S1c, S1d, S1f) at no measurable cost, while a
PR fuzz session costs 60 s CPU per target plus the build. Two mistakes of this run, for the record: a replay
command without the artifact path silently started a new fuzzing session (it found a second crash); `tmin` wrote
nothing for a two-integer input.

**Decision.** No budget change (none was measured as needed). Procedure for the template: every fuzz crash is
replayed from its artifact, then its oracle is written as a plain test with the printed input and the crash's id in a
comment; the corpus keeps the artifact. The test was not added to the pilot crate: it would change `CRATE_SHA`
and require a new acceptance run for no new information.
