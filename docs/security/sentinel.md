# Client Sentinel

The Sentinel is a small visibility aid. It is not a root of trust, anti-tamper
agent, or cryptographic attestation mechanism.

## Client sample

Every report contains a bounded envelope with:

- client epoch;
- increasing sequence;
- client game-timer sample time;
- current challenge reference;
- position, velocity, and gameplay-camera coordinates;
- health, armor, visibility, alpha, model, and selected weapon;
- vehicle, ragdoll, falling, and parachute state.

The client uses guarded native calls and numeric bounds. A failed RPC retries the
same pending envelope rather than silently incrementing the sequence. The
default interval is three seconds, and the server can return a bounded next
interval.

## Server validation

The Sentinel network contract is the only client-to-server Security contract.
Core first supplies an active session and source generation. The server then
validates the closed envelope, bounded sample, client epoch, sequence,
challenge continuity, timer freshness, and current session/source generation.

The first report for an epoch must use sequence `1` and the bootstrap challenge.
Successful reports receive a new challenge. An exact retry of the immediately
previous report is idempotently accepted as a duplicate. Gaps, unexpected
challenges, stale timing, or reused sources are rejected.

## Liveness

The server tracks at most 1,024 active Sentinel subjects by default. Missing
reports after the bounded liveness window emit `SECURITY_SENTINEL_MISSING` as
low-confidence `SERVER_DERIVED` evidence. Very stale state is removed. Player
drop and source-generation cleanup remove state immediately.

Missing telemetry is not an automatic permanent-ban reason. It can result from a
client crash, resource restart, connection issue, load, or an attacker.

## Trust statement

A compromised client can read the challenge format, forge sample values, replay
known data, alter the loop, or stop the resource. Sequence and freshness make
accidental stale/replayed reports visible; they do not make client data true.

All sample-derived signals are `CLIENT_TELEMETRY` or, when combined with other
bounded observations, `BEHAVIORAL_HEURISTIC`. Strong enforcement requires
independent server/domain evidence.

## Privacy and performance

The Sentinel does not inspect memory, enumerate files/processes, capture the
screen, transmit arbitrary state, or store a full movement history. Server-side
history and report state are bounded. The exact client/gameplay performance and
reconnect behavior still require live measurement.
