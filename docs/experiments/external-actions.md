# E-9: external Actions candidate validation (#78, #80)

Candidate: `f5a73177237cc572eb1e5ca9378ba3a992eee50a`, including main
`8224ef94dc1c5cbb74883e831a3111753e43fdad`. Date: 2026-11-28 UTC.
Public fixture: [rcc-humantime-acceptance](https://github.com/demiurg-au-rcc-agent/rcc-humantime-acceptance),
humantime `76af4738e7ddbab884b68c46ee82a0810adc3506` plus `pilots/humantime` configuration in `.rcc`.
Crate sources are unchanged for clean; R4 is applied from `docs/experiments/evidence/variants/R4.patch`.
The upstream workflow was replaced by one read-only RCC caller. No private project content was copied.

| Case | Witness | Job start – finish (UTC) | API run wall time | Runner time (job duration) |
|---|---|---|---|---|
| clean | [Actions 46129796613](https://github.com/demiurg-au-rcc-agent/rcc-humantime-acceptance/actions/runs/46129796613) | 2026-11-28T09:17:51Z – 2026-11-28T09:24:20Z | 393 s | 389 s / 6.483 min / 7 rounded min |
| r4 | [Actions 46129905383](https://github.com/demiurg-au-rcc-agent/rcc-humantime-acceptance/actions/runs/46129905383) | 2026-11-28T09:19:15Z – 2026-11-28T09:27:05Z | 474 s | 470 s / 7.833 min / 8 rounded min |
| unpinned | [Actions 46129930661](https://github.com/demiurg-au-rcc-agent/rcc-humantime-acceptance/actions/runs/46129930661) | 2026-11-28T09:19:35Z – 2026-11-28T09:19:39Z | 6 s | 4 s / 0.067 min / 1 rounded min |

Runner minutes are computed from job timestamps, rounded up per job in the last column.
The timing API reports `billable.UBUNTU.total_ms: 0` for these public repository runs; that is billing,
not zero execution time. See the saved `evidence/e9/*-jobs.json` and `*-timing.json`.

- Clean: exit 0, **152/152 PASS**; the local Quick Start command on this candidate also gives **152/152 PASS**.
- R4: exit 1, **150/152 PASS**, specifically
  `NOT PASS S1d mutation: FAIL - MISSED   src/date.rs:43:9`.
  The only other failing row is dependent T1: `THREAT unknown or failed gate S1d in CI-3`.
- Unpinned: exit 2 at the first step, before either checkout:
  `RCC template-sha must be a full 40-hex commit SHA (got 'main'); branch and tag names are not supported`.
  The workflow implementation remains pinned; only its template input is deliberately invalid.

All three setup logs show **Contents: read; Metadata: read** (GitHub's implicit metadata permission).
No secrets are passed and checkout does not persist credentials. Runner: GitHub-hosted `ubuntu-24.04`.
The clean and R4 runs perform the AppArmor user namespace sysctl and bubblewrap probe successfully.
`EXT_OFFLINE=1` records the live ruleset checks as unchecked; it does not claim a checked caller ruleset.

Cache state: no RCC cache restore/save action and no restored cargo target/dependency cache in either run;
fresh hosted runners, with tools downloaded during setup. GitHub logs say `Cache mode: write`, which is a
capability, not a hit. The repository cache inventory contains one unrelated semver cache from the initial
inherited upstream workflow on `main` (09:16:34 UTC, Rust 1.100.1); it was not accessed by these RCC jobs
(Rust 1.100.0). Inventory saved in `evidence/e9/caches.json`. Thus these are cold RCC runs, not a warm-cache benchmark.

The first inherited upstream run [46129676255](https://github.com/demiurg-au-rcc-agent/rcc-humantime-acceptance/actions/runs/46129676255)
is setup history, not an acceptance witness.

## Release acceptance remains pending

These witnesses validate a candidate SHA, **not a published release tag**. Issue #78 remains open and the
Quick Start release row stays "Not packaged and not tested in this release."
After publishing a tag containing this workflow, resolve that tag to its full commit SHA, use that SHA in
both caller fields, and repeat clean, R4 and unpinned PRs. Record their run URLs, permissions, cache state,
wall time and runner minutes, and compare the clean result with local Quick Start for that same tag.
Only then change the release row and close #78. No release/tag was created by this validation.

Final-head repetitions and the review request are recorded in PR #80 after the documentation commit,
so attaching their results does not move the reviewed HEAD.
