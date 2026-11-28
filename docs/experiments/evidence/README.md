# Evidence for experiments E-1…E-8

Raw outputs of the runs described in `docs/experiments/*.md`, copied unchanged from the agent workspace
(archive `experiments-e1-e6.tar.gz`, SHA-256 `00556230ca85d726b17152756efda27685d02e830bd614c84f15fdd5976a5253`).
`SHA256SUMS` in this directory covers every file below.

| Path | Contents |
|---|---|
| `e1/` | E-1: harness `e1-run.sh`, `<id>.diff`, `<id>.base.txt` (baseline CI), `<id>.tmpl.txt` / `.tmpl.sum` (template 3a), `variants.txt` |
| `e2-e6/` | E-2 semver (`S1`, `S2`, `sc-*`, `s2d-*`), E-3 fuzz (`fz-*`), E-5 Kani (`ka-*`, `kh*`), E-6 oracle (`R10*`, `R0-*`, `rfc3339_vs_time.rs`), release-verify refusals (`verify-*.out`) |
| `e4/` | E-4 second crate (`semver` `280ebcb6`): `pilot.env`, `claims.tsv`, per-gate logs in `evidence/` |
| `e7/` | E-7 acceptance of target D: pilot 3b log, `status.tsv`, `fuzz.log`, ci-local `results.tsv`, HF6 and K4 SM4 logs |
| `e8/` | E-8 cargo-mutants `--jobs`: `run.sh`, `summary.txt`, per run `<crate>-j<N>/` with `caught/missed/unviable/timeout.txt` and `run.txt` (wall, CPU, peak RSS) |
| `variants/` | variant commits: `variants.bundle` (exact commit ids) and one `<id>.patch` per variant; `R6.Cargo.lock` |

## Reconstructing the variants

All variants sit on the crate commit `76af4738e7ddbab884b68c46ee82a0810adc3506`, branch `pilot/humantime-fixes` of
this repository (R7b sits on R7).

```
git clone --single-branch -b pilot/humantime-fixes https://github.com/Demiurg-AU/rust-cicd-core humantime
cd humantime
git fetch <this repo>/docs/experiments/evidence/variants/variants.bundle 'refs/heads/*:refs/remotes/v/*'
git log --oneline -1 v/R10     # 8972aec, the id in the experiment tables
```

Checked on 2026-11-26 in a fresh clone: all 13 bundle heads have the commit ids from the tables, and
`git am variants/R10.patch` on `76af473` gives the same tree as `v/R10`.

## Limits

The harness paths (`/root/ht-cmp`, `/root/pcmp`, `/root/pol-cmp`) are the agent's VM; to re-run, point them at the
clone above and at a template checkout of main `4aca02d`. One run per variant, one 2-vCPU VM. Timings are not
expected to reproduce on other hardware; gate verdicts are.
