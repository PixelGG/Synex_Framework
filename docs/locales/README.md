# Synex README translations

English is the canonical README and the source of truth for every translation.
The current landing pages describe the frozen `synex_core` baseline as **Production Beta** for one exact Core-only profile. Acceptance was completed on 2026-08-25 for Core commit `7ad4b72ee9bcd0a2a0481cfacfe5f807eb1b3ec5` and Core tree `9f0960f1e27fe43195ae4602cb2ef447cbc0509b`. Server outage/recovery, the automated closing run, documentation synchronization, final review, and the live client join/disconnect/reconnect smoke test are PASS. Automated closure included `npm run check`, 416 passed tests, 0 failures, 19 expected live-database skips, 0 security findings, and 0 audit vulnerabilities. The live run completed all nine ordered connection stages, Doctor returned `PASS`, 26/26 migrations were applied, and final cleanup left 3 closed sessions, 0 open sessions, and 0 active session or admission leases. Current Core domain-persistence/deletion additions are later candidate work and do not inherit that decision.

The accepted profile is deliberately limited to `synex_core` on Windows with FXServer build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, one active Core instance, strict production configuration, and `deny_new`. MySQL and multi-instance operation are not certified. Synex `0.1.0` and its public Core contracts remain experimental; this is not Stable/1.0 or framework-wide readiness. `synex_groups` is an Experimental Alpha Organizations Engine with separate working-tree evidence and open acceptance items. `synex_accounts` is a server-only Experimental Alpha Financial Engine; its current working tree passed the isolated MariaDB 11.8.8 database scope 104/104 on 2026-08-28, while FXServer, restart/recovery, restored-upgrade, exact-candidate, and maturity acceptance remain open. `synex_entities` is a server-only Development / Experimental Alpha Entity Authority Engine with repository implementation present; fresh MariaDB, live FXServer/OneSync, restart/recovery, cluster, real-client/Control, and exact-candidate acceptance remain open. `synex_world` is a Development / Experimental Alpha semantics and spatial-authority candidate whose MariaDB, FXServer/OneSync, native client and restart acceptance remains open. Its read-only `synex_control` projection is experimental. `synex_ui` is implemented as an Experimental Alpha UI foundation, but its real FiveM/CEF acceptance remains open. Every otherwise unlisted later downstream resource, library, bridge, and example remains pending rework. None is included in Core certification.

The optional read-only `synex_control` operations surface is implemented as Development / Experimental Alpha with automated provider, transport, sanitizer, and NUI source gates. Its real FXServer provider lifecycle and CEF/client smoke acceptance remain open; those automated checks are not a maturity promotion.

`synex_ui` is implemented as an Experimental Alpha build-time React package plus a separate FiveM client runtime. Automated type, unit/component, browser, build, transport, and closed-state checks do not replace its still-open real FiveM/CEF, safe-zone, controller, focus-recovery, gameplay-readability, and performance acceptance. It is not part of the frozen Core certification.

Detailed release criteria and evidence boundaries stay canonical in English under [Release readiness](../release-readiness.md), [Testing](../testing.md), and [Known limitations](../known-limitations.md).

The 125-minute soak, permanent evidence runner, historical upgrade rehearsal, extended backup-and-restore rehearsal, and additional non-critical ABI tests are explicitly deferred to the work required to move beyond Beta. They are not blockers for this frozen Production-Beta decision.

| Code | Language | README |
| --- | --- | --- |
| `en` | English | [Canonical README](../../README.md) |
| `de` | Deutsch | [German translation](./de/README.md) |
| `fr` | Français | [French translation](./fr/README.md) |
| `es` | Español | [Spanish translation](./es/README.md) |
| `pt-BR` | Português Brasileiro | [Brazilian Portuguese translation](./pt-BR/README.md) |

Translations keep release maturity, Core-only scope, accepted profile, downstream implementation and rework status, commands, license, and documentation links synchronized. Detailed technical documentation remains canonical English under [`docs/`](../README.md).

Copyright &copy; 2026 PixelGG. Synex is licensed under the [GNU Affero General Public License v3.0 only](../../LICENSE).
