# Experiment E-4: a second external crate of another structure

Pre-registered 2026-11-26 before any run. ROADMAP plan improvement 4 (portability after the four criteria).

## Subject

- Crate: `dtolnay/semver` at `280ebcb6edac3aa4cdc545dbff8a26c5ac4861fe` (2026-06-23). Structure unlike humantime:
  `build.rs` that runs `rustc --version` and emits a `rustc-check-cfg`; features (`std` default, optional `serde`
  through `serde_core`); 49 `unsafe` occurrences (43 in `identifier.rs`, a packed-pointer representation); a large
  dev-dependency tree (`criterion`); integration tests with shared modules; its own `fuzz/`.
- Template: main `4aca02d`, `scripts/pilot.sh pilots/semver 3a`, configuration only (pilot.env, overlay lockfile and
  cargo-vet store); no spec pack (3b not attempted).

## Expected 3a verdicts (registered)

| Gate | Expected | Why |
|---|---|---|
| S1i no-unsafe-code | FAIL | `unsafe` is part of the design, not a defect |
| S1e no-panic-lints | FAIL | indexing and arithmetic in a parser, unchecked by design |
| S1g no-judge-forks | PASS | no `cfg(test)`/`debug_assertions` branches found in `src/` by grep |
| S1d mutation | UNDERDETERMINED | large test suite; not predicted |
| S2a/S2b/S2c | PASS after configuration | dev-dependency tree needs cargo-vet exemptions (configuration) |
| everything else | PASS | — |

Measured: time to connect (configuration written by hand), size of the configuration, core changes needed, and
the verdict of every gate not PASS with its reason.

## Results (2026-11-26, 14:16-14:30 UTC)

**Connection.** 30 s of agent time from registration to a runnable pilot; no change to the template core. The
configuration is `pilot.env` (6 lines), an empty `claims.tsv`, `overlay/Cargo.lock` (`cargo generate-lockfile`,
53 packages) and `overlay/supply-chain/` (`cargo vet init`: 53 exemptions — every dependency trusted unreviewed,
the same choice as for humantime); 695 lines in all, nearly all generated. Not written: a spec pack (3b).

**3a: 138/146, exit 1, 856 s wall.**

| Gate | Registered | Result |
|---|---|---|
| S1i no-unsafe-code | FAIL | **FAIL** `usage of an unsafe block` (by design of the crate) |
| S1e no-panic-lints | FAIL | **FAIL**: 39 findings — 24 arithmetic, 12 string indexing, 2 `unwrap()`, 1 `unreachable!` |
| S1g no-judge-forks | PASS | PASS (`build.rs` emits only a `rustc-check-cfg`) |
| S1d mutation | UNDERDETERMINED | **FAIL**: 365 mutants in 7 min, 62 missed, 267 caught, 32 unviable, 4 timeouts; e.g. `Comparator::matches -> bool` replaced with `true` and with `false` both survive, as does `<impl Debug for Version>::fmt` |
| S1c test-coverage | (PASS, implicitly) | **FAIL, not registered**: the instrumented build runs with `-F unsafe_code` (`ci-local.sh:530`). Deliberate: the coverage profile is trusted only because no code under test can write the counter section (threat CI-3) |
| S2a deny, S2b audit, S2c vet | PASS | PASS |
| other gates | PASS | PASS; C8, C66, C67 report FAIL_WRONG_REASON (the coverage build cannot run) and T1 aggregates |

**Conclusion, limited to the two crates tried.** The template connects by configuration only to a crate with a
`build.rs`, features, a large dev-dependency tree and integration tests with shared modules: build, lint, release,
fork, neutral-mutant and supply-chain gates ran unchanged. Its strict profile does not fit a crate that uses
`unsafe` by design: S1i fails and, through the CI-3 coupling, S1c cannot measure coverage — such a crate is outside
the template's profile until a separate profile exists. S1d found real test gaps in a widely used crate (62
surviving mutants, among them a public matching function whose result is never checked directly).
