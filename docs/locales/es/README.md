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

El candidato exacto anterior `888a7326` superó el gate automatizado y las principales etapas de aceptación del servidor: arranque limpio del Core con 26 migraciones, prueba externa de las API públicas, reinicios preparados y no preparados del Core, caída completa del proceso con recuperación, corte fail-closed de la base de datos con recuperación mediante un reinicio completo de FXServer, copia/restauración y actualización real de la línea base `cd4b3cd5` de 25 a 26 migraciones. Sin embargo, el soak mínimo previsto de 120 minutos falló en la primera ejecución horaria del worker de retención del outbox, antes de completar la duración mínima, porque se rechazó una configuración de retención válida decodificada por Cfx.

- **EVIDENCIA DEL CANDIDATO ANTERIOR.** Las etapas de servidor, recuperación, copia/restauración y actualización indicadas pasaron para `888a7326`, pero el fallo posterior del soak impide considerarlas un PASS completo del candidato.
- **RECUPERACIÓN ACOTADA ANTE CORTES.** En la condición probada de callback perdido de oxmysql, la admisión de jugadores permanece cerrada. No se afirma una recuperación automática: tras restaurar el servicio de base de datos, los operadores deben reiniciar el proceso FXServer completo antes de reabrir la admisión.
- **ÁRBOL DE RUNTIME ACTUAL / IN PROGRESS.** La corrección introducida por `e0cbf45` acepta los contenedores de objeto JSON de Cfx confiables en la ruta de retención del outbox; las comprobaciones del repositorio y headless han pasado. La revisión limpia seleccionada después de la documentación todavía necesita el gate exacto de servidor, un nuevo soak de 120 minutos y la prueba del ciclo de vida del cliente. Hasta que las tres evidencias pasen, la decisión sigue siendo NO-GO y esta no es una beta estable para producción.
- **NO CERTIFICADO.** MySQL y la operación multiinstancia, incluido `kick_old`, quedan fuera del primer perfil candidato.
- **FUERA DE ALCANCE.** Cada recurso, biblioteca, bridge y ejemplo posterior a `synex_core` es un snapshot de rework experimental o un scaffold y no forma parte de la certificación del Core.

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
