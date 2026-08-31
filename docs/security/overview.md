# Security overview

`synex_security` is a server-side evidence and policy layer for Synex. It is not
a collection of secret client checks and it is not a repair layer for unsafe
domain handlers.

## Purpose

The resource provides a common path for four classes of input:

1. deterministic denials and integrity findings emitted by Core or a domain;
2. server-derived observations such as bounded position history;
3. supported Cfx server events;
4. advisory client telemetry from the Sentinel.

Every accepted observation becomes a canonical `SecuritySignal`. Active,
resource-owned expectations identify unusual states that are currently allowed.
The correlation engine groups non-expected signals by subject and hypothesis,
collapses related root events, applies evidence weights and time decay, and can
open or update a bounded security case. Enforcement is a separate policy step.

## Authority boundaries

| Concern | Authoritative owner | Security role |
| --- | --- | --- |
| Session and source generation | `synex_core` | Reject stale subjects |
| Capability and contract admission | `synex_core` | Consume denial findings |
| Financial truth | `synex_accounts` | Correlate domain signals |
| Entity identity and lifecycle | `synex_entities` | Consult authority; guard Cfx creation |
| World transitions and routing context | `synex_world` | Honor bounded expectations |
| Interaction leases and target validation | `synex_interact` | Correlate rejected/replayed operations |
| Access bans | Core Access | Request a ban through the existing API |

Security never writes an account ledger, invents an EntityRef, grants a World
transition, validates an interaction effect, or stores a second ban record.

## Runtime shape

The manifest declares `synex_core` and OneSync as required dependencies.
`synex_entities` and `synex_world` supply bounded lifecycle events, while
Accounts, Entities, Interact, and World call the capability-gated Security
service for denials or expectations they own. Security does not acquire their
optional services. Runtime binding is owner-epoch aware: a resource restart
invalidates its old expectation ownership, while a Core restart causes Security
to rebind.

The resource owns only:

- `synex_security_cases`;
- `synex_security_case_signals`;
- `synex_security_enforcements`.

Signals and expectations use bounded in-process registries. Only bounded case,
case-signal, and enforcement summaries are intended for durable storage. There
is no raw packet capture, client memory collection, or full movement archive.

## Default operating posture

`config/default.json` selects the conservative profile:

- automatic kick: disabled;
- automatic ban: disabled;
- heuristic detector families: observe;
- client telemetry: advisory;
- transport, entity, and game-event mode: `MITIGATE`; transport findings remain
  evidence/case inputs, while the default Cfx policy keeps burst cancellation
  and projectile/PTFX cancellation disabled and all deny catalogs empty;
- weak evidence cannot independently justify strong enforcement.

Changing a detector to a stronger mode does not make weak evidence
authoritative. Subject freshness, evidence requirements, policy thresholds, and
action availability are still checked immediately before an action.

## Operations surface

Health reports `READY`, `DEGRADED`, or `UNHEALTHY` with bounded reason codes.
The read-only Control provider exposes summary, health, detector, case, player,
hardening, metric, and Doctor views without mutation controls or raw client
telemetry. Core metrics are emitted below the `synex_security_` namespace. They
cover accepted and deduplicated signals, created/open cases, active
expectations, missing Sentinel samples, detector-family anomalies, Cfx
mitigations, blocked entity events, enforcement actions, kicks, and bans. Metric
labels use only closed category, evidence-class, and action vocabularies—never a
player, case, signal, entity, session, or resource identifier.

## Maturity

The implementation is **Experimental / Alpha**. Pure Lua tests cover core
algorithms and port-level behavior. Real FXServer event semantics, OneSync state,
MariaDB persistence/recovery, resource restart behavior, and live gameplay
calibration are open acceptance gates. See [Development](development.md).
