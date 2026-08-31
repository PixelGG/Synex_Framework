# Security cases

A case is a revisioned, bounded summary of one subject/hypothesis. It is not a
raw telemetry archive and does not itself apply a punishment.

## States

```text
OPEN -> MONITORING | REVIEW | ENFORCED | CLOSED
MONITORING -> OPEN | REVIEW | ENFORCED | CLOSED
REVIEW -> MONITORING | ENFORCED | CLOSED
ENFORCED -> REVIEW | CLOSED
CLOSED -> explicit reopen only
```

Every transition requires the current case revision and a bounded reason. A
closed case receives a close timestamp and leaves the active hypothesis index.
Reopen is explicit, revision-bound, and rejected if another active case already
tracks the same subject/hypothesis.

## Case content

The engine stores:

- case, subject, session/source generation, and hypothesis references;
- category, severity, current and peak confidence;
- state, revision, and UTC timestamps;
- a bounded signal summary with count, stable codes, and first/last time;
- a bounded evidence summary with independent roots, evidence classes,
  weak-only flag, and expectation-filter count;
- a bounded enforcement summary.

Opening requires a valid hypothesis at or above the case threshold. A later
assessment updates the active case and normally advances `OPEN` to
`MONITORING`. Severity retains the higher observed value; confidence tracks the
current hypothesis while peak confidence is retained.

## Persistence

Migration `001_security.sql` creates:

- `synex_security_cases` for the case projection;
- `synex_security_case_signals` for bounded attached signal summaries;
- `synex_security_enforcements` for idempotent enforcement records.

Signal and enforcement rows use foreign keys to the case. JSON columns are
validated by database checks. The repository uses parameterized statements and
bounded JSON encoding. A case projection and its contributing signals are
committed in one transaction; completion of an applied enforcement and the
resulting case projection are also committed together. Duplicate signal IDs
are accepted only when they already belong to the same case. It does not
persist unrestricted movement samples or raw client telemetry.

An enforcement row left in `DECIDED` across a Security restart is quarantined
as `INDETERMINATE`, exposed through health/Doctor and never automatically
replayed. Manual reconciliation is required because an external action and its
database completion cannot be made one atomic operation.

The configured general retention is 90 days and closed-case retention is 30
days, with bounded maintenance deletion. Real MariaDB migration, restore, and
retention behavior for this resource remain open acceptance gates.

Startup restore reads the complete bounded active-case capacity (4,096) plus
one detection row and the 256 most recently updated closed cases. More than
4,096 open cases produces an explicit degraded backlog error instead of
silently truncating active state. The restored closed archive preserves the
explicit-reopen fence across a Security resource restart for that bounded
window. A direct case inspection can fall back to its persisted summary after
the archive no longer contains it.

## Privacy

Only identifiers needed for case continuity should be retained. Control player
views are masked by default, and evidence must exclude raw IPs, platform tokens,
secrets, screenshots, memory, full packets, and full domain records.

Security evidence is currently retained when a character is deleted. The
resource manifest intentionally declares `retain`; no anonymization provider is
claimed until a separately tested domain-deletion integration exists.

## Capacity

The in-process case registry is bounded to 4,096 cases. Listing is capped and
sorted by update time. Capacity exhaustion returns an explicit retryable error;
it does not silently evict an active case.
