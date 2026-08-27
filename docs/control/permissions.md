# Control permissions

Control uses Cfx ACEs for the in-game operator and Core resource capabilities for server-to-server provider access. They are separate boundaries.

## Operator ACEs

| ACE | Scope |
| --- | --- |
| `synex.control.view` | Safe general overview and non-sensitive provider diagnostics |
| `synex.control.audit` | Routes whose trusted metadata declares the `audit` class, currently trace history, the exact trace inspector, and exact trace search |
| `synex.control.security` | Security and capability diagnostics |
| `synex.control.financial` | Accounts, ledger, transaction, hold, economy, anomaly, integrity, and outbox reads |
| `synex.control.identifiers` | Full identifiers in otherwise authorized responses; credentials remain redacted |

Example restricted role:

```cfg
add_ace group.synex_operator synex.control.view allow
add_ace group.synex_operator synex.control.audit allow
add_ace group.synex_finance synex.control.view allow
add_ace group.synex_finance synex.control.financial allow
```

Do not grant the four specialist ACEs merely because the base panel is available. `synex.control.identifiers` never reveals passwords, tokens, API keys, private keys, webhook URLs, connection strings, or other credentials.

Every provider view declares one of the five access classes in trusted metadata. A search view additionally declares the access class of each kind; its optional input fields inherit the containing view's class. Control projects authorization into the catalog for navigation, but still resolves and enforces the class again on every server request. The Core `audit` search view is general navigation because it hosts several safe registry searches; the selected kind still controls the specialist check. Its exact `user` kind requires `identifiers` and returns only bounded active-session projections without echoing the supplied user ID.

Core slow-operation history is a `general` diagnostic because it contains no SQL or parameters; trace history and trace detail remain `audit`. Groups policy simulation is `general`, but it evaluates only the bounded actor/Group/action inputs declared by trusted metadata and has no persistence path. Specialist ACEs are checked again for every request, including cached navigation and opaque-cursor continuation.

Provider-owned Character-relation views inherit their domain class: Groups and Entities are `general`, while Accounts is `financial`. The Core Character inspector exposes only a count/status/truncation aggregate from each registered provider and never forwards relation identifiers, balances, currencies, statuses or Entity details.

## Request-time authority

The server verifies the player source and base ACE for every request. It then checks the route-specific ACE before provider discovery or invocation. The browser does not retain an authorization decision.

If the base ACE is revoked while the panel is open, the next request returns `ACCESS_REVOKED`; an open-viewer check also detects the revocation on its five-second cycle. The client releases focus and clears the UI state. Revoking a specialist ACE blocks the next request for that area without trusting any already-rendered client state.

## Resource capabilities

Providers request `synex.control.provider.register`. `synex_control` requests `synex.control.provider.read` and `synex.control.provider.register`; the second grant is used only for its own `control` meta-health provider. Core policy must grant exactly those capabilities. Domains do not grant Control their normal mutation or broad service capabilities.
