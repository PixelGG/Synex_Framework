# ADR-0012: Assume the client is fully compromised

- Status: Accepted design; Security implementation Experimental / Alpha
- Date: 2026-08-31
- Scope: `synex_security` and every client-facing Synex resource

## Context

A FiveM client receives and executes resource code and can originate events,
NUI messages, local state, native results, camera/ped/weapon observations, and
telemetry. Event or contract names are discoverable. A value embedded in client
Lua or JavaScript cannot remain secret from a client owner.

Treating a client heartbeat, hidden event name, local key, obfuscation, screenshot,
or native check as authoritative would create a security boundary the platform
does not provide.

## Decision

Assume an attacker can inspect, alter, forge, replay, block, or stop every client
component and every client-originated value.

Authorization, financial truth, inventory truth, permissions, sessions, source
generations, durable identity, entity/world authority, interaction leases, and
enforcement policy remain server-side. Client reports are bounded evidence only.

`synex_security` may run a small Sentinel to improve visibility, but Sentinel
sequence, freshness, and challenges are replay/liveness controls rather than
cryptographic attestation. Signals derived only from client telemetry or
behavioral heuristics remain weak, have a correlation confidence cap, and cannot
alone justify restrict, kick, or ban.

No secret client event, hard-coded client password/key, hidden table, or
obfuscation scheme may be used for authorization. Obfuscation may provide only
intellectual-property friction.

## Consequences

- Client code and contract names can be documented without weakening the trust
  model.
- Domains must rederive and validate sensitive values server-side.
- Client telemetry can increase observability but cannot prove client integrity.
- Some local presentation manipulation is not deterministically detectable by
  this framework.
- Strong enforcement needs current server authority and independent server/domain
  evidence.
- Every live detector still requires real FXServer calibration; accepting this
  ADR does not promote `synex_security` beyond Experimental / Alpha.
