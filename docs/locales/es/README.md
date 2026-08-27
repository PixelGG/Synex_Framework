<p align="center">
  <img src="../../../.github/assets/branding/synex-mark.svg" width="96" height="96" alt="Marca Synex">
</p>

<h1 align="center">Synex</h1>

<p align="center">
  <strong>Un Core de FiveM contract-first con responsabilidades explícitas y límites fail-closed.</strong>
</p>

<p align="center">
  <a href="../../../README.md">EN</a>
  &nbsp;&middot;&nbsp;
  <a href="../de/README.md">DE</a>
  &nbsp;&middot;&nbsp;
  <a href="../fr/README.md">FR</a>
  &nbsp;&middot;&nbsp;
  <strong>ES</strong>
  &nbsp;&middot;&nbsp;
  <a href="../pt-BR/README.md">PT-BR</a>
</p>

<p align="center">
  <img alt="Objetivo: FiveM" src="https://img.shields.io/badge/target-FiveM-5ed7ff?style=flat-square&amp;labelColor=111827">
  <img alt="Versión: 0.1.0" src="https://img.shields.io/badge/version-0.1.0-4b94ff?style=flat-square&amp;labelColor=111827">
  <img alt="Madurez del Core: Production Beta" src="https://img.shields.io/badge/core-Production--Beta-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml?query=branch%3Amain"><img alt="Framework CI" src="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml/badge.svg?branch=main"></a>
  <a href="../../../LICENSE"><img alt="Licencia: AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/runtime-flow.svg" width="1200" alt="Flujo modular del runtime Synex">
</p>

> [!IMPORTANT]
> **Synex Core — PRODUCTION BETA.** El candidato exacto de `synex_core` ha superado el primer perfil Production-Beta limitado al Core. Synex `0.1.0` sigue siendo una versión de código experimental con contratos públicos marcados como `experimental`. Esto no es una versión Stable/1.0, una declaración de preparación de todo el framework ni una garantía general de soporte en producción.

## Estado actual de validación

`synex_core` superó la línea de aceptación Production-Beta congelada el **25-08-2026** para el perfil exacto indicado más abajo. La decisión solo se aplica al commit del Core `7ad4b72ee9bcd0a2a0481cfacfe5f807eb1b3ec5` y al árbol del Core `9f0960f1e27fe43195ae4602cb2ef447cbc0509b`. Las incorporaciones actuales del Core para persistencia de dominios y borrado coordinado son trabajo candidato posterior y no heredan esa aceptación.

| Punto de cierre | Estado actual |
| --- | --- |
| Prueba final de caída y recuperación de la base de datos | PASS |
| Ejecución automatizada completa de cierre | PASS — `npm run check`; 416 aprobadas, 0 fallidas, 19 skips live-DB esperados; seguridad: 0 findings; auditoría: 0 vulnerabilidades |
| Sincronización de toda la documentación del repositorio | PASS |
| Smoke test del cliente: conexión, desconexión y reconexión | PASS — pipeline de conexión ordenado en nueve etapas, desconexión limpia, reconexión y limpieza final |
| Revisión final del diff y secretos; commit y publicación en `main` | PASS |

- **PRODUCTION-BETA ACEPTADA.** La recuperación tras la caída de la base de datos, el cierre automatizado, la sincronización de la documentación, el smoke test del cliente, la revisión final y los gates de publicación pasaron para el perfil exacto limitado al Core.
- **CLIENTE REAL VERIFICADO.** La conexión completó las nueve etapas en el orden previsto, seguida de una desconexión limpia y una reconexión correcta. Doctor devolvió `PASS`, se aplicaron las 26 migraciones y la limpieza final dejó 3 sesiones cerradas, 0 sesiones abiertas y 0 leases activos de sesión o admisión.
- **MADUREZ LIMITADA.** Esta aceptación no convierte Synex en Stable/1.0, no certifica todo el framework y no cambia los contratos públicos del Core de `experimental`.
- **NO CERTIFICADO.** MySQL y la operación multiinstancia, incluido `kick_old`, quedan fuera del perfil Production-Beta aceptado.
- **FUERA DE ALCANCE.** `synex_groups` y `synex_accounts` son engines independientes en Experimental Alpha. `synex_entities` es una Entity Authority Engine solo para servidor en Development / Experimental Alpha; su implementación está presente en el repositorio, pero siguen pendientes las aceptaciones reales de MariaDB, FXServer/OneSync, reinicio/recuperación, clúster, cliente/Control y del candidato exacto. La proyección Entity de solo lectura en `synex_control` es experimental. `synex_bridge` está implementado como Compatibility Platform Experimental Alpha fail-closed, pero aún no tiene aceptación real. Los demás recursos, bibliotecas y ejemplos son snapshots de rework o scaffolds. Ninguno forma parte de la certificación congelada del Core.

El `synex_control` opcional y de solo lectura está implementado como superficie operativa Development / Experimental Alpha con pruebas automatizadas de provider, transporte, sanitizer y NUI. Siguen pendientes el ciclo de vida real de providers en FXServer y la aceptación CEF/cliente; las pruebas automatizadas no elevan su madurez.

<details>
<summary>Hardening posterior a la beta — explícitamente fuera de este gate de aceptación</summary>

- soak de 125 minutos
- runner permanente de evidencias
- ensayo histórico de actualización
- ensayo ampliado de copia de seguridad y restauración
- pruebas ABI no críticas adicionales

Estas comprobaciones pertenecen al trabajo necesario para salir de la beta más adelante. No amplían la línea de cierre Production-Beta congelada.

</details>

[Gate de release](../../release-readiness.md) &middot; [Cobertura de pruebas](../../testing.md) &middot; [Limitaciones conocidas](../../known-limitations.md)

### Perfil Production-Beta aceptado

| Límite | Valor aceptado |
| --- | --- |
| Producto | solo `synex_core` |
| Host | Windows |
| Runtime | FXServer build `35245` |
| Adaptador de base de datos | `oxmysql 2.14.1` |
| Base de datos | MariaDB `11.8.8`, hora de sesión UTC |
| Topología | una instancia Core activa |
| Política de producción | `synex_environment "production"`, `synex_strict "1"`, `synex_duplicate_policy "deny_new"` |

La decisión Production-Beta solo es válida dentro de estos límites. Otras plataformas, versiones de dependencias, topologías o políticas requieren evidencias de aceptación independientes.

## Alcance de la beta del Core

| Área | Ruta | Función actual |
| --- | --- | --- |
| Runtime del Core aceptado | [`synex_core`](../../../core/synex_core/) | Arranque, conexiones, ciclos de sesión/personaje, contratos, RPC, eventos, hooks, servicios, capabilities, política de acceso persistente, estado, fiabilidad, auditoría, métricas, salud y migraciones propias |
| Pipeline de contratos | [`packages/contracts`](../../../packages/contracts/) | Entradas canónicas y artefactos runtime/referencia generados de forma determinista para desarrollar el Core |
| SDK y herramientas | [`packages`](../../../packages/) / [`tools`](../../../tools/) | Clientes/tipos generados, validación, migración, seguridad, certificación y pruebas; no son funciones de servidor certificadas por separado |

Solo `core/synex_core` está aceptado como Production-Beta-ready para el perfil exacto anterior. La API pública del Core sigue siendo experimental.

### Límite de madurez downstream

`synex_groups` es la Organizations Engine en Experimental Alpha. El catálogo actual contiene 71 contratos de Groups y 31 migraciones: 70 contratos son locales del servidor y solo `synex.groups.self.snapshot` es una proyección de cliente limitada y vinculada a la sesión. La evidencia live anterior precede a la migración `032`; las pruebas actuales de cliente, candidato y madurez siguen pendientes. `synex_accounts` es ahora una Financial Engine Experimental Alpha solo para servidor, con 59 contratos locales y 17 migraciones. La implementación automatizada está ampliamente completa, pero se han aplazado expresamente las pruebas reales de MariaDB, FXServer, reinicio/recuperación, actualización y candidato exacto. Accounts no tiene superficie cliente ni NUI; el gameplay y la UI pertenecerán posteriormente a `synex_banking`. `synex_entities` es una Entity Authority Engine solo para servidor en Development / Experimental Alpha, con 33 definiciones de contrato versionadas bajo 32 nombres y cuatro migraciones propias. La implementación y las regresiones del repositorio están presentes; siguen pendientes las aceptaciones reales de MariaDB, FXServer/OneSync, reinicio/recuperación, clúster, cliente/Control y del candidato exacto. La proyección Entity de solo lectura en `synex_control` está implementada, pero es experimental. `synex_bridge` tiene proveedores QB/QBX/ESX separados, pero sigue en Experimental Alpha sin aceptación exacta de FXServer/cliente. Los recursos posteriores, demás bibliotecas y ejemplos ejecutables siguen siendo snapshots de rework o scaffolds. Ninguno forma parte de la beta del Core.

También incluye `synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` y `synex_ui`. La presencia de un directorio no demuestra una función terminada. El ciclo de personaje/sesión existente pertenece a `synex_core`.

## Inicio

El perfil Production-Beta aceptado requiere Windows, FXServer build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, un `synex_instance_id` estable y único, modo de producción estricto y `deny_new`. Node.js `>=22.12.0` con npm `>=10.0.0` se usa para herramientas y pruebas del repositorio, no para el runtime Lua.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

Estos comandos son gates de desarrollo y por sí solos no prueban una Production-Beta. El repositorio sigue siendo un monorepo de desarrollo, no un paquete de servidor listo para copiar. Para el perfil aceptado, despliega únicamente `oxmysql` y `synex_core`. Consulta la [guía de inicio](../../getting-started.md), el [ejemplo de configuración del Core](../../../examples/server.cfg.example) y el [gate de release](../../release-readiness.md).

## Documentación

El inglés es la fuente técnica canónica.

- [Índice de documentación](../../README.md)
- [Gate Production-Beta del Core](../../release-readiness.md)
- [Limitaciones conocidas](../../known-limitations.md)
- [Copia de seguridad y restauración](../../backup-and-restore.md)
- [Arquitectura](../../architecture/README.md)
- [API pública](../../api/README.md)
- [Seguridad](../../security/README.md)
- [Política de seguridad](../../../SECURITY.md)
- [Operaciones](../../operations.md)
- [Pruebas y CI](../../testing.md)

## Comunidad

Las conversaciones de desarrollo, los comentarios de implementación y las actualizaciones del framework están disponibles en la comunidad oficial de Synex.

<p align="center">
  <a href="https://discord.gg/heJU5t2Hfa">
    <img src="../../../.github/assets/readme/discord-community.svg" width="720" alt="Unirse al Discord oficial de Synex">
  </a>
</p>

## Licencia

Copyright &copy; 2026 PixelGG. Synex se distribuye exclusivamente bajo la [GNU Affero General Public License v3.0](../../../LICENSE).

---

<p align="center"><sub>Synex Framework &middot; Contratos explícitos. Estado con propietario. Límites honestos.</sub></p>
