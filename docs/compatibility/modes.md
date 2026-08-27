# Modes and deployment

Mode is selected per explicitly configured consumer resource. It changes compatibility eligibility and warning behavior; it never bypasses capabilities, validation, mappings, native authority, or framework-conflict checks.

| Mode | Eligible catalog status | Deprecated surface | Resolver warnings |
| --- | --- | --- | --- |
| `strict` | `CERTIFIED`, `COMPATIBLE` | rejected | emitted |
| `compat` | `CERTIFIED`, `COMPATIBLE`, `PARTIAL` | allowed after all gates | warning-once |
| `silent` | `CERTIFIED`, `COMPATIBLE`, `PARTIAL` | allowed after all gates | suppressed |

Telemetry, terminal outcomes, security denials, and Core metrics remain active in `silent`. The resolver suppresses its optional warning-once entry, but each provider still emits its own bounded deprecation warning once per consumer/operation. `UNSUPPORTED` and `UNKNOWN` never become executable through a mode change.

All checked-in surfaces are currently deprecated and either `PARTIAL` or `UNSUPPORTED`. The checked-in consumer/profile catalogs are empty. Consequently, no compatibility call is enabled by default and `strict` cannot admit any current provider surface.

## Failure policy

Each consumer also selects one bounded failure policy:

- `warn`: report the resolution failure and keep the consumer configuration active;
- `disable`: disable that consumer for the current owner epoch after a resolution failure;
- `fail_start`: return the blocking failure to startup/integration code.

The policy does not convert an error into a successful legacy return.

## Deployment shapes

The experimental runtime implements these configuration-driven composition shapes; none has completed exact-candidate deployment acceptance:

- native Synex only: do not start compatibility providers;
- direct provider: start one or more provider resources and call their real Synex resource names;
- historical facade: also start the matching repository facade when a consumer requires the historical resource name;
- mixed providers: providers may be started together for non-conflicting consumer profiles while projecting the same canonical state. The coordinator evaluates both provider resource state and current lifecycle authorization. An eligible QB provider/consumer pair has priority for the shared global `QBCore:*` family; QBX is the fallback when QB is stopped, excluded, or denied. QBX retains its provider-local projection and its separately authorized `qbx_core:*` family. A running QB/QBX handoff is silent for the shared family and does not synthesize another unload/load transition.

Lifecycle eligibility also requires both provider and configured consumer resources to be `starting` or `started`. When the consumer selected for a provider stops, another eligible consumer receives publication authority without a synthetic unload/load pair. If none remains, the retained delivery follows the normal public unload path and may publish the corresponding load when an eligible consumer returns. A provider restart is handled separately: the new process rehydrates bounded active client projections with `resync = true` and suppresses duplicate public player-loaded events.

Client player-data and callback exports do not automatically follow from lifecycle mode. They require their own cataloged surfaces and appear only for active configured consumers that pass those exact gates. QB and ESX callback invocation additionally requires the same consumer's player-data and server callback-registration surfaces; callback-only profiles are incomplete. An empty player-data allowlist clears any retained projection and both lists. Likewise, every cataloged job, gang/group, duty, money, or account update-event family is independent from base lifecycle publication. These client allowlists are compatibility API admission, not client-side confidentiality or server authorization. This failover/recovery and surface-gating behavior is implemented and headless-tested, but still needs exact-candidate FXServer, facade, mixed-provider, callback/event, and real-client acceptance.

A real upstream framework using a historical name conflicts with the matching facade/provider and is rejected rather than shadowed.
