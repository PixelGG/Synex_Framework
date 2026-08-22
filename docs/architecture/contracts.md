# Contracts and API stability

Canonical JSON contract definitions under `packages/contracts` describe request and response schemas, versions, capability requirements, network exposure, idempotency, lifecycle states, and payload limits. Generated Lua and TypeScript artifacts are reproducible build outputs and carry their source checksum.

Public contracts use canonical semantic versions. Stable ranges do not select prerelease providers, and prerelease identifiers follow SemVer numeric precedence rather than lexical ordering.

Compatibility policy:

- Patch releases clarify metadata without changing accepted data.
- Minor releases may add optional fields and compatible operations.
- Major releases are required for removed fields, narrower accepted inputs, changed meaning, or incompatible errors.

Runtime providers and consumers negotiate compatible majors. Unknown fields are rejected at security-sensitive boundaries unless a contract explicitly permits them. Generated code must not contain timestamps, absolute paths, current working directories, or nondeterministic ordering.

## Result model

Lua operations return either `value, nil` or `nil, error`. Errors have a stable shape:

```text
code, message, traceId?, retryable, details?
```

Internal exception text and database details are never returned to clients. Generated TypeScript exposes operation-specific input, output, and error types; the host-provided transport remains responsible for how it represents a failed delivery or returned error.

## Stability boundary

Only the three Core ABI exports, their documented caller-bound facade, versioned contracts/services, and generated SDK surfaces are public. Internal factory tables, registries, persistence adapters, and resource-local events may change without compatibility guarantees.
