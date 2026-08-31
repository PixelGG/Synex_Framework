# Enforcement

Enforcement is a policy-separated final stage. Detectors emit evidence; they do
not call kick or ban directly.

## Action ladder

```text
OBSERVE -> CORRECT -> MITIGATE -> RESTRICT -> KICK -> BAN
                       \-> MANUAL_REVIEW
```

- `OBSERVE` records the case only.
- `CORRECT` invokes a configured corrective handler.
- `MITIGATE` invokes a bounded immediate mitigation handler.
- `RESTRICT` invokes a configured temporary restriction handler.
- `KICK` requires a current connected source and an available kick handler.
- `BAN` requires a durable user identity and delegates to Core Access.
- `MANUAL_REVIEW` changes the case review posture without a destructive action.

The engine supplies the policy mechanism; an action is unavailable unless the
runtime provides its handler.

The current runtime registers no `CORRECT`, `MITIGATE`, or `RESTRICT` handler;
such a decision therefore fails closed as unavailable. `KICK` and Core Access
`BAN` handlers exist, but the committed automatic flags are disabled.

## Policy evaluation

A closed policy specifies mode and ordered rules. Rules can require minimum
confidence, minimum severity, independent evidence count, evidence classes, a
reason, and optional duration.

`MITIGATE` mode permits only observe, correct, mitigate, and manual review.
`ENFORCE` mode may select the full ladder. `DISABLED` and `OBSERVE` cannot select
a strong action.

Weak-only evidence is structurally downgraded from restrict/kick/ban to manual
review. A missing user, a user reference outside Core Access's 8–36 byte
identity contract, or a missing source for kick has the same result.

## Last-moment subject validation

Immediately before every actual action, the engine invokes an authoritative
subject validator. A stale session, changed source generation, disconnected
source, or unavailable validator blocks the action with
`SECURITY_SUBJECT_STALE` or a retryable validation error.

This check is repeated at action time because case assessment and enforcement
may be separated by yields or queueing.

## Idempotency

The decision key is derived from case ID, policy ID, action, reason, and the
authoritative subject, but deliberately not from the mutable case revision.
Applied records are retained in a bounded idempotency registry for 24 hours.
New evidence or a case-state revision therefore cannot repeat the same action;
an explicit policy/action change can produce a distinct decision. Repeating the
same decision returns the prior result and does not invoke the handler twice.
Durable enforcement rows also enforce a unique idempotency key.
Before an irreversible kick or ban, the decision, case revision, UTC decision
time, expiry, and stable provenance digest must be reserved successfully. If
that durable reservation is unavailable, the action is not executed. After a
successful action the same row is advanced to `APPLIED`; a persistence conflict
is surfaced as degraded health rather than hidden.

The generated idempotency key, deterministic ban ID, user reference, printable
reason, and expiry format are fenced to Core Access's public bounds before the
call. Temporary ban rules require at least 60 seconds at decision time and at
least 30 seconds remaining at dispatch. A duplicate nonterminal reservation is
quarantined rather than treated as permission to repeat the external action.

A process can stop after an external action but before its `APPLIED` projection
commits. On the next Security start, every bounded leftover `DECIDED` row is
atomically changed to `INDETERMINATE`. It is never replayed automatically and
the runtime remains degraded until an operator reconciles the outcome. This is
intentional: the database alone cannot prove whether the external kick or ban
already happened. Control is intentionally read-only and this resource exposes
no mutation resolver; a separately authorized administrative reconciliation
workflow remains future work.

## Ban boundary

`BAN` calls Core's existing `api.Access.ban` facade with a bounded reason,
idempotency key, durable user ID, and optional UTC expiry. Security does not
create a ban table, mutate Core access tables, or implement identifier matching.
Core Access remains the single ban authority and audit boundary.

## Default posture

The committed profile sets `automaticKick` and `automaticBan` to `false`.
Heuristic and Sentinel families are observe-first. No production enforcement
policy has been live-calibrated, so the resource remains Experimental / Alpha.
