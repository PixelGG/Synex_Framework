# ESX compatibility provider

`synex_bridge_esx` exposes a partial ESX Legacy-shaped shared object and detached online `xPlayer` view. It does not load or embed ESX.

> [!WARNING]
> This provider is part of the Experimental Alpha Bridge platform. Exact-candidate FXServer, historical-facade/restart, callback/event, deployment-mapping, third-party-flow, and real-client acceptance remain pending.

## Implemented subset

- shared-object access plus online `GetPlayerFromId`, `GetPlayerFromIdentifier`, and `GetPlayerIdFromIdentifier` lookup;
- bounded online `GetPlayers` enumeration and `GetExtendedPlayers` projection, with only `identifier` or `job` filters, scalar or at most 32 unique array values, and the ESX `minimal` form;
- detached player identifier/name, primary job, mapped metadata, and reviewed account reads;
- policy-selected transfer/mint/burn money mutations and transfer-only sequence-fenced target balance behavior;
- exact existing-membership two-argument `xPlayer.setJob(name, grade)` through the atomic policy-aware Groups service;
- bounded server callbacks and client callback transport;
- generation-fenced player-loaded, job/account-update, and logout projection;
- optional repository-owned `es_extended` historical facade and local shared-object event.

Server load preserves the ESX event positions `esx:playerLoaded(source, xPlayerData, isNew)`, but the broadcast `xPlayerData` is deliberately data-only and carries no consumer-bound methods. Caller-bound server exports remain the only path to a privileged detached xPlayer facade. Client load follows `esx:playerLoaded(playerData, isNew, skin)`. Synex cannot truthfully infer new-character or skin semantics at this boundary, so `isNew` is conservatively `false` and `skin` is `nil`. Canonical job and account changes publish their ESX update events only when the corresponding `esx.shared.job_update_events` or `esx.shared.account_update_events` surface is separately authorized. Base lifecycle access does not enable either family. The provider-local client projection is delivered by a server-origin event rather than reconstructed from public ESX lifecycle payloads, and provider recovery refreshes it without replaying public load.

Client shared-object/player-data and callback access are separate cataloged surfaces. The coordinator sends a player-data allowlist for active consumers that pass `esx.client.player_data`; callback access additionally requires the same consumer to pass `esx.client.callback_invocation` and `esx.server.callback_registration`. A callback-only profile is incomplete, and an empty player-data list clears the client snapshot and both access lists. Direct client exports compare the immediate client resource name with the applicable list, while the repository `es_extended` facade can forward only a listed consumer through a dedicated `*ForConsumer` path. These lists are compatibility API admission, not confidentiality or server-trusted client identity; the client-sent callback consumer is only a routing hint, and callback handlers must still authorize the player action on the server.

The provider discovers account names from the centrally reviewed ESX account-mapping catalog and projects only matching active character accounts. `money` resolves to the canonical `cash` alias; every other requested account name is lowercased and must resolve uniquely through the mapping alias or its reviewed legacy name. The current catalog exposes `money` and `bank`; their native targets use `usd` asset accounts with minor unit `0`, and the `cash`/`bank` account-key prefixes are expanded into deterministic owner-scoped keys for the active character. Provider-local currency or account-key overrides are not accepted. Adding another reviewed ESX mapping makes that custom account available across `getAccount`, `getAccounts`, and the mapped account mutation methods without adding a provider-side hardcoded name. An arbitrary, unmapped, or ambiguous name remains fail-closed.

The checked-in metadata catalog admits only integer `hunger` values from `0` through `100`, stored as `needs.hunger`. It does not expose arbitrary ESX variables or a complete xPlayer data blob. A successful mapped write queues one refresh fenced to the exact source, character, session, and source generation.

## Explicitly unsupported

Offline player lookup, permission mutation/admin methods, arbitrary unmapped accounts, inventory methods, and every `GetExtendedPlayers` filter other than `identifier` or `job` are cataloged as `UNSUPPORTED`. Enumeration is deliberately online-only, bounded by the native bridge player limit, and returns detached `xPlayer` facades rather than ESX-owned mutable state. Job mutation is limited to an exact catalog mapping, an existing active membership/grade, and the atomic Groups compatibility service. The optional `onDuty` argument of `xPlayer.setJob(name, grade, onDuty)` is rejected before the job write because Synex does not expose one primitive that atomically commits both changes; accepting it would permit a partially applied legacy call. `xPlayer.getGroup()` is a read-only `PARTIAL` projection over explicit permission mappings and Core RBAC; the empty checked-in permission catalog disables it by default and gameplay memberships are never treated as administrator roles. Inventory requires a future native inventory adapter.

The authoritative names and statuses are in [`surfaces/esx.json`](../../libraries/synex_bridge/compatibility/surfaces/esx.json) and the generated [matrix](matrix.md).
