# rust-cicd-core v0.3.0: product summary and demo

## In one paragraph

rust-cicd-core runs strict checks on a small Rust library from one command on Linux or WSL2: mutation testing,
no-panic lints, advisory and supply-chain checks, a no-`unsafe` gate and release-build tests. Every run also runs
109 planted-bug tests ("canaries") that prove the checks still catch what they claim to catch. Code under test runs
in a bubblewrap sandbox. It needs no GitHub account, and it writes a per-check report with checksums.

## Claims, each with its evidence

| # | Claim | Evidence | How to check it yourself |
|---|---|---|---|
| 1 | One command takes a pinned external crate (humantime 2.4.0 + 4 fixes) to a PASS report: 152/152 checks, exit 0, 265–420 s | three Quick Start runs, 2026-11-27, each in a fresh `$HOME` (two on WSL2, 16 vCPU, at 150/150 before C108 and C109; one in an Ubuntu 24.04 container, 4 vCPU, at 152/152); one session had only the public page | [Quick Start](QUICKSTART.md), steps 1–3 |
| 2 | A safe regression that a plain `fmt + clippy + test` CI misses is blocked: S1d names `src/date.rs:43:9`, exit 1 | same session; E-1 variant R4 | Quick Start, step 4 |
| 3 | On 9 seeded regressions in humantime, these checks caught 9 and `fmt + clippy + test` caught 3; no false block on the clean crate | E-1, [baseline-vs-template.md](experiments/baseline-vs-template.md), raw logs in `experiments/evidence/e1/` | rerun with `experiments/evidence/e1/e1-run.sh` |
| 4 | The price is about 10x the wall time and 13x the CPU of plain CI (E-1: 499 s against 50 s wall on 2 vCPU) | E-1 | same |
| 5 | Every check that fails names its reason, and the canaries require the *right* reason (a check that fails for another reason is `FAIL_WRONG_REASON`) | `results.tsv` column `reason_check` | any run |
| 6 | Releases carry SLSA provenance and a CycloneDX SBOM, verifiable with `gh attestation verify` | v0.2.0 consumer check | [verify-release.md](verify-release.md) |

## Limits (confirmed)

- **One crate passes end to end:** humantime, a small pure-Rust library. The second crate tried, `semver` (E-4),
  fails the profile because it uses `unsafe`. That is by design, but it means the profile has been shown on one
  crate only.
- **Strict by design.** Swapping types under `cfg(kani)` or `cfg(test)` fails S1g. The ALISA Authority Firewall crate
  does this for its Kani proofs, and it needed a lab change to pass. Runs on one machine wait for each other.
- **Linux x86_64 only.** Tested on Ubuntu 26.04 under WSL2, in an Ubuntu 24.04 container, and on GitHub's
  `ubuntu-24.04` runners for this repository's own CI. The container run found `openssh-client` missing from the
  package list (now added); other minimal images may lack something else.
- **GitHub Actions for your own repository is not packaged** and has not been tested.
- **Domain claims stay ABSTAIN without proofs.** Stage 3a does not prove properties of your crate; it reports that
  they are unproven.
- **The sample was designed by the author.** E-1's regressions target the classes these checks are built for. It
  says nothing about other regression classes.
- **Install takes 12–18 minutes**, most of it compiling seven cargo tools.

## Demo (2 commands after install, about 10 minutes)

```sh
git clone --branch v0.3.0 https://github.com/Demiurg-AU/rust-cicd-core && cd rust-cicd-core
EXT_OFFLINE=1 bash scripts/pilot.sh pilots/humantime 3a        # PASS, 152/152
# then Quick Start step 4: the same crate with the R4 regression -> FAIL at S1d, exit 1
```

## Announcement text

> **rust-cicd-core v0.3.0**: strict local checks for small Rust libraries, with checks that test themselves.
>
> One command runs mutation testing, no-panic lints, cargo-deny/audit/vet and release-build tests on a pinned
> crate, inside a sandbox, and writes a per-check report. 109 planted-bug canaries fail the run if a check stops
> catching what it should.
>
> On one crate (humantime), it caught 9 of 9 seeded regressions where `fmt + clippy + test` caught 3, at about 10x
> the run time. Linux/WSL2, no GitHub account needed. Quick start:
> https://github.com/Demiurg-AU/rust-cicd-core/blob/v0.3.0/docs/QUICKSTART.md
>
> Limits: shown end to end on one small pure-Rust crate; `unsafe` is out of profile; no packaged GitHub Actions setup yet.
