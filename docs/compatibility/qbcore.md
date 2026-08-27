# QBCore compatibility provider

`synex_bridge_qb` exposes a deliberately partial, detached QBCore-shaped surface for reviewed online consumers. It does not load or embed QBCore.

> [!WARNING]
> This provider is part of the Experimental Alpha Bridge platform. Exact-candidate FXServer, historical-facade/restart, callback/event, deployment-mapping, third-party-flow, and real-client acceptance remain pending.

## Implemented subset

- server `GetCoreObject`, source-bound `GetPlayer`, online `GetPlayerByCitizenId`, and active-session `GetPlayers`/`GetQBPlayers`; bounded array filtering of the exposed `Functions` subset is a separate cataloged surface and requires both base Core Object and filtering authorization;
- detached online `PlayerData` with the Cfx player name, character identity, `cash`/`bank`, one primary job, one primary gang/group, and mapped metadata; the Player facade also exposes a fenced `GetPlayerData` refresh;
- `GetMoney`, policy-selected transfer/mint/burn `AddMoney`/`RemoveMoney`, transfer-only sequence-fenced `SetMoney`, and reviewed metadata access;
- exact existing-membership `SetJob`/`SetGang` plus duty-session-backed `SetJobDuty`;
- bounded server callback registration and client callback invocation, including the current callback-first and Promise/Await client forms without a second pending-request registry;
- generation-fenced load, update, and unload projection with deterministic event ordering;
- optional repository-owned `qb-core` historical facade.

The provider updates its provider-local client snapshot before public delivery. Server load publishes `QBCore:Server:PlayerLoaded` with data only—`PlayerData` plus `Offline = false`—and never broadcasts consumer-bound `Functions` closures. Caller-bound server exports are the only path to a privileged detached Player facade. Client load publishes `QBCore:Client:OnPlayerLoaded` without a payload. Job, gang, duty, and money update families are independently cataloged and authorized; base lifecycle publication does not enable them. Duty is represented through the job projection and job update events, and QB does not invent Qbox-only `QBCore:*:SetDuty` events. Duplicate canonical notifications with unchanged player data remain silent.

Client `GetCoreObject`/`GetPlayerData` access is also separate from lifecycle. The coordinator sends a bounded allowlist only for active consumers that resolve `qb.client.player_data`; callback functions appear only for consumers that additionally resolve `qb.client.callback_invocation` and `qb.server.callback_registration`. A callback-only profile is incomplete, and an empty player-data list clears the client snapshot and both access lists. Direct exports compare the immediate client resource name with those lists, while the repository `qb-core` facade can forward only a listed consumer through the dedicated `*ForConsumer` path. This is compatibility API admission, not confidentiality or server-trusted client identity; the client-sent callback consumer is only a routing hint, and each public callback handler must still authorize the player action on the server.

The provider exposes only the supported `cash` and `bank` alias names. Their native targets are controlled centrally: both use `usd` asset accounts with minor unit `0`; the catalog prefixes `cash` and `bank` are expanded into deterministic owner-scoped keys for the active character. Provider-local currency or account-key overrides are not accepted.

Every mutable path still requires an enabled consumer/profile, the matching compatibility capability, native domain capability, a current session fence, and the relevant mapping or policy.

Citizen-ID lookup is online-only. The bridge resolves the stable QB compatibility identity and then requires a current active Synex session for the same character. `GetPlayers` returns only active numeric server sources; `GetQBPlayers` builds detached, source-keyed Player facades from that same bounded snapshot. Invalid, ambiguous, stale, or over-capacity results fail closed instead of returning partial data.

A provider restart rebuilds the client projection for active sources without publishing another public player-loaded transition. If one authorized QB lifecycle consumer stops, another eligible consumer can take publication authority without a synthetic unload/load pair; with none available, the retained delivery follows the normal unload path and may load again after authority returns. In a mixed QB/QBX deployment, an eligible QB path has priority for the shared QBCore family, while a stopped or denied QB path yields silently to eligible QBX. Core stop/rebind uses the same real unload/load boundary rather than pretending continuity while Core is unavailable.

The checked-in metadata catalog admits only integer `hunger` values from `0` through `100`, stored as `needs.hunger`. It does not expose the full QBCore metadata or `PlayerData` blob. A successful mapped write queues one refresh fenced to the exact source, character, session, and source generation.

## Explicitly unsupported

Offline player lookup, permission mutation/admin methods, and shared Jobs/Gangs/Vehicles/Items registries are cataloged as `UNSUPPORTED`. `HasPermission` and `GetPermission` are a read-only `PARTIAL` view over explicit permission mappings and Core RBAC; the empty checked-in mapping catalog keeps that view disabled by default, and it never grants Synex capabilities. Filtered Core-object lookup is `PARTIAL`: requested fields are selected from the bounded Synex compatibility object, but unavailable `Shared`, `Commands`, `Players`, and `Config` namespaces are not invented. Group mutation is limited to exact catalog mappings, an existing active membership/grade, and the atomic policy-aware Groups service; it does not expose membership creation/removal or organization/grade-definition management.

The projection intentionally omits fields whose owning domain is unavailable, including inventory items, vehicle catalogs, job payment/type data, phone/account identifiers, and arbitrary writable PlayerData. `SetPlayerData` is not exposed because legacy callers may not mutate identity, money, groups, permissions, or other canonical Synex state through a generic field setter.

The authoritative names and statuses are in [`surfaces/qb.json`](../../libraries/synex_bridge/compatibility/surfaces/qb.json) and the generated [matrix](matrix.md).

## Conflict rule

If a started resource named `qb-core` does not carry the exact repository facade marker, the provider fails closed with `COMPAT_FRAMEWORK_CONFLICT`. A real QBCore instance and the Synex historical-name facade cannot occupy the same resource name.
