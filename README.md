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

## Не сделано (следующие шаги S3+)
SHA-pinned GitHub workflow + zizmor, Trusted Publishing, build provenance, SBOM, cargo-vet.
