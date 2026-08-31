# Evidence model

Evidence class and confidence are separate. Confidence expresses how strongly a
specific observation supports its claim; evidence class describes where the
observation came from.

## Classes

| Class | Base weight | Meaning |
| --- | ---: | --- |
| `SERVER_AUTHORITATIVE` | 1.00 | A fact decided by a server authority |
| `DOMAIN_AUTHORITATIVE` | 0.90 | A bounded finding from the owning domain |
| `CFX_SERVER_EVENT` | 0.80 | A server-received Cfx event with its documented limitations |
| `SERVER_DERIVED` | 0.75 | A server computation over bounded observations |
| `BEHAVIORAL_HEURISTIC` | 0.35 | A temporal or statistical pattern with ambiguity |
| `CLIENT_TELEMETRY` | 0.25 | Advisory data supplied by a fully compromised client |

Weights are inputs to correlation, not probabilities and not automatic action
thresholds.

## Independence

Signals sharing `rootEventId`, `requestId`, or `traceId` form one independent
root. Within that root, correlation keeps only the strongest contribution. This
prevents a single event from gaining artificial strength through multiple
detectors or delivery paths.

Independent evidence means distinct roots, not merely a larger signal count.
The assessment exposes both `signalCount` and `independentEvidence`.

## Weak evidence rule

`CLIENT_TELEMETRY` and `BEHAVIORAL_HEURISTIC` are weak classes. A hypothesis
containing only weak evidence has a confidence cap of 0.64. Even if a policy
would otherwise choose `RESTRICT`, `KICK`, or `BAN`, the enforcement engine
downgrades a weak-only case to `MANUAL_REVIEW`.

This rule is structural. Switching a detector to `ENFORCE` does not make client
telemetry trustworthy.

## Severity, time, and diversity

Correlation multiplies class weight, severity weight, and signal confidence,
then applies category-specific decay. Independent roots combine non-linearly.
Multiple evidence classes provide a small bounded diversity adjustment; they do
not sum linearly to an unlimited score.

Category windows range from 30 seconds for transport/entity observations to
five minutes for combat/resource-integrity observations. Older observations stop
contributing to that hypothesis.

## Expectations

A matching active expectation removes the signal from actionable hypothesis
calculation. The signal remains counted as expected evidence for diagnostics.
Expectations are explicit, owner-bound, revisioned, and time-limited; they are
not a way to rewrite evidence after the fact.

## Evidence handling

Evidence is closed, depth-, entry-, string-, and byte-bounded. Store facts such
as a policy name, rate-window count, sanitized model/hash, bounded distance, or
the stable denial code. Do not store access tokens, platform identifiers, raw IP
addresses, full client payloads, memory, screenshots, or arbitrary packet data.

## Operational interpretation

No evidence class is a universal cheat proof. Cfx events can contain
client-originated values; server-derived movement can be distorted by streaming
or network timing; domain findings can reveal an integration bug. Strong action
requires current subject authority, policy support, and sufficient independent
evidence, with live false-positive calibration still outstanding.
