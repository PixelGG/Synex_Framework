# Interaction security boundary

`synex_interact` owns canonical interaction definitions, current actor/target
context, revisions, slots, policy, rate limits, and single-use Interaction
Leases. Security observes rejected attempts; it cannot issue a lease or execute
an Action Graph.

## Implemented integration

When a contract handler rejects a request and current session context is
available, Interact's observability layer makes a fail-open call to
`synex.security@1.reportSignal`.

The signal uses:

- namespace `synex.interact`;
- category `interaction`;
- detector `synex.interact.domain`;
- the stable Interact error code;
- the current session, source, source generation, user, and character;
- `DOMAIN_AUTHORITATIVE` evidence;
- bounded operation name only.

Replay-related codes receive medium severity; other denials are low severity in
this adapter. A trace ID is propagated where available.

## Fail-open means correctness stays local

"Fail-open" applies only to reporting. Interact has already denied the operation
before calling Security. If Security is missing, slow, degraded, or rejects the
signal, the denied interaction remains denied.

Security does not:

- accept a client ray hit as a canonical target;
- validate distance or entity/world generation;
- create, renew, consume, or revoke a lease;
- reserve a slot or actor lock;
- run an action node or domain adapter;
- authorize a side effect.

## Correlation

Repeated invalid/replayed leases, stale revisions, and policy denials can form an
interaction hypothesis. The signal normalizer deduplicates equivalent short-term
reports, and correlation decays them over the interaction window.

Routine denials can be caused by movement, contention, stale UI state, resource
restarts, or latency. They must not be treated as independent proof without
additional domain/server evidence.

## Current limits

Only denials that reach the context-aware observability call are reported. Many
internal defensive denials deliberately have no player context and remain local
metrics. Real join, reconnect, lease replay, range, and restart behavior remain
unverified for the Security integration.
