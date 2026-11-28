# Quick Start

Run the rust-cicd-core checks on a pinned Rust crate on your own Linux machine and get a report. Your crate is not
modified, and you need no GitHub account.

Checked three times on 2026-11-27, each time as a user with a fresh `$HOME`, no tokens or `gh`, `PATH=/usr/bin:/bin`
and public downloads only: twice on Ubuntu 26.04 under WSL2 (16 vCPU, 15 GB; the second session had only this page),
once in an Ubuntu 24.04 container (4 vCPU, 15 GB). Times are the range of the runs.

## 1. Install (once, 12–18 min)

```sh
# system packages (needs sudo; this is the only step that does)
sudo apt-get install -y git curl build-essential cmake pkg-config libssl-dev python3 bubblewrap zstd openssh-client
# Ubuntu 24.04+ only, if `bwrap --ro-bind / / true` prints "setting up uid map: Permission denied":
#   sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0

cd "$(mktemp -d)"    # downloads and installers land here; delete it afterwards

# Rust 1.100.0 (90–200 s). If a system Rust exists, rustup prints "error: cannot install while Rust is installed"
# and then continues: with -y that is a warning, not a failure.
# Each download, its check and the install are one && chain: a wrong SHA-256 (or a failed download) stops it
# before anything runs or is unpacked.
curl -sSfL -o rustup-init https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init &&
  echo "$(curl -sSfL https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init.sha256 | cut -d' ' -f1)  rustup-init" | sha256sum -c - &&
  chmod +x rustup-init && ./rustup-init -y --profile minimal --default-toolchain 1.100.0 --component clippy,rustfmt,llvm-tools-preview
export PATH="$HOME/.cargo/bin:$PATH"

# the tools the checks call (640–880 s: they are compiled from source)
cargo install --locked cargo-nextest@0.9.152 cargo-llvm-cov@0.9.1 cargo-deny@0.20.2 cargo-audit@0.23.0 \
  cargo-mutants@27.1.0 cargo-vet@0.10.3 cargo-semver-checks@0.51.0

# elan for the Lean stage (2 s)
curl -sSfLO https://github.com/leanprover/elan/releases/download/v4.2.4/elan-x86_64-unknown-linux-gnu.tar.gz &&
  echo "42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63  elan-x86_64-unknown-linux-gnu.tar.gz" | sha256sum -c - &&
  tar xzf elan-x86_64-unknown-linux-gnu.tar.gz && ./elan-init -y --default-toolchain leanprover/lean4:v4.35.0
export PATH="$HOME/.elan/bin:$PATH"
```

In every new shell, put both tool directories on `PATH` again before the next steps:
`export PATH="$HOME/.cargo/bin:$HOME/.elan/bin:$PATH"`.

## 2. Run the example (4–7 min)

The example crate is humantime 2.4.0 with four small fixes, pinned at commit `76af473`
(`pilots/humantime/pilot.env`).

```sh
git clone --branch v0.3.0 https://github.com/Demiurg-AU/rust-cicd-core
cd rust-cicd-core
EXT_OFFLINE=1 bash scripts/pilot.sh pilots/humantime 3a; echo "exit=$?"
```

`EXT_OFFLINE=1` is needed. Without it the run tries to read this repository's GitHub ruleset. When it cannot,
T3 fails with `RULESET live policy unavailable`. With it, the ruleset checks are recorded as "unchecked: offline"
and the checks of your crate run in full.

**Expected result** (exit 0, 265–420 s):

```
  ci-local (exit 0): 152/152 PASS
    core            17/17 PASS
    canaries        109/109 PASS
    evidence/judge  15/15 PASS
    policy          7/7 PASS
    lean            4/4 PASS
  domain claims (claims.tsv, claim-verdict, request: bounded):
    ABSTAIN H1: no evidence listed
  ...
PILOT 3a core (ci-local): PASS
```

ABSTAIN is expected here. H1–H3 are claims about humantime that stage 3a does not try to prove. They are listed
so that a missing proof shows up instead of passing silently.

## 3. Open the report

The run prints `evidence: <dir>`, which is `pilots/humantime/work/humantime/evidence/<UTC time>/`.

| File | What it holds |
|---|---|
| `results.tsv` | one row per check: id, name, expected (`pass` or `fail` for canaries), exit code, reason match, verdict |
| `<ID>-<name>.log` | that check's full output; the first line, `$ ...`, is the command that ran |
| `summary.txt` | `PROGRESS=<passed>/<total>`, the evidence path and the temporary build directory (already deleted) |
| `SHA256SUMS` | checksums of all of the above, written only when every check passed |

## 4. See a check fail (4–6 min)

This applies a safe test regression to a local copy of the crate. The patch weakens the tests, and the crate still
builds and its tests pass, so a plain `cargo fmt && cargo clippy && cargo test` CI does not notice it (experiment
E-1, `docs/experiments/baseline-vs-template.md`, variant R4). This is also how you point the checks at your own crate:
copy a pilot and change two lines. (`CRATE_NAME` stays `humantime` here, so the output still says
`PILOT humantime` and the copy is in `work/humantime`.)

```sh
git clone --single-branch -b pilot/humantime-fixes https://github.com/Demiurg-AU/rust-cicd-core ../humantime-r4
git -C ../humantime-r4 -c user.name=demo -c user.email=demo@example.invalid am "$PWD/docs/experiments/evidence/variants/R4.patch"
cp -r pilots/humantime pilots/humantime-r4
sed -i "s#^CRATE_URL=.*#CRATE_URL=$(cd ../humantime-r4 && pwd)#; s#^CRATE_SHA=.*#CRATE_SHA=$(git -C ../humantime-r4 rev-parse HEAD)#" pilots/humantime-r4/pilot.env
EXT_OFFLINE=1 bash scripts/pilot.sh pilots/humantime-r4 3a; echo "exit=$?"
```

**Expected result** (exit 1, 263–348 s):

```
  ci-local (exit 1): 150/152 PASS
    core            16/17 PASS
    canaries        109/109 PASS
    evidence/judge  15/15 PASS
    policy          6/7 PASS
    lean            4/4 PASS
    NOT PASS S1d mutation: FAIL - MISSED   src/date.rs:43:9: replace <impl fmt::Display for Error>::fmt -> fmt::Result with Ok(Default::default()) ...
    NOT PASS T1 threat-model: FAIL - THREAT unknown or failed gate S1d in CI-3
PILOT 3a core (ci-local): FAIL
```

S1d is mutation testing. It changed the code (here, made `Display for Error` return nothing) and no test noticed.
T1 fails because the threat model counts S1d as a control. One real failure, reported twice. The summary line shows
the first surviving mutant; `S1d-mutation.log` lists all of them: 15 or 16 in the 2026-11-27 runs (3 or 4 in
`date.rs`, 5 in `duration.rs`, 7 in `wrapper.rs`).

## 5. Re-run a failed check

The full output is already in `<ID>-<name>.log`. To check a fix quickly, run the tool directly in the copy the run
used, `pilots/<name>/work/<crate>/`. Example for S1d:

```sh
cd pilots/humantime-r4/work/humantime
cargo mutants --test-tool nextest --file src/date.rs    # 87–97 s, exit 2 (mutants missed): 3 MISSED in src/date.rs
```

A direct run like this skips the sandbox and `mutants-exclusions.tsv`. Only the full pilot run counts as the
verdict. One mutant, `src/date.rs:311:16` (`<` to `<=` in `civil_from_unix`), was caught in some runs and missed in
others on 2026-11-27, so the `date.rs` count is 3 or 4. The `43:9` line that step 4 shows was missed every time.
If the first log line names a template function (`mutants_gate`, `coverage_gate`, ...), its definition in
`scripts/ci-local.sh` shows the tool command.

## Your own crate

Make a copy of `pilots/humantime`:
- In `pilot.env`, set `CRATE_NAME`, `CRATE_URL` (a git URL or a local path) and `CRATE_SHA` (a full commit id).
  Delete `SEMVER_BASELINE` if the crate is not a published library with a previous release. Set `REQUIRE_LEAN=0`
  if it has no Lean project.
- In `overlay/`, keep only what your crate needs, and nothing but configuration: `Cargo.lock`, `deny.toml`,
  `mutants-exclusions.tsv`, `supply-chain/*`. Run `cargo vet init` in the crate to create `supply-chain/`. Without it,
  S2c fails with `no supply-chain/ store (cargo vet init)`.
- The checks always use this repository's registries (`threat-model.tsv`, `ext-controls.tsv`,
  `ruleset-snapshot.json`). Files with those names in your crate are ignored, so a crate cannot bring a weaker
  threat model.
- Code that swaps types or modules under `cfg(kani)`, `cfg(test)` or other check-only cfgs fails S1g
  (`JUDGE-FORK ...`): the checks would judge different code from what ships. Only a whole module under `#[cfg(test)]`
  or `#[cfg(kani)]` is allowed.

Expect failures the first time. Upstream humantime 2.4.0 needed four commits before it passed (`git log
997ff566..76af473` on branch `pilot/humantime-fixes`):
- arithmetic and indexing that could panic (S1e);
- tests for mutants that survived (S1d);
- a bench dependency with an advisory, RUSTSEC-2026-0543 (S2a);
- rustfmt.

## Your own GitHub repository (candidate preview)

The reusable entry point is `.github/workflows/check-crate.yml`. The following complete caller was
[verified in a separate public humantime repository](experiments/external-actions.md) on candidate
`f5a73177237cc572eb1e5ca9378ba3a992eee50a`: clean **152/152 PASS**, R4 rejected by **S1d**, and a branch
name rejected before checkout. This candidate is not a released tag; release acceptance for #78 is pending.
The v0.3.0 instructions above and the release status row below remain unchanged.

In your crate repository, copy the configuration (not the template's CI workflow):

```sh
git clone https://github.com/Demiurg-AU/rust-cicd-core /tmp/rcc-template
git -C /tmp/rcc-template checkout --detach f5a73177237cc572eb1e5ca9378ba3a992eee50a
mkdir -p .rcc
cp /tmp/rcc-template/pilots/humantime/pilot.env .rcc/
cp -r /tmp/rcc-template/pilots/humantime/overlay .rcc/
```

Adapt `.rcc/pilot.env` and `.rcc/overlay/` as described in "Your own crate". `pilot.env` is literal
`KEY=value` data, not shell: blank lines, full-line comments and optional matching quotes around values
are accepted; expansions, commands, unknown keys and duplicate keys are rejected. Allowed keys are
`CRATE_NAME` (letters/digits, underscores, hyphens), `CRATE_URL` (HTTPS URL or absolute local path),
`CRATE_SHA` and `SEMVER_BASELINE` (full lowercase commit SHA; the baseline may be empty),
`REQUIRE_LEAN` (`0` or `1`), `PILOT_KANI` (`abstain` or `required`), and the stage-3b lists
`PILOT_3B_REQUIRE` (`fuzz-targets fuzz-canaries k5 k4 claims`) and `PILOT_3B_CLAIMS` (claim IDs).
The workflow requires a completed report from its fresh run directory before returning success.
 For humantime, keep the
fixture's configuration unchanged. The workflow sets `CRATE_URL` and `CRATE_SHA` to the caller checkout;
you do not supply them. Commit `.rcc` and this file as `.github/workflows/rcc.yml`:

```yaml
name: rust-cicd-core
on:
  pull_request:
permissions:
  contents: read
jobs:
  check:
    permissions:
      contents: read
    uses: Demiurg-AU/rust-cicd-core/.github/workflows/check-crate.yml@f5a73177237cc572eb1e5ca9378ba3a992eee50a
    with:
      template-sha: f5a73177237cc572eb1e5ca9378ba3a992eee50a
```

Open a PR to run it. Both SHA fields must identify the same template commit. For a released version,
resolve its published tag to the full commit SHA and retain the tag name as a comment beside the pin;
branch names and tag names in `template-sha` are rejected. Only SHA-pinned `uses` references are supported.
Do not use `secrets: inherit`. The caller needs Actions enabled and a GitHub-hosted `ubuntu-24.04` runner;
it needs no rights on rust-cicd-core. `push` is also supported; `pull_request_target` and `workflow_run`
are refused. A PR run checks GitHub's PR merge commit, as shown in the summary.

The job installs the pinned Quick Start tools, enables unprivileged user namespaces on the ephemeral
runner for bubblewrap, and runs `scripts/pilot.sh ... 3a`. It uses `contents: read` only, no secrets, and
`persist-credentials: false`. `EXT_OFFLINE=1` is the default: live ruleset checks T1/T3 are reported as
"unchecked: offline"; no repository-admin ruleset setup is needed for this mode.
Read the job summary for the verdict and download `rcc-evidence-<run-id>-<attempt>` for the per-gate logs.
Artifacts expire after 30 days; the [candidate report](experiments/external-actions.md) preserves the
key results and timing records. The workflow does not configure a persistent build cache.

## One run at a time

Runs on one machine wait for each other (`LOCK another rust-cicd-core run holds ...; waiting`). The sandbox canaries
open decoy sockets, and a second run in parallel can reach the first one's decoy, so C108, C109 or C97 would fail on a good
crate. Set `RCC_LOCK` to choose the lock file.

## What you need, and what you do not

| Where | Needs | Does not need |
|---|---|---|
| Your machine | sudo, only for `apt-get install` (and the AppArmor `sysctl` on Ubuntu 24.04+); disk: 2.0 GB after install and both runs (build directories are temporary and removed; peak not measured); network for the downloads | a GitHub account or token; any rights on this repository (it is public, so cloning is enough) |
| Your own GitHub repository (Actions) | **Not packaged and not tested in this release.** This repository's own `ci.yml` runs the same `scripts/ci-local.sh`. It needs: Actions enabled; a GitHub-hosted `ubuntu-24.04` runner; `sudo sysctl` on the runner (allowed there); `contents: read` for the job; for the ruleset checks T1/T3, a ruleset on your default branch and a `ruleset-snapshot.json` matching it, which only a repository admin can set up | rights on this repository |

## The demo binary

`src/main.rs` prints `5` (`checked_add(2, 3)`), and that is all it does. It is the crate this repository runs its
own checks on. The release (`v0.x.y` assets with SLSA provenance and an SBOM) shows the signed-release path end to
end (`docs/verify-release.md`). You do not need it to check your crate.
