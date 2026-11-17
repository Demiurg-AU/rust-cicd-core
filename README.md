# rust-cicd-core — минимальное ядро CI (S0–S2) + самопроверка гейтов

Запуск: `./scripts/ci-local.sh` (Linux/WSL; нужны cargo, clippy, rustfmt, cargo-nextest,
cargo-llvm-cov + llvm-tools-preview, cargo-deny, cargo-audit). Логи → `evidence/<UTC>/`.

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
| S3b | zizmor 1.32.0 без находок (локально в WSL и в CI) | `evidence/zizmor-20261115T123109Z/`, CI run 43714298921 | VERIFIED_PRIMARY |
| S3c | zizmor ловит плохой workflow (канарейка Z2: pull_request_target + unpinned + injection) | `evidence/zizmor-*/results.txt` | VERIFIED_PRIMARY |
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
Проверяющий: отдельно, в WSL (`gh attestation verify`), не тот процесс, что собирал. Свидетели: `evidence/s4-20261115T125558Z/`.

| ID | Утверждение | Свидетель | Статус |
|---|---|---|---|
| V1 | SHA256SUMS бинарника и SBOM сходятся | `V1-sha256.log` | VERIFIED_PRIMARY |
| V2 | SLSA provenance v1 подписана именно `build-reusable.yml@refs/heads/main`, раннер github-hosted | `V2-provenance.json`, `V4-provenance-fields.txt` | VERIFIED_PRIMARY |
| V3 | SBOM-аттестация (CycloneDX) привязана к тому же бинарнику и подписанту | `V3-sbom.json` | VERIFIED_PRIMARY |
| V5 | Бинарник содержит данные cargo-auditable (секция `.dep-v0`) | `V5-auditable.txt` | VERIFIED_PRIMARY |
| V6 | SBOM — CycloneDX 1.5, компонент rust-cicd-core 0.1.0, 0 зависимостей | `V6-sbom-summary.txt` | VERIFIED_PRIMARY |
| C8 | Канарейка: изменённый на 1 байт бинарник не проходит проверку | `C8-tampered.log` | VERIFIED_PRIMARY |
| C9 | Канарейка: проверка с чужим подписантом (`ci.yml`) отклонена; контроль с верным подписантом проходит, отличие только в `--signer-workflow` | `evidence/s4-c9-recheck-*.txt` | VERIFIED_DERIVED (было VERIFIED_PRIMARY: текст ошибки общий — замечание Codex к PR #3 принято) |
| L3 | Соответствие SLSA Build L3 | GitHub: аттестации + reusable workflow дают L3; подписант = reusable workflow (V2) | VERIFIED_DERIVED (по документации GitHub + V2; независимого аудита платформы нет) |

Журнал отклонений: мой предварительный скрипт проверки версий в манифесте install-action дал ложное MISSING
(ошибка декодирования в самом скрипте; повторная проверка по raw-файлу: версии есть). Гейт сработал по неправильной причине — исправлено.
zizmor 1.32.0 предложил синтаксис `$/` для ссылки на свой reusable workflow — применён; работоспособность подтверждена прогоном 43716257897.

## L — Lean (2026-11-15)
Стадия L в `scripts/ci-local.sh` включается автоматически, если есть `lakefile.toml`.

| ID | Гейт | Что ловит |
|---|---|---|
| L0 / L0b | `lean-toolchain` в репозитории и версия Lean совпадает с ним | невоспроизводимая сборка |
| L1 | `lake build` | неверные доказательства |
| L2 | `#print axioms` для каждой теоремы, `sorryAx` = FAIL | «доказано» через sorry |
| L3 | нет `sorry`/`admit` в тексте | то же, грубая проверка |
| X1 / X2 | `proof-map.tsv`: каждая теорема сопоставлена Rust-тесту, тест существует и проходит | разрыв Rust↔Lean |
| CL1 / CL2 | канарейки: теорема с sorry, ложное доказательство — должны упасть по своей причине | неработающий гейт |

Граница: X1/X2 доказывают трассируемость и прохождение тестов, но НЕ семантическое соответствие модели коду
(соответствие в `proof-map.tsv` — утверждение владельца, ASSUMPTION до ревью).
Lean в CI: elan v4.2.4 и Lean 4.35.0 скачиваются с проверкой sha256 (digest Lean сверен с GitHub API).

## Не сделано (S5+)
Trusted Publishing (решение владельца: первая публикация в crates.io вручную), cargo-vet, MSRV, канарейка удаления main. Изменения в main — только через PR.
