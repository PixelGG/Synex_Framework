# Compatibility matrix

> [!WARNING]
> This matrix records the current bridge rework snapshots only. All bridges are unsupported and outside `synex_core` Production-Beta certification. An `Implemented in current snapshot` cell means only that the listed code path exists in this snapshot; it is not a production-support claim.

Status meanings:

- **Implemented in current snapshot** — present and covered by repository tests within the stated snapshot boundary; not a current deployment-support claim.
- **Partial** — only the listed subset is implemented; legacy semantics differ.
- **Unsupported** — rejected or intentionally absent.
- **Deprecated** — available only as a transition path; native Synex APIs are preferred.

All three bridge snapshots are currently **Deprecated / Partial**. They are clean-room, Synex-native shims and do not depend on an installed legacy framework, but none is included in the Core Production-Beta profile.

## QBCore-shaped surface

| Surface | Mapping | Status |
| --- | --- | --- |
| Server Core Object | `GetCoreObject()` with `Functions.GetPlayer` and `Functions.CreateCallback` | Partial |
| Server player lookup | Connected source with an active Synex character | Implemented in current snapshot |
| Player data | Detached identity, `cash`/`bank`, first job, first gang, and Synex metadata projection | Partial |
| Money | `GetMoney`, `AddMoney`, `RemoveMoney`, `SetMoney`; writes are balanced counterparty transfers | Partial |
| Job / gang | First matching membership; duty and boss state are not inferred | Partial, read-only |
| Callbacks | Bounded `CreateCallback` / client `TriggerCallback` transport | Partial |
| Lifecycle | `QBCore:Client:OnPlayerLoaded`, `QBCore:Server:PlayerLoaded`, and unload counterparts | Partial |
| Client Core Object | Cached detached `GetPlayerData` and `TriggerCallback` | Partial |
| Citizen-ID/offline lookup | `GetPlayerByCitizenId` and offline players | Unsupported |
| Job/gang mutation | `SetJob`, `SetGang` | Unsupported |

The export resource changes from `qb-core` to `synex_bridge_qb`.

## Qbox-shaped surface

| Surface | Mapping | Status |
| --- | --- | --- |
| Direct server exports | `GetPlayer`, `GetMoney`, `AddMoney`, `RemoveMoney`, `SetMoney`, `GetGroups`, `GetGroup` | Partial |
| Core Object | Limited `Functions.GetPlayer` and `Functions.CreateCallback` compatibility object | Partial |
| Player data | Detached identity, cash/bank, bounded groups, first job/gang, and Synex metadata | Partial |
| Groups | Group key to rank projection and single-group read | Partial, read-only |
| Callbacks | Bounded `CreateCallback` / client `TriggerCallback` transport | Partial |
| Lifecycle | Qbox-compatible `QBCore:*` loaded/unloaded subset | Partial |
| Client exports | `GetPlayerData`, `GetGroups`, limited `GetCoreObject` | Partial |
| Citizen-ID/offline lookup | Only a connected numeric source is accepted | Unsupported |
| Crypto and other money types | Only `cash` and `bank` map to Synex accounts | Unsupported |
| Group mutation | No legacy group mutation API | Unsupported |

The export resource changes from `qbx_core` to `synex_bridge_qbx`.

## ESX-shaped surface

| Surface | Mapping | Status |
| --- | --- | --- |
| Shared object | `getSharedObject` export and local `esx:getSharedObject` handler | Partial |
| Player lookup | `GetPlayerFromId` for a connected source with an active character | Implemented in current snapshot |
| xPlayer | Detached identifier/name/job/account facade | Partial |
| Accounts | `money`/`cash` and `bank` reads plus balanced add/remove/set operations | Partial |
| Job | First Synex `job` membership; duty is not inferred | Partial, read-only |
| Callbacks | Bounded `RegisterServerCallback` / client `TriggerServerCallback` transport | Partial |
| Lifecycle | `esx:playerLoaded`, `esx:onPlayerLogout`, and server logout subset | Partial |
| Client object | Cached detached player data and callback trigger | Partial |
| Permission group | `xPlayer.getGroup()` does not infer an authorization group | Unsupported |
| Job mutation | `xPlayer.setJob()` | Unsupported |
| Offline lookup / arbitrary accounts | Connected source and cash/bank only | Unsupported |

The export resource changes from `es_extended` to `synex_bridge_esx`. The projected identifier is `synex:<character-uuid>` and is not an ESX license identifier.

## Shared failure behavior

| Condition | Result |
| --- | --- |
| Consumer is stopped, undeclared, or ungranted | `CALLER_INVALID` or capability error |
| Source is disconnected or has no active character | `INVALID_SOURCE` or `CHARACTER_NOT_ACTIVE` |
| Multiple compatible accounts exist for one character/currency | `AMBIGUOUS_MONEY_ACCOUNT` |
| Compatible account projection exceeds its bounded window | `ACCOUNT_PROJECTION_TRUNCATED` |
| Currency scale is not a legacy integer unit | `UNSUPPORTED_MONEY_SCALE` |
| Counterparty account is absent | `MONEY_COUNTERPARTY_NOT_CONFIGURED` |
| Money/account name is outside cash/bank | `UNSUPPORTED_MONEY_TYPE`, `UNSUPPORTED_ACCOUNT`, or validation error |
| Callback is oversized, over limit, timed out, or source generation changed | Dropped or bounded callback error; no stale response is delivered |

No bridge falls back to a legacy framework, direct SQL, or an implicit privileged operation.
