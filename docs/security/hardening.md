# Cfx hardening advisor

The hardening module is a read-only advisor. It reads selected ConVars, returns
bounded findings, and never changes configuration. The runtime injects a bounded
provider for buckets observed through player samples or Entity lifecycle events.
It reports at most 32 buckets and shows `unknown` unless explicit domain
metadata supplied a recognized lockdown mode.

## Current findings

| Setting | Advisor direction | Compatibility note |
| --- | --- | --- |
| `sv_filterRequestControl` | Mode 2 baseline; evaluate 3/4 | Stronger modes can break control-migration-dependent resources |
| `sv_pureLevel` | Consider 1 or 2 after review | Can reject legitimate client audio/graphics modifications |
| `sv_pure_verify_client_settings` | Consider `true` after artifact testing | Connection behavior must be verified |
| `sv_disableClientReplays` | Consider `true` when Rockstar Editor is not needed | Disables Rockstar Editor |
| `sv_stateBagStrictMode` | Consider only after ownership review | Can break intentional client state-bag writes |
| `sv_entityLockdown` | Consider `relaxed` or `strict` after entity-authoring review | Strict blocks every client-created entity |
| `sv_authMinTrust`, `sv_authMaxVariance` | Operator-defined review | Overly strict identity policy can reject legitimate clients |

Player or entity presence does not prove a bucket is controlled. The adapter
never calls a setter, never infers policy from ownership, and keeps
`controlled=false` unless explicit domain metadata says otherwise.

## Request-control semantics

The implementation records current reviewed semantics for modes `-1` through
`4`. Mode `0` is off; modes `1` through `3` progressively filter control
requests; mode `4` does not route the request-control event. The exact behavior
must still be confirmed against the deployed artifact and resource stack.

## Entity-lockdown artifact vocabulary

Current public OneSync documentation names the GTAV Enhanced dummy-object mode
`full`; some reviewed artifact/source vocabulary has used `no_dummy`. The advisor
recognizes both, reports either as artifact-specific compatibility input, and
never enables either value automatically.

`strict`, `relaxed`, and `inactive` retain their ordinary reviewed meanings.
Even a documented value must be tested with actual server-created and
client-created entity paths before rollout.

## Operational use

Findings appear through the read-only Security Control provider and doctor
output. Status values include `OK`, `REVIEW`, `ACTION_RECOMMENDED`,
`COMPATIBILITY_RISK`, and `UNKNOWN`.

Treat the output as configuration review input, not proof that a server is
secure. Apply changes manually in deployment configuration, one group at a time,
with rollback and compatibility tests.
