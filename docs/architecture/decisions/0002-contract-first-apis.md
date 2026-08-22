# ADR-0002: Contract-first public APIs

Status: Accepted

## Decision

Define public operations in canonical JSON, generate Lua and TypeScript SDKs deterministically, and validate at runtime. Keep internal functions private and expose no mutable aggregate object.

## Consequences

Compatibility can be checked before deployment. Code generation is a required CI check. A contract definition does not grant permission to call it.
