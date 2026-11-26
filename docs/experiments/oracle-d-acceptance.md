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

## Results (run 2026-11-26 17:35-18:02 UTC, 1595 s wall)

Template `95f7ddb` (this branch), crate `76af473`, live policy (`fetch-policy.sh`). Evidence:
`docs/experiments/evidence/e7/` (pilot log, `status.tsv`, `fuzz.log`, ci-local `results.tsv`, HF6 and SM4 logs).

| Item | Criterion | Result |
|---|---|---|
| pilot exit | 0 | **0** |
| 3a ci-local | PASS, 149/149 | **PASS 149/149** |
| `fuzz:rfc3339_vs_time` on the unmodified crate | PASS (no false alarm) | **PASS**, 6 464 550 runs in 60 s |
| HF6 (April has 31 days) | caught for its reason | **caught**: `FUZZ-ORACLE humantime accepts, time rejects: 4545-04-31T14:14:40Z` |
| K5 `rfc3339_vs_time` | ≥ 30 % of `date.rs` | **PASS 47.95 %** |
| K4 SM4 | HF6 escapes | **PASS**: 6 256 209 runs, HF6 not caught |
| H4 | PASS | **PASS** (bounded) |
| previous items (fuzz ×3, HF1–HF5, K5 ×3 + canary, SM1–SM3, H1–H3) | still PASS | **all PASS** |
| Kani | ABSTAIN | ABSTAIN |

**Verdict: PASS** by the criterion fixed in `30db762`. 3b now has 23 items (was 18).

### Deviations, recorded as they happened

1. **A defect in `scripts/pilot.sh` K5, found by this change.** The first measurement for the K5 threshold showed
   that `llvm-cov report` lists every file of the profile, and the `time` crate also has a `src/date.rs`, sorted
   before the crate's. The K5 awk takes the first match: on the same profile it read **8.55 %** (time's `date.rs`)
   instead of **47.95 %** (humantime's). Before this change no target linked a dependency with a clashing file name,
   so earlier K5 numbers are unaffected. Fix `6db3305`: the report is restricted to sources under the crate tree.
   That is a pipeline change (`scripts/`) and needs the owner's K1 signature.
2. **K5 threshold from a standalone measurement.** The registered rule ("below the first measurement") was applied
   to a 60 s run of D outside the pilot on the same crate commit (47.95 % → threshold 30 %); the acceptance run
   measured the same 47.95 %.
