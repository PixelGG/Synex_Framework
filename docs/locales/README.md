# Synex README translations

English is the canonical README and the source of truth for every translation.
The current landing pages describe Synex `0.1.0` as experimental and the `synex_core` Production-Beta decision as **IN PROGRESS / NO-GO**. Final server outage/recovery, the automated closing run, documentation synchronization, final diff/secret review, and publication to `main` are PASS. Automation completed with 416 passed, 0 failed, 19 expected live-database skips, and 0 security findings. Only the client join/disconnect/reconnect smoke test remains pending.

The first candidate profile is deliberately limited to `synex_core` on Windows with FXServer build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, one active Core instance, strict production configuration, and `deny_new`. MySQL and multi-instance operation are not certified. `synex_groups`, `synex_accounts`, `synex_entities`, every other downstream resource, library, bridge, and example are experimental rework snapshots or scaffolds and remain outside Core certification.

Detailed release criteria and evidence boundaries stay canonical in English under [Release readiness](../release-readiness.md), [Testing](../testing.md), and [Known limitations](../known-limitations.md).

The 125-minute soak, permanent evidence runner, historical upgrade rehearsal, extended backup-and-restore rehearsal, and additional non-critical ABI tests are explicitly deferred to the work required to move beyond Beta. They are not blockers for this frozen Production-Beta decision.

| Code | Language | README |
| --- | --- | --- |
| `en` | English | [Canonical README](../../README.md) |
| `de` | Deutsch | [German translation](./de/README.md) |
| `fr` | Français | [French translation](./fr/README.md) |
| `es` | Español | [Spanish translation](./es/README.md) |
| `pt-BR` | Português Brasileiro | [Brazilian Portuguese translation](./pt-BR/README.md) |

Translations keep release maturity, Core-only scope, candidate profile, downstream rework status, commands, license, and documentation links synchronized. Detailed technical documentation remains canonical English under [`docs/`](../README.md).

Copyright &copy; 2026 PixelGG. Synex is licensed under the [GNU Affero General Public License v3.0 only](../../LICENSE).
