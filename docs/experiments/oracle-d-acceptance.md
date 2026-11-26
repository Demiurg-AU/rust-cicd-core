# E-7: target D in the humantime spec pack, acceptance run

Pre-registered 2026-11-26 before any change to the pilot. Closes the gap named in the ROADMAP verdict ("fuzz targets
of humantime without an independent oracle", E-6). Does not depend on CI-7.

## Change

1. `spec/fuzz/fuzz_targets/rfc3339_vs_time.rs`: target D from E-6, unchanged
   (`docs/experiments/evidence/e2-e6/rfc3339_vs_time.rs`), registered in `Cargo.toml`.
2. `time = "=0.3.55"` with feature `parsing` in the fuzz crate only (the version E-6 ran; the fuzz crate is its own
   workspace and never enters the crate's build, so 3a is unchanged).
3. `fuzz-targets.tsv`: the oracle column of every target starts with `independent:` or `not independent:`.
4. Canary **HF6** on `rfc3339_vs_time`: `src/date.rs` `4 => (90, 30),` → `4 => (90, 31),` (exactly E-6's R10);
   required reason `FUZZ-ORACLE humantime accepts, time rejects`.
5. Spec mutant **SM4**: the `(Some(_), None) => panic!(…)` arm of D becomes `(Some(_), None) => {}`; with it HF6
   must escape.
6. K5 row for `rfc3339_vs_time` on `date.rs`. Rule (same as the other rows): threshold set below the first
   measurement, at the measured value rounded down to a multiple of 10, minus 10.
7. Claim **H4** (bounded): parse_rfc3339 agreed with the `time` crate on every tried `DDDD-DD-DDTDD:DD:DDZ`
   (second 60 excluded); evidence `fuzz:rfc3339_vs_time,k5:rfc3339_vs_time,k4:SM4,k5:canary`; added to
   `PILOT_3B_CLAIMS`.

## Pass criterion (fixed now)

One acceptance run `scripts/pilot.sh pilots/humantime 3b` on template = this branch, crate `76af473`, live policy:

- pilot exit 0; `PILOT 3a core (ci-local): PASS` with the same count as the last acceptance (149/149);
- `PILOT 3b PASS` with every previous item still PASS and in addition: `fuzz:rfc3339_vs_time` PASS (no false alarm
  on the unmodified crate), HF6 caught for its reason, K5 `rfc3339_vs_time` PASS, K4 SM4 PASS (HF6 escapes), H4 PASS;
- Kani stays ABSTAIN (not part of this change).

Anything else is FAIL of this change, recorded as is. HF6's reason is the oracle line, not a panic elsewhere: a
catch with any other reason is FAIL_WRONG_REASON.

## Results

(filled in after the run)
