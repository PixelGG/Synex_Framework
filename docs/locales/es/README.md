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
  <img alt="Madurez: experimental" src="https://img.shields.io/badge/maturity-experimental-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml?query=branch%3Amain"><img alt="Framework CI" src="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml/badge.svg?branch=main"></a>
  <a href="../../../LICENSE"><img alt="Licencia: AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/runtime-flow.svg" width="1200" alt="Flujo modular del runtime Synex">
</p>

> [!CAUTION]
> **Candidato Production-Beta del Core — IN PROGRESS / NO-GO.** Synex `0.1.0` sigue siendo una versión de código experimental. Solo `synex_core` se evalúa para el primer perfil Production-Beta y el candidato exacto actual todavía no ha completado todos los gates obligatorios. Los contratos públicos siguen marcados como `experimental`; no existe una versión estable ni una garantía de soporte en producción para todo el framework.

## Estado actual de validación

`synex_core` está en su ciclo final de aceptación Production-Beta. La línea de cierre de la beta está congelada: solo los cinco puntos siguientes pueden bloquear la decisión, salvo que aparezca un defecto crítico del producto.

| Punto de cierre | Estado actual |
| --- | --- |
| Prueba final de caída y recuperación de la base de datos | PASS |
| Ejecución automatizada completa de cierre | PASS — 416 aprobadas, 0 fallidas, 19 skips live-DB esperados; seguridad: 0 findings |
| Sincronización de toda la documentación del repositorio | PASS |
| Smoke test del cliente: conexión, desconexión y reconexión | PENDING |
| Revisión final del diff y secretos; commit y publicación en `main` | PASS |

- **CIERRE VERIFICADO.** La recuperación de la base de datos, la ejecución automatizada de cierre, la sincronización de la documentación, la revisión final del diff y los secretos, y la publicación en `main` están completas. La automatización pasó con 416 pruebas aprobadas, 0 fallidas, 19 skips live-DB esperados y 0 findings de seguridad.
- **SIN PASS ANTICIPADO.** Solo queda pendiente el smoke test del cliente para el candidato exacto. Hasta que conexión, desconexión y reconexión pasen, la decisión Production-Beta permanece **IN PROGRESS / NO-GO**.
- **NO CERTIFICADO.** MySQL y la operación multiinstancia, incluido `kick_old`, quedan fuera del primer perfil candidato.
- **FUERA DE ALCANCE.** Cada recurso, biblioteca, bridge y ejemplo posterior a `synex_core` es un snapshot de rework experimental o un scaffold y no forma parte de la certificación del Core.

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

### Primer perfil objetivo de aceptación

| Límite | Valor candidato |
| --- | --- |
| Producto | solo `synex_core` |
| Host | Windows |
| Runtime | FXServer build `35245` |
| Adaptador de base de datos | `oxmysql 2.14.1` |
| Base de datos | MariaDB `11.8.8`, hora de sesión UTC |
| Topología | una instancia Core activa |
| Política de producción | `synex_environment "production"`, `synex_strict "1"`, `synex_duplicate_policy "deny_new"` |

Estos valores definen el candidato; todavía no constituyen un PASS.

## Alcance de la beta del Core

| Área | Ruta | Función actual |
| --- | --- | --- |
| Candidato runtime | [`synex_core`](../../../core/synex_core/) | Arranque, conexiones, ciclos de sesión/personaje, contratos, RPC, eventos, hooks, servicios, capabilities, política de acceso persistente, estado, fiabilidad, auditoría, métricas, salud y migraciones propias |
| Pipeline de contratos | [`packages/contracts`](../../../packages/contracts/) | Entradas canónicas y artefactos runtime/referencia generados de forma determinista para desarrollar el Core |
| SDK y herramientas | [`packages`](../../../packages/) / [`tools`](../../../tools/) | Clientes/tipos generados, validación, migración, seguridad, certificación y pruebas; no son funciones de servidor certificadas por separado |

Solo `core/synex_core` puede llegar a Production-Beta-ready en el ciclo actual. La API pública del Core seguirá siendo experimental aunque el gate beta pase.

### Límite de rework posterior

`synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, todos los directorios posteriores o independientes de `resources/`, todas las bibliotecas y bridges de `libraries/` (incluido `synex_bridge`) y los ejemplos ejecutables son **snapshots de rework experimentales o scaffolds**. Quedan completamente excluidos de la beta del Core y no deben iniciarse, empaquetarse ni anunciarse como componentes certificados. El comportamiento posterior que depende de OneSync también queda fuera de este perfil Core-only.

También incluye `synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` y `synex_ui`. La presencia de un directorio no demuestra una función terminada. El ciclo de personaje/sesión existente pertenece a `synex_core`.

## Inicio

El primer perfil candidato requiere Windows, FXServer build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, un `synex_instance_id` estable y único, modo de producción estricto y `deny_new`. Node.js `>=22.12.0` con npm `>=10.0.0` se usa para herramientas y pruebas del repositorio, no para el runtime Lua.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

Estos comandos son gates de desarrollo y por sí solos no prueban una Production-Beta. El repositorio sigue siendo un monorepo de desarrollo, no un paquete de servidor listo para copiar. Para el primer candidato, despliega únicamente `oxmysql` y `synex_core`. Consulta la [guía de inicio](../../getting-started.md), el [ejemplo de configuración del Core](../../../examples/server.cfg.example) y el [gate de release](../../release-readiness.md).

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
