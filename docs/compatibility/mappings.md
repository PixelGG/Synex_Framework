# Compatibility mappings

Mappings are explicit, versioned, provider-scoped records in [`mappings.json`](../../libraries/synex_bridge/compatibility/mappings.json). Registry entries are owner/epoch bound and duplicate lookup keys fail as ambiguous.

## Identity

Identity mappings bind a reviewed legacy user or character identifier to one native identifier. When no static character mapping exists, the persistent identity store creates one stable provider-specific identifier and retains imported `citizenid` or ESX `identifier` values. Cross-provider identifiers are never assumed equivalent.

## Accounts and money policies

An account alias binds a provider alias to one exact native account tuple template: currency code, account-key prefix, account role, and minor-unit scale. Optional presentation metadata fixes the legacy name, label, and rounding behavior without changing account authority. `cash` and `bank` are legacy account aliases, not currencies. The checked-in QB, QBX, and ESX definitions therefore resolve both aliases inside `usd`: `cash` uses the `cash` prefix and `bank` uses the `bank` prefix, both with asset role and minor unit `0`. ESX presents the canonical `cash` alias as `money`. Runtime and migration append the normalized Synex character ID to produce the same deterministic owner-scoped key, so different characters never share one compatibility account.

These values exist only in the central catalog and registry. A provider declares which aliases it exposes; it cannot override currency, account key, role, or scale locally. Duplicate aliases or two aliases resolving to the same provider-scoped account tuple are ambiguous and fail closed before Accounts is called. ESX account lookup resolves a requested name uniquely through the mapping alias or reviewed legacy name, so a newly reviewed custom account becomes visible without provider code while duplicate presentation names fail closed. A mapping only identifies the character account; it does not authorize a money mutation.

Every mutation additionally needs one exact active entry in [`money-policies.json`](../../libraries/synex_bridge/compatibility/money-policies.json), matching provider, consumer, alias, direction, and normalized legacy reason. `transfer` supplies a reviewed counterparty account; `mint` is valid only for `add`, and `burn` only for `remove`, with Accounts resolving the configured currency topology. Every action supplies a native reason code and requires the immediate consumer plus provider to hold the matching native Accounts capability. Missing or ambiguous matches fail closed. The reviewed providers are the only checked-in mint/burn executors; the empty policy and consumer catalogs leave every legacy mint/burn action disabled by default.

The checked-in file contains only `PARTIAL` `cash` and `bank` aliases and no money policies, so money writes are disabled by default. Account projection requires an exact match across currency, account key, role, and minor-unit scale; no first matching account is selected. No ConVar, client argument, or first matching account can become a counterparty. The bridge does not perform direct balance writes.

## Groups and grades

A group mapping binds provider + native group type/key to one legacy type/name. Every grade uses an exact legacy numeric grade to native grade-key mapping, and both sides must be one-to-one; two legacy grades may not resolve to the same native grade key. Optional boss-role keys are explicit; rank alone never implies `isboss`. Duty appears only when the mapping declares it supported. Qbox's job and gang namespaces share bare-name lookup forms, so the same legacy name cannot be registered for both types: that catalog is ambiguous and fails closed rather than depending on lookup order.

Every active membership in a complete projection must map. The bridge does not silently choose a first membership, grade, or primary group. A mutation resolves the provider's exact legacy type/name/grade mapping back to one existing active native group, grade, and membership. Grade and primary selection change together through the policy-aware Groups compatibility service; duty starts, updates, or stops a real duty session using the explicitly mapped duty state. Mappings never authorize group, grade, or membership creation.

## Metadata

Only explicitly listed, non-sensitive fields can be projected or stored. Each mapping fixes storage key, value type, optional numeric/string bounds, and status. System roots for identity, sessions, money, accounts, permissions, tokens, inventory, and similar authority data are always forbidden even if configuration attempts to add them.

Metadata writes use expected-version compare-and-swap. After a successful write, the provider invalidates that source's projection and schedules one refresh bound to the exact source, character, session, and source generation; delayed work for a replaced session is discarded. Unknown keys return `COMPAT_METADATA_UNSUPPORTED`; forbidden keys return `COMPAT_METADATA_FORBIDDEN`.

The checked-in catalog contains one deliberately narrow `PARTIAL` mapping per provider: QB, QBX, and ESX `hunger` must be an integer from `0` through `100` and is stored as `needs.hunger`. It does not admit the provider's complete `PlayerData` or metadata object.

## Permission projection

Permission mappings are a read-only legacy view over Core RBAC. Each entry binds one legacy group name to one concrete Synex permission probe and deterministic priority; exactly one explicit fallback is required before projection can run. Equal highest priorities, duplicate names, missing fallback mappings, and Core lookup errors fail closed. Gameplay Groups are never interpreted as administrator roles, and these mappings cannot assign or revoke permissions. The checked-in permission catalog is empty, so permission projection is disabled by default.

The legacy migrator loads these same checked-in definitions and forbidden roots. A migration mapping selects exact provider mapping IDs and includes the canonical catalog digest; both the reviewed report and mapping digest bind that selection. A catalog change therefore makes an older mapping or bundle stale instead of silently applying independent migration rules.
