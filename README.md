# rust-cicd-core

Strict checks for a Rust crate, run on your machine from one command. 107 planted-bug tests ("canaries") check that
the checks themselves still catch what they are meant to catch: a check that has stopped catching anything fails too.
The result is a per-check report.

**For:** maintainers of small, pure-Rust libraries who want more than `fmt + clippy + test`, on Linux (or WSL2)
x86_64. **Not yet for:** crates with `unsafe` (the profile forbids it), large workspaces, or a ready-made GitHub
Actions setup in your own repository (see [limits](docs/QUICKSTART.md#what-you-need-and-what-you-do-not)).

**What it adds to a plain CI**, measured on one crate (humantime, experiment E-1,
[results](docs/experiments/baseline-vs-template.md)):
- **Regressions caught:** 9 of 9 seeded regressions, against 3 of 9 for `fmt + clippy + test`. The extra catches
  come from mutation testing, no-panic lints, advisory checks, a no-`unsafe` gate and a check for code that differs
  between test and release builds.
- **False blocks:** none on the clean crate.
- **Cost:** about 10x the wall time and 13x the CPU time: 499 s against 50 s wall, 781 against 59 CPU-seconds, for one
  run on a 2-vCPU VM.

E-1 ran on template commit `4aca02d`. Since then three changes were added: S2d (semver, #69), a pilot fix (#72) and
the WSL sandbox fixes in this release. The clean pass and the R4 failure in the Quick Start were measured again on
this release, on a 16-vCPU machine.

## Quick start

Install the tools once, in 13–18 minutes ([full steps](docs/QUICKSTART.md#1-install-once-1318-min)), then:

```sh
git clone --branch v0.3.0 https://github.com/Demiurg-AU/rust-cicd-core
cd rust-cicd-core
EXT_OFFLINE=1 bash scripts/pilot.sh pilots/humantime 3a; echo "exit=$?"
```

**Expected:** `PILOT 3a core (ci-local): PASS`, `150/150 PASS`, exit 0, in 4–7 minutes.

**Report:** the `evidence:` directory the run prints. It holds `results.tsv`, one row per check, and one log per
check whose first line is the command that ran.

**A failing example and how to re-run one check:** [Quick Start, steps 4–5](docs/QUICKSTART.md#4-see-a-check-fail-56-min).
**Your own crate:** copy `pilots/humantime` and set the crate URL and commit ([how](docs/QUICKSTART.md#your-own-crate)).

**The demo binary** (`src/main.rs`, prints `5`) is the crate this repository tests itself on. It also exercises the
signed-release path ([verify a release](docs/verify-release.md)). You do not need it.

Product summary and verifiable claims: [docs/ANNOUNCE.md](docs/ANNOUNCE.md). Project status: [docs/ROADMAP.md](docs/ROADMAP.md).

---

## Project log (Russian; the original notes)

### Минимальное ядро CI (S0–S2) + самопроверка гейтов

**Статус и что осталось до цели:** [docs/ROADMAP.md](docs/ROADMAP.md).

Запуск: `./scripts/ci-local.sh` (Linux/WSL; нужны cargo, clippy, rustfmt, cargo-nextest,
cargo-llvm-cov + llvm-tools-preview, cargo-deny, cargo-audit, **bubblewrap**). Логи → `evidence/<UTC>/`.

Код под проверкой (тесты, `build.rs`, proc-macro, Lean) запускается в тюрьме bubblewrap: свидетельства и скрипты
для него только для чтения (угроза CI-9, ворота S0s/C28/C29). Ubuntu 24.04 / WSL: `sudo apt install bubblewrap`;
если `bwrap` пишет `setting up uid map: Permission denied` — `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`.

## Гейты
| ID | Шаг | Ожидание |
|---|---|---|
| S0a | `cargo build --locked --all-targets` | pass |
| S1a | `cargo fmt --check` | pass |
| S1b | `cargo clippy --all-targets -D warnings` | pass |
| S1c | `cargo llvm-cov nextest --fail-under-lines 80` | pass |
| S2a | `cargo deny check` (формат без устаревших ключей) | pass |
| S2b | `cargo audit` | pass |
| C1–C4 | канарейки: плохой формат / clippy len_zero / падающий тест / лицензия GPL | **fail по правильной причине** |

Вердикт канарейки: PASS только если гейт упал И в логе найдена ожидаемая причина.
FAIL_WRONG_REASON = гейт упал, но не из-за того, что должен ловить.

## Журнал прогонов 2026-11-15 (Cowork Linux VM, Ubuntu 22.04, rustc 1.100.0)
| Прогон | Итог | Что показал |
|---|---|---|
| 20261115T122016Z | 7/10 | S0a, S1c упали из-за среды (нет права удалять файлы в папке → cargo не может чистить target). C3 = FAIL_WRONG_REASON — самопроверка поймала ложное падение. Исправлено: сборка вынесена в temp. |
| 20261115T122125Z | 9/10 | S1c упал по делу: покрытие 64.29% < 80 (main.rs без теста). Порог НЕ снижен; добавлен e2e-тест `tests/cli.rs`. |
| 20261115T122145Z | 10/10 | Покрытие строк 92.86%. |
| 20261115T122159Z | 10/10 | Повтор без изменений — идемпотентность (F(0)=I). |
| 20261115T122217Z | 10/10 | Исправлен env-свидетель (хеши реальных бинарников вместо прокси rustup). |

## Ограничения (честно)
- Прогон в изолированной VM, а не в вашем WSL: повторите там `./scripts/ci-local.sh` для своего свидетеля.
- cargo-audit 0.23.0: у релиза нет опубликованной sha256 — хеш записан по принципу TOFU. deny и nextest сверены с опубликованными sha256.
- Не git-репозиторий (git_head=none); MSRV не заявлен, пока нет проверки MSRV.
- Нулевые зависимости → deny/audit пока проверяют тривиальный граф.
- Мусор от прогона 1, который я не смог удалить (нет права на удаление): `target/`, `evidence/20261115T122016Z/canary-work/` — можно удалить вручную.

## S3 — GitHub (Demiurg-AU/rust-cicd-core, public с 2026-11-15)
| ID | Утверждение | Свидетель | Статус |
|---|---|---|---|
| S3a | Все actions закреплены полными SHA, `permissions: {}` по умолчанию, `persist-credentials: false` | `.github/workflows/ci.yml` | VERIFIED_PRIMARY |
| S3b | zizmor 1.32.0 без находок (локально в WSL и в CI) | [`evidence/zizmor-20261115T123109Z/`](https://github.com/Demiurg-AU/rust-cicd-core/tree/ff8dbde0de3f3b13ad761e3837bbe08aabb15ef4/evidence/zizmor-20261115T123109Z), CI run 43714298921 | VERIFIED_PRIMARY |
| S3c | zizmor ловит плохой workflow (канарейка Z2: pull_request_target + unpinned + injection) | [`evidence/zizmor-*/results.txt`](https://github.com/Demiurg-AU/rust-cicd-core/tree/ff8dbde0de3f3b13ad761e3837bbe08aabb15ef4/evidence) | VERIFIED_PRIMARY |
| S3d | Тот же `ci-local.sh` в CI: 10/10 на GitHub-раннере | CI run 43714298921, артефакт evidence | VERIFIED_PRIMARY |
| S3e | Политика репозитория: SHA-pinning обязателен; токен по умолчанию read-only | API `actions/permissions` | VERIFIED_PRIMARY |
| C5 | Канарейка: `actions/checkout@v4` на ветке `canary/unpinned-action` отклонён политикой («must be pinned to a full-length commit SHA») | CI run 43714420615 (failure — ожидаемо) | VERIFIED_PRIMARY |
| S3f | Dependabot с карантином 7 дней (cooldown) — найдено zizmor (dependabot-cooldown) | `.github/dependabot.yml` | VERIFIED_PRIMARY (конфиг), работа обновлений — UNDERDETERMINED |
| S3g | Защита main: ruleset `main-protection` (запрет удаления и force-push, обязательные проверки core + zizmor) | API `rules/branches/main` | VERIFIED_PRIMARY (конфиг) |
| C6 | Канарейка: force-push в main отклонён (GH013) | лог canary-ruleset, main не изменился | VERIFIED_PRIMARY (отклонение); какое именно правило сработало — UNDERDETERMINED: коммит также не прошёл проверки |
| C7 | Канарейка: прямой push в main без проверок отклонён («2 of 2 required status checks are expected») | лог canary-ruleset | VERIFIED_PRIMARY |
| S3h | Публичный репозиторий (2026-11-15); перед публикацией: gitleaks 8.30.1 по всей истории — no leaks | лог prepublic-scan | VERIFIED_PRIMARY |
| S3i | Secret scanning + push protection, Dependabot alerts, private vulnerability reporting включены | API | VERIFIED_PRIMARY |

## S4 — происхождение сборки и SBOM, 2026-11-15
Исполнитель: `release.yml` → изолированный `build-reusable.yml` (workflow_call), прогон 43716257897 на `main` (eabd2c0).
Проверяющий: отдельно, в WSL (`gh attestation verify`), не тот процесс, что собирал. Свидетели: [`evidence/s4-20261115T125558Z/`](https://github.com/Demiurg-AU/rust-cicd-core/tree/ff8dbde0de3f3b13ad761e3837bbe08aabb15ef4/evidence/s4-20261115T125558Z).

| ID | Утверждение | Свидетель | Статус |
|---|---|---|---|
| V1 | SHA256SUMS бинарника и SBOM сходятся | `V1-sha256.log` | VERIFIED_PRIMARY |
| V2 | SLSA provenance v1 подписана именно `build-reusable.yml@refs/heads/main`, раннер github-hosted | `V2-provenance.json`, `V4-provenance-fields.txt` | VERIFIED_PRIMARY |
| V3 | SBOM-аттестация (CycloneDX) привязана к тому же бинарнику и подписанту | `V3-sbom.json` | VERIFIED_PRIMARY |
| V5 | Бинарник содержит данные cargo-auditable (секция `.dep-v0`) | `V5-auditable.txt` | VERIFIED_PRIMARY |
| V6 | SBOM — CycloneDX 1.5, компонент rust-cicd-core 0.1.0, 0 зависимостей | `V6-sbom-summary.txt` | VERIFIED_PRIMARY |
| C8 | Канарейка: изменённый на 1 байт бинарник не проходит проверку | `C8-tampered.log` | VERIFIED_PRIMARY |
| C9 | Канарейка: проверка с чужим подписантом (`ci.yml`) отклонена; контроль с верным подписантом проходит, отличие только в `--signer-workflow` | [`evidence/s4-c9-recheck-*.txt`](https://github.com/Demiurg-AU/rust-cicd-core/tree/ff8dbde0de3f3b13ad761e3837bbe08aabb15ef4/evidence/s4-c9-recheck-20261115T160448Z.txt) | VERIFIED_DERIVED (было VERIFIED_PRIMARY: текст ошибки общий — замечание Codex к PR #3 принято) |
| L3 | Соответствие SLSA Build L3 | GitHub: аттестации + reusable workflow дают L3; подписант = reusable workflow (V2) | VERIFIED_DERIVED (по документации GitHub + V2; независимого аудита платформы нет) |

Журнал отклонений: мой предварительный скрипт проверки версий в манифесте install-action дал ложное MISSING
(ошибка декодирования в самом скрипте; повторная проверка по raw-файлу: версии есть). Гейт сработал по неправильной причине — исправлено.
zizmor 1.32.0 предложил синтаксис `$/` для ссылки на свой reusable workflow — применён; работоспособность подтверждена прогоном 43716257897.

## L — Lean (2026-11-15)
Стадия L в `scripts/ci-local.sh` обязательна: требуется ровно один `lakefile.toml`
(каталоги `.git`, `.lake`, `target`, `evidence`, `fixtures` исключены из поиска).
Для разбора TOML нужен Python 3.11+; для сборки — elan и закреплённый Lean.

| ID | Гейт | Что ловит |
|---|---|---|
| L0 / L0b | `lean-toolchain` в репозитории и версия Lean совпадает с ним | невоспроизводимая сборка |
| L1 | `lake build +Module…` для всех обнаруженных модулей | неверные доказательства, в том числе при пустых defaultTargets |
| L2 | Lean-environment audit каждой теоремы во всех модулях библиотек, включая неимпортированные подмодули и custom roots/globs; `sorryAx` = FAIL; generated constructor auxiliaries and protected `brecOn.eq` are audited but need no proof-map row | «доказано» через sorry |
| L3 | нет `sorry`/`admit` в тексте | то же, грубая проверка |
| X1 / X2 | `proof-map.tsv`: каждая теорема сопоставлена Rust-тесту, тест существует и проходит | разрыв Rust↔Lean |
| CL1 / CL2 | канарейки: теорема с sorry, ложное доказательство — должны упасть по своей причине | неработающий гейт |

Граница: X1/X2 доказывают трассируемость и прохождение тестов, но НЕ семантическое соответствие модели коду
(соответствие в `proof-map.tsv` — утверждение владельца, ASSUMPTION до ревью).
Lean в CI: elan v4.2.4 и Lean 4.35.0 скачиваются с проверкой sha256 (digest Lean сверен с GitHub API).
Fixture CI uses a matrix generated from every fixture Rust root containing a Lean `lakefile.toml`;
its final coverage job requires successful discovery and fixture jobs plus checksum-sealed,
all-PASS `results.tsv` evidence matching the complete `expected-gates.txt` inventory and an N/N
summary. The root Lean scan excludes only the top-level `fixtures/` directory; nested directories
named `fixtures` remain in scope.

### Silent-skip audit

`evidence/audit-before.tsv` records the new canaries against the original gate
behavior: the existing 24 checks pass, but CL8–CL28 all exit 0
(`FAIL_GATE_DID_NOT_FIRE`). `evidence/audit-after.tsv` records the fixed run.
Failure reasons are matched against tool output only, never the logged command.

| Examined location | Verdict / broken input previously accepted |
|---|---|
| Script setup, evidence writes and checksum finalization | FIXED (CL21): checksum failure was overwritten by a successful results check; setup/write errors now abort |
| Environment witness (`head`, optional tool lookup, rustup fallback) | OK: diagnostic only; actual gates invoke tools and check their status |
| `run` expected-pass status / expected-fail reason | FIXED (CL19): a reason present only in command arguments satisfied the canary |
| S0a, S1a–S1c, S2a–S2b | OK: commands propagate failure; 80% coverage unchanged; an empty third-party dependency graph is intentional |
| C1–C4 and CL1–CL7 | OK: preserved; conditional proof-map canaries are now unconditional and required by the witness inventory (CL20) |
| Lean project discovery | FIXED (CL8, CL9): no project or multiple projects silently omitted checks; no depth limit remains |
| L0 / L0b and tool invocation | FIXED (CL25): failed version command with plausible output passed the version check; pin and literal version checks are mandatory, no default-toolchain fallback |
| L1 explicit build targets | FIXED (CL28): `defaultTargets = []` let a false theorem pass L1 with “Nothing to build”; all discovered modules are now explicit targets |
| L2 build and axiom checks | OK: build/Lean errors, zero theorems and `sorryAx` fail; compiler auxiliaries are axiom-audited without requiring extra proof-map rows; existing CL1–CL5 preserved |
| L2 generated auxiliary classification | FIXED (CL35): mutual-inductive `brecOn.eq` declarations were mistaken for user theorems; exemption requires the exact protected name and Lean auxiliary-recursor metadata, and the canary confirms they remain axiom-checked |
| L2 module inventory | FIXED (CL22–CL24): custom roots, unimported submodules and valid alternate TOML table syntax omitted proofs |
| L2 theorem filters | FIXED (CL26, CL27): private theorems and declarations without source ranges were skipped; all project theorem constants are now checked |
| L3 source inventory and scan | FIXED (CL10, CL11): missing sources / nested `sorry` text passed; discovery and grep errors now fail |
| X1 theorem inventory | FIXED (CL12–CL14): missing/empty input or an unmapped final line without a newline passed |
| X2 row loop | FIXED (CL15): comment-only input executed zero tests and passed; rows must be nonempty, two-column TSV |
| X2 Cargo result | FIXED (CL16–CL18): arbitrary `1 passed` text, failed Cargo status, or `11 passed` satisfied the check; requires exit 0 and an exact one-test success summary |
| Summary / `results.tsv` | FIXED (CL20): an omitted gate (even an empty table) could satisfy PASS counts; all gate IDs must occur exactly once |
| `ci.yml`: push/PR/manual triggers, core/tool installation, zizmor | OK: no path filters, gate `if:` conditions, or error suppression; main is the intended branch scope |
| `ci.yml`: evidence upload | OK: `always()` preserves failure; missing artifacts are an error |
| `build-reusable.yml`: workflow_call, build, packaging/SBOM, both attestations, upload | OK: unconditional steps, shell error propagation, explicit SBOM presence, required binary and error-on-missing artifacts |
| `release.yml`: manual/tag triggers, reusable caller | OK: deliberate `v*` release scope; existing `$/` caller syntax already verified by release run 43716257897 |

The script fails closed on unsupported module identifiers, symlinked source
directories and source directories outside the project. Build products remain
outside the repository; checksum generation and the required gate inventory must
both succeed before the run succeeds.

## Не сделано (S5+)
Trusted Publishing (решение владельца: первая публикация в crates.io вручную), cargo-vet, MSRV, канарейка удаления main. Изменения в main — только через PR.

### Lean stage switch and Python requirement
- `REQUIRE_LEAN` (default `1`): the Lean stage is mandatory. `REQUIRE_LEAN=0` skips it **only** when the repository has no `lakefile.toml`; the skip is recorded as gate `LSKIP` in `results.tsv`. Multiple or broken Lean projects always fail. Canaries CL29, CL30, CL32 test the switch. A Rust-only run with `REQUIRE_LEAN=0` needs no Python.
- The Lean config parser needs Python >= 3.11 (`tomllib`). Gate `L00` checks this before the Lean stage and fails with `PYTHON too old: …`; canary CL31 tests the check. Override the interpreter with `PY=/path/to/python3.12`.

### Mutation testing (S1d)
Line coverage says code *ran*; mutation testing says the tests *catch changes*. Gate `S1d` runs `cargo-mutants` (27.1.0) and passes only if no mutant is missed or times out and at least one is caught. Exclusions go in `mutants-exclusions.tsv` as `<regex><TAB><justification>`; an empty justification fails the gate. Canaries: `C5` (a test without an assertion must leave a surviving mutant), `C6` (unjustified exclusion is rejected).


> Historical run evidence (`evidence/<timestamp>/`, `s4-*`, `zizmor-*`) was removed from HEAD by owner decision #31; it stays in git history. Links above are permalinks to commit `ff8dbde`. Current runs: CI artifacts plus the signed `evidence.tar` attestation on main (CI-4).
