# Experiment E-8: parallel mutation testing (cargo-mutants --jobs) for S1d

Pre-registered 2026-11-27 before any run (this file's commit time is the registration time). Engineering program
v1.0, P1 (cost of each stage).

## Problem

Measured from the log mtimes of the clean-user Quick Start run on tag `v0.3.0` (humantime, 4 vCPU, 152 checks):
S1d mutation testing took 179 s of 288 s (62 %); the next stage is S0a build (14 s); the 109 canaries together 67 s.
`mutants_gate` in `scripts/ci-local.sh` runs `cargo mutants` without `--jobs`: one mutant at a time.

Contradiction (TRIZ): the gate must test every mutant (no sampling, no `--in-diff` for the verdict), but the run must
be cheaper. Resolution to test: the same mutants and the same per-mutant outcomes, in parallel.

## Subject and conditions

- Crate: humantime `76af4738e7ddbab884b68c46ee82a0810adc3506` with the pilot overlay (`pilots/humantime/overlay`),
  and the same crate with E-1 variant R4 applied (`docs/experiments/evidence/variants/R4.patch`).
- Tool: cargo-mutants 27.1.0, `--test-tool nextest --no-shuffle` (as in `mutants_gate`), Rust 1.100.0.
- Machine: the agent's cloud container, 4 vCPU, 15 GB. Target dir fresh for every run; cargo registry warm.
- Variants: `--jobs 1` (current), `--jobs 2`, `--jobs 3`. One run each, in that order, for each crate.
- Measured: wall time (`/usr/bin/time`), CPU s, peak RSS; the per-mutant outcome sets (`caught.txt`, `missed.txt`,
  `unviable.txt`, `timeout.txt`).

## Acceptance (decided before the runs)

Adopt `--jobs N` in `mutants_gate` only if, for the chosen N, on both crates:
1. the outcome sets are identical to `--jobs 1` (every mutant in the same file), except for a mutant that is
   already unstable at `--jobs 1` (e.g. `src/date.rs:311:16`, seen caught and missed in v0.3.0 runs); any such
   difference is listed;
2. no TIMEOUT appears;
3. wall time is at least 30 % lower than `--jobs 1`.

Otherwise reject, and record why. N is then chosen for a machine size by a rule stated in the change (not a guess).
The result says nothing about other crates or machine sizes.

## Result (2026-11-27, runs after the registration commit `fd6c264`)

Raw outputs: `evidence/e8/` (`summary.txt`, per run `<crate>-j<N>/`; checksums in `evidence/SHA256SUMS`).

| Crate | `--jobs` | Wall | CPU (user+sys) | Peak RSS | Outcome |
|---|---|---|---|---|---|
| humantime | 1 | 179.7 s | 216 + 93 s | 396 MB | 304 caught, 16 unviable, 0 missed |
| humantime | 2 | 108.8 s (−39 %) | 224 + 87 s | 396 MB | identical sets |
| humantime | 3 | 89.8 s (−50 %) | 232 + 80 s | 396 MB | identical sets |
| R4 | 1 | 176.8 s | 196 + 76 s | 396 MB | 288 caught, 16 missed, 16 unviable |
| R4 | 2 | 98.1 s (−45 %) | 198 + 69 s | 396 MB | identical except `src/date.rs:311:16` (missed at 1, caught at 2) |
| R4 | 3 | 80.6 s (−54 %) | 204 + 65 s | 397 MB | identical except `src/date.rs:311:16` (missed at 1, caught at 3) |

No TIMEOUT in any run. The only difference is the mutant named in criterion 1 as already unstable (it was caught in
one v0.3.0 gate run and missed in another, both at `--jobs 1`). CPU total stays within 3 %, so the saving is idle
cores, not less work.

**Decision: adopt.** All three criteria hold for N = 2 and N = 3 on both crates. Rule in `mutants_gate`
(`scripts/ci-local.sh`): `nproc − 1`, clamped to the measured 1…3; `RCC_MUTANTS_JOBS` overrides; the value is
printed as `MUTANTS jobs=N` at the top of the S1d log.

**Limits.** One crate, one run per variant, one 4-vCPU machine. Each extra job builds in its own copy of the tree
(more disk, not measured here). The unstable mutant `src/date.rs:311:16` is a separate finding: its verdict does not
depend on `--jobs` alone (it varied at `--jobs 1` too), and its cause is not known yet.
