# Compatibility bridges

> [!WARNING]
> Every bridge and its shared library are experimental rework snapshots. They are unsupported and excluded from the `synex_core` Production-Beta deployment, integration, and security certification boundary.

The current compatibility snapshots explore an optional migration aid. They expose a deliberately small, consumer-bound legacy API shape while executing identity, account, group, callback, and lifecycle work through native Synex services. They do not load or query QBCore, Qbox, or ESX, and their interfaces may change or be replaced during rework.

The current implementation matrix is `Partial` and `Deprecated` by design. Those labels describe only the checked-in snapshot; they are not support levels or a claim that an unchanged legacy resource will run. Consumers would need to change their export target from `qb-core`, `qbx_core`, or `es_extended` to the selected Synex bridge and handle the explicit `(result, error)` return convention.

> [!CAUTION]
> Every command, capability example, export call, and configuration fragment below is retained only to explain the historical snapshot during rework. It is not current installation or migration guidance. Do not start these bridges or their downstream dependencies in the accepted Core Production-Beta profile.

## Snapshot component catalog

| Resource | Responsibility | Runtime dependencies |
| --- | --- | --- |
| `synex_bridge` | Shared bounded server/client transport and compatibility metadata | `synex_core` |
| `synex_bridge_qb` | QBCore-shaped online-player facade | Core, bridge, accounts, groups |
| `synex_bridge_qbx` | Qbox-shaped exports plus a limited Core Object facade | Core, bridge, accounts, groups |
| `synex_bridge_esx` | ESX shared-object and detached xPlayer facade | Core, bridge, accounts, groups |

The checked-in snapshot declared the following dependency order. It is shown for source review only; do not execute it as a deployment recipe. The QB and QBX snapshots also publish the same `QBCore:*` lifecycle event names and were never intended to run together.

```cfg
ensure synex_core
ensure synex_groups
ensure synex_accounts
ensure synex_bridge
ensure synex_bridge_qbx
```

## Historical consumer-authorization design

Every call is bound to Cfx's immediate `GetInvokingResource()` value. A consumer cannot supply or substitute another resource identity. It needs both a manifest declaration and an operator policy grant; denies still win.

```json
{
  "capabilities": {
    "request": [
      "synex.compat.qbx.read",
      "synex.compat.qbx.write",
      "synex.compat.qbx.callbacks"
    ]
  }
}
```

Add the same reviewed permissions for that consumer in `core/synex_core/config/capabilities.json`:

```json
{
  "resources": {
    "synex_legacy_resource": {
      "allow": [
        "synex.compat.qbx.read",
        "synex.compat.qbx.write",
        "synex.compat.qbx.callbacks"
      ],
      "deny": []
    }
  }
}
```

Replace `qbx` with `qb` or `esx` for the other bridge. Compatibility consumers are still Synex-managed resources, so their Cfx resource name and manifest name must follow the `synex_[a-z0-9_]+` convention. Request only the surfaces the resource actually uses. The bridge resources have separate, least-privilege grants for the native Synex operations they perform; consumers never receive those native privileges through delegation.

## API path changes

Server-side QBCore example:

```lua
local QBCore, compatError = exports.synex_bridge_qb:GetCoreObject()
if not QBCore then
    error(compatError.code)
end

local player, playerError = QBCore.Functions.GetPlayer(source)
if not player then
    print(playerError.code)
    return
end
```

Equivalent entry points are `exports.synex_bridge_qbx:GetPlayer(source)` and `exports.synex_bridge_esx:getSharedObject()`. Client facades are exported by the same selected bridge. See the [matrix](matrix.md) before changing a consumer; unsupported functions do not silently fall back to another framework or direct SQL.

## Money mutations

`cash` and `bank` use integer units and are the only mapped money types. Every add/remove/set operation becomes a balanced `synex.accounts.transfer`; the bridge cannot mint or burn. Writes remain disabled until the operator configures reviewed UUIDs for suitable active counterparty accounts:

```cfg
set synex_bridge_qbx_cash_counterparty "00000000-0000-4000-8000-000000000001"
set synex_bridge_qbx_bank_counterparty "00000000-0000-4000-8000-000000000002"
```

Use the corresponding `synex_bridge_qb_*` or `synex_bridge_esx_*` names for those bridges. A player's compatible currency must have `minor_unit = 0`, and the character must own exactly one active account for that currency. Missing, ambiguous, or incompatible accounts fail closed.

## Callback and lifecycle boundary

Each bridge owns exactly one generic client-to-server callback endpoint. Requests are size- and argument-bounded, rate-limited, capped per source, timed out after ten seconds, and fenced to the active Synex session plus source generation. Client responses and lifecycle projections accept server-origin events only. Callback names are owned by the registering consumer and removed when it stops.

Character activation/unload produces the documented legacy lifecycle event subset. Event payloads and player facades are detached projections: mutating them cannot mutate Synex state.

## Deliberate limits

- online sources with an `ACTIVE` Synex character only;
- no offline/citizen-ID lookup, direct SQL, arbitrary dynamic methods, or mutable framework objects;
- no inventory, vehicle, metadata, admin, permission-group, job, or gang mutations;
- no implicit account creation, currency conversion, mint, or burn;
- no authorization equivalence between a Synex group, QBCore gang, Qbox group, and ESX permission group.

Compatibility use emits bounded deprecation telemetry per consumer. Use `synex compat scan` to identify migration work, consult the precise [compatibility matrix](matrix.md), and use the [legacy migration workflow](migration.md) only on reviewed exports and disposable target rehearsals first.
