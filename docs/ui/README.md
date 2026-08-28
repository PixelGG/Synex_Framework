# Synex UI documentation

`synex_ui` is the shared interface foundation for Synex. It has two deliberately
separate roles:

1. **`@synex/ui`** is a build-time React package. A resource imports its tokens,
   styles, and components into that resource's own NUI bundle.
2. **`synex_ui`** is a small FiveM client resource. It owns cross-resource focus
   arbitration, input routing, generic shared surfaces, lifecycle cleanup, and a
   bounded NUI transport.

It is not a central home for inventory, finance, character, vehicle, or other
domain state. `synex_control` also remains fully usable without `synex_ui` at
runtime.

> Status: **Experimental Alpha implementation candidate.** This label applies
> to the UI package and runtime only; it does not inherit the frozen Core
> Production-Beta decision.

## Guide

- [Overview](overview.md)
- [Architecture](architecture.md)
- [Design language](design-language.md)
- [Tokens](tokens.md)
- [Materials](materials.md)
- [Glass and transparency](glass.md)
- [Components](components.md)
- [Focus arbitration](focus.md)
- [Input model](input.md)
- [Gamepad](gamepad.md)
- [Accessibility](accessibility.md)
- [Transport and trust boundaries](transport.md)
- [Performance](performance.md)
- [Theming](theming.md)
- [Quality profiles](quality-profiles.md)
- [NUI safety](nui-safety.md)
- [Development and verification](development.md)

## Verification status

Static checks, unit/component tests, browser scenarios, and production builds
provide development evidence only. Real FiveM/CEF behavior, safe-zone mapping,
glass over moving gameplay, controller behavior, focus recovery, and measured
runtime performance are **not yet verified**. They remain required acceptance
gates before `synex_ui` can be described as live-approved.
