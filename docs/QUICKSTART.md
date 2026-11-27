# Quick Start

Run the rust-cicd-core checks on a pinned Rust crate on your own Linux machine and get a report. Your crate is not
modified, and you need no GitHub account.

Checked twice on 2026-11-27, each time with a fresh `$HOME`, no tokens or `gh`, `PATH=/usr/bin:/bin` and public
downloads only, on Ubuntu 26.04 under WSL2 (16 vCPU, 15 GB). The second session had only this page. Times are the
range of the two runs.

## 1. Install (once, 13–18 min)

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
  ci-local (exit 0): 150/150 PASS
    core            17/17 PASS
    canaries        107/107 PASS
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

## 4. See a check fail (5–6 min)

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

**Expected result** (exit 1, 284–348 s):

```
  ci-local (exit 1): 148/150 PASS
    core            16/17 PASS
    canaries        107/107 PASS
    evidence/judge  15/15 PASS
    policy          6/7 PASS
    lean            4/4 PASS
    NOT PASS S1d mutation: FAIL - MISSED   src/date.rs:43:9: replace <impl fmt::Display for Error>::fmt -> fmt::Result with Ok(Default::default()) ...
    NOT PASS T1 threat-model: FAIL - THREAT unknown or failed gate S1d in CI-3
PILOT 3a core (ci-local): FAIL
```

S1d is mutation testing. It changed the code (here, made `Display for Error` return nothing) and no test noticed.
T1 fails because the threat model counts S1d as a control. One real failure, reported twice. The summary line shows
the first surviving mutant; `S1d-mutation.log` lists all 15 (3 in `date.rs`, 4 in `duration.rs`, 8 in `wrapper.rs`).

## 5. Re-run a failed check

The full output is already in `<ID>-<name>.log`. To check a fix quickly, run the tool directly in the copy the run
used, `pilots/<name>/work/<crate>/`. Example for S1d:

```sh
cd pilots/humantime-r4/work/humantime
cargo mutants --test-tool nextest --file src/date.rs    # 87–96 s, exit 2 (mutants missed): the 3 MISSED lines of src/date.rs
```

A direct run like this skips the sandbox and `mutants-exclusions.tsv`. Only the full pilot run counts as the
verdict. If the first log line names a template function (`mutants_gate`, `coverage_gate`, ...), its definition in
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

## One run at a time

Runs on one machine wait for each other (`LOCK another rust-cicd-core run holds ...; waiting`). The sandbox canaries
open decoy sockets, and a second run in parallel can reach the first one's decoy, so C108 or C97 would fail on a good
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
