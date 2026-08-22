<p align="center">
  <img src="../../../.github/assets/branding/synex-mark.svg" width="88" height="88" alt="Marca Synex">
</p>

<h1 align="center">Synex</h1>

<p align="center">
  <strong>Un runtime FiveM contract-first y una base para recursos con responsabilidades independientes.</strong>
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
  <img alt="Versión: 0.1.0 experimental" src="https://img.shields.io/badge/release-0.1.0%20experimental-8b73ff?style=flat-square&amp;labelColor=111827">
</p>

<p align="center">
  <a href="https://discord.gg/heJU5t2Hfa">
    <img src="../../../.github/assets/readme/discord-community.svg" width="720" alt="Unirse al Discord oficial de Synex">
  </a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/hero.webp" width="1200" alt="Ilustración abstracta de la red modular Synex">
</p>

> [!CAUTION]
> **Versión de código experimental.** Synex `0.1.0` incluye recursos base ejecutables, contratos generados, migraciones, pruebas y herramientas. Todos los contratos públicos siguen marcados como `experimental`; todavía no existe una versión estable, instalador empaquetado ni garantía de soporte en producción.

## Base implementada

| Área | Módulo | Responsabilidad realmente presente | Estado |
| --- | --- | --- | --- |
| Kernel | [`synex_core`](../../../core/synex_core/) | Ciclo de arranque/sesión/personaje, contratos, RPC, eventos, hooks, servicios, capabilities, RBAC/acceso persistente, estado, fiabilidad, auditoría, métricas y salud | Experimental |
| Grupos | [`synex_groups`](../../../resources/synex_groups/) | Grupos, grados, reglas de capability, selección primaria y membresías versionadas | Experimental |
| Cuentas | [`synex_accounts`](../../../resources/synex_accounts/) | Monedas, cuentas de doble entrada, retenciones, roles de acceso, reversiones y modelos de integridad | Experimental |
| Entidades | [`synex_entities`](../../../resources/synex_entities/) | Identidad de entidad autoritativa en servidor, resolución persistente y routing buckets | Experimental |
| Operaciones | [`synex_control`](../../../resources/synex_control/) | NUI in-game de solo lectura con vistas Core/dominio limitadas, búsqueda exacta de auditoría y estado cerrado transparente | Experimental |
| Compatibilidad | [`synex_bridge`](../../../libraries/synex_bridge/) | Adaptadores QB/QBX/ESX opcionales ligados al consumidor, con callbacks limitados, transferencias cash/bank e importación revisada | Experimental / transición |
| Desarrollo | [`packages`](../../../packages/) / [`tools`](../../../tools/) | SDK Lua/TypeScript generados, CLI, analizadores, certificación y pruebas | Experimental |

Los adaptadores de compatibilidad no exponen objetos de jugador legacy mutables. Los cambios de dinero se ejecutan únicamente como transferencias Synex equilibradas mediante cuentas de contrapartida configuradas; las cuentas ausentes o ambiguas fallan de forma cerrada.

Synex vincula cada fachada API al recurso llamante real y a su epoch de inicio. Los contratos JSON definen versión, esquema, capability y dirección de red. Cada migración y tabla tiene un único propietario de dominio. Las entradas de cliente y NUI no son confiables.

### Límites solo reservados

`synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` y `synex_ui` contienen por ahora solo scaffolds y **no son funciones ejecutables**. El ciclo de personaje/sesión que sí existe está en `synex_core`.

## Inicio

Se necesita un FXServer actual, MariaDB/MySQL mediante `oxmysql >= 2.14.1` (y `< 3.0.0` cuando se habilita `synex_entities`), un `synex_instance_id` estable en producción estricta y OneSync `on` para `synex_entities`. Node.js se usa para herramientas y pruebas del repositorio, no para el runtime Lua.

```bash
npm ci
npm run check
npm test
npm run security
npm run certify
```

Este repositorio es un monorepo de desarrollo, no un paquete de servidor listo para copiar. La [guía de inicio](../../getting-started.md) cubre ubicación, configuración, migraciones, orden de arranque y límites.

## Documentación

El inglés es la fuente técnica canónica.

- [Índice de documentación](../../README.md)
- [Arquitectura](../../architecture/README.md)
- [API pública](../../api/README.md)
- [Seguridad](../../security/README.md)
- [Operaciones](../../operations.md)
- [Pruebas y CI](../../testing.md)
- [Compatibilidad](../../compatibility/README.md)

---

<p align="center"><sub>Synex Framework &middot; Contratos explícitos. Estado con propietario. Límites honestos.</sub></p>
