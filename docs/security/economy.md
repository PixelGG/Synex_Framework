# Economy security boundary

`synex_security` does not own balances, transfers, ledgers, account membership,
mint/burn policy, inventory, job rewards, or shop prices. These remain
server-authoritative domain concerns, primarily in `synex_accounts` and the
future/reworked gameplay domains that call it.

## Required order

```text
client or resource request
  -> domain validates contract, actor, ownership, value, policy, revision
  -> domain transaction/idempotency prevents an invalid or duplicate effect
  -> rejected abuse may emit a bounded DOMAIN_AUTHORITATIVE signal
  -> Security correlates the attempt
```

A signal is emitted after denial. Security must never approve a financial
mutation or compensate for a handler that trusted a client-supplied amount,
price, account, membership, or reward.

## Signal shape

An economy domain can use category `economy`, its owned namespace/detector, a
stable uppercase rejection code, current session subject, confidence appropriate
to its authority, and bounded facts such as operation class or policy revision.

Do not include balances, full ledger entries, payment metadata, platform
identifiers, SQL errors, or the full rejected request in evidence.

Replay/idempotency findings should carry a stable `requestId` or root reference
so derived signals do not count as independent evidence. Ordinary network
retries must not become multiple cases.

## Current implementation status

`synex_accounts` declares the `synex.security.signal.emit` capability and now
reports a deliberately small allowlist of security-relevant denials after the
financial operation has failed closed. These include principal spoofing,
authorization and reason-namespace denials, idempotency conflicts, and forbidden
operations. Ordinary insufficient-funds, missing-record, validation, and limit
outcomes are not treated as security evidence merely because they failed.

The Security default includes a `domain_abuse` observe posture, but there is no
automatic balance correction, account restriction, or financial ban policy in
`synex_security`.

## Enforcement

Deterministic domains should prevent or reverse only through their own
transactional rules. Security may open a case or request manual review. Any
future financial restriction must call a reviewed domain API and revalidate the
current subject; it must not write domain tables directly.
