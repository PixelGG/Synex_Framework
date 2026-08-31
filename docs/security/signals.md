# Security signals

`SecuritySignal` is the canonical, bounded observation primitive.

## Shape

An accepted signal records:

```text
signalId, ownerResource, ownerEpoch, namespace
category, detector, code
subjectSession?, subjectSource?, sourceGeneration?
subjectUser?, subjectCharacter?, subjectResource?
severity, confidence, evidenceClass, observedAt
correlationKey, traceId?, rootEventId?, requestId?
worldRef?, entityRef?, summary, evidence?
```

Subjects may represent a current session, user, character, or resource. A
session subject carries its source generation and may carry the current source.
The runtime rechecks session subjects before accepting them.

## Closed classifications

Categories are limited to:

```text
transport, economy, inventory, interaction, movement, combat,
player_integrity, entity, weapon, world, client_integrity,
resource_integrity, connection
```

Severity is one of `INFO`, `LOW`, `MEDIUM`, `HIGH`, or `CRITICAL`.
Evidence class is one of the six classes described in [Evidence](evidence.md).

The detector name must remain inside the signal namespace, and the namespace
must belong to the calling resource. The error code uses an uppercase stable-code
format. Caller identity and owner epoch come from Core context, not request data.

## Bounds

- summary: at most 192 bytes;
- evidence: at most 4,096 encoded bytes, depth 6, 64 entries, 512 bytes per
  string;
- complete signal: at most 8,192 encoded bytes;
- volatile signal registry: 4,096 entries;
- per subject: 256 entries;
- retention: one hour;
- duplicate window: five seconds.

Metatable-backed Cfx JSON containers are accepted only when their metadata is the
known `__jsontype` marker. Cycles, unsupported keys, non-finite numbers, unknown
fields, oversized values, and stale identities are rejected.

## Deduplication and roots

Deduplication combines subject, owner, detector, code, and the best available
event root (`rootEventId`, `requestId`, or `traceId`). When none exists,
`correlationKey` is the fallback; a fixed empty marker is used only if that key
is also absent. A repeat within five seconds returns the original signal
identity instead of creating another observation.

Correlation uses the same root references to ensure one underlying event cannot
be counted several times merely because multiple derived signals were emitted.
`correlationKey` groups observations into a hypothesis; it is not evidence that
two observations came from independent events.

## Emission

Resource callers use `synex.security@1.reportSignal` or the matching server
contract and require `synex.security.signal.emit`. The request is owner- and
namespace-bound. Internal detectors use the same normalizer.

Domains should emit a signal only after their authoritative handler has denied
or classified an operation. Evidence must contain bounded facts, never secrets,
full requests, raw network captures, SQL details, or arbitrary client dumps.

## Durability

The in-memory signal registry is not a permanent telemetry archive. Signals
attached to a case may be stored as bounded summaries in
`synex_security_case_signals`. The implementation intentionally has no database
table for unrestricted raw telemetry.
