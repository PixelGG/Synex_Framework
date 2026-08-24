# Contracts and API stability

Canonical JSON contract definitions under `packages/contracts` describe request and response schemas, versions, capability requirements, network exposure, idempotency, lifecycle states, and payload limits. Generated Lua and TypeScript artifacts are reproducible build outputs and carry their source checksum.

All public contracts in `0.1.0` remain `experimental`. Semantic versions describe compatibility negotiation inside the current source tree; they do not make a contract stable or add a downstream provider to `synex_core` Production-Beta certification. Contracts owned by groups, accounts, entities, bridges, examples, or other non-Core components may change with their rework.

Public contracts use canonical semantic versions. Stable ranges do not select prerelease providers, and prerelease identifiers follow SemVer numeric precedence rather than lexical ordering.

Compatibility policy:

- Patch releases clarify metadata without changing accepted data.
- Minor releases may add optional fields and compatible operations.
- Major releases are required for removed fields, narrower accepted inputs, changed meaning, or incompatible errors.

Runtime providers and consumers negotiate compatible majors. Unknown fields are rejected at security-sensitive boundaries unless a contract explicitly permits them. Generated code must not contain timestamps, absolute paths, current working directories, or nondeterministic ordering.

## Result model

Internal Core operations and provider-local logic use `value, nil` for success or `nil, error` for failure. Errors have a stable shape:

```text
code, message, traceId?, retryable, details?
```

Raw cross-resource Cfx calls cannot safely transport a `nil` hole before a later meaningful return. Synex therefore substitutes `false` only for those intervening slots: a failure crosses as `false, error`, `value, nil` remains effectively unchanged, and `value, nil, metadata` crosses as `value, false, metadata`. The second slot is authoritative: a truthy value is an error, while `nil` or `false` means no error. This wire convention does not change the internal result model.

Internal exception text and database details are never returned to clients. Generated TypeScript exposes operation-specific input, output, and error types; the host-provided transport remains responsible for how it represents a failed delivery or returned error.

## Stability boundary

Only the three Core ABI exports and their documented caller-bound facade are part of the current Core candidate's integration boundary, and that boundary is still experimental in `0.1.0`. Versioned contracts/services and generated SDK surfaces are public in the source-level sense but remain outside Production-Beta support. Internal factory tables, registries, persistence adapters, and resource-local events may change without compatibility guarantees.
