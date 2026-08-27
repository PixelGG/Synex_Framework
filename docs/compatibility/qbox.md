# Qbox compatibility provider

`synex_bridge_qbx` is a separate native Qbox-shaped provider. It is not an alias for the QB provider and does not load Qbox.

> [!WARNING]
> This provider is part of the Experimental Alpha Bridge platform. Exact-candidate FXServer, historical-facade/restart, mixed-provider event, deployment-mapping, third-party-flow, and real-client acceptance remain pending.

## Implemented subset

- source-bound online `GetPlayer` and detached player data;
- online `GetPlayerByCitizenId` plus a detached, read-only `GetOfflinePlayer` projection;
- exact `cash`/`bank` reads and policy-selected transfer/mint/burn `AddMoney`/`RemoveMoney`, accepting a current source or stable citizen identifier on the standalone server surface;
- transfer-only sequence-fenced `SetMoney` and explicitly mapped `GetMetadata`/`SetMetadata`, with the same online identifier resolution on standalone calls;
- bounded multi-group projection, primary job/gang views, and `HasGroup`/`HasPrimaryGroup` string, array, or minimum-grade map filters;
- exact existing-membership job/gang mutation through the detached player and standalone `SetJob`/`SetGang` exports, online-only `SetPlayerPrimaryJob`/`SetPlayerPrimaryGang` using the membership's current grade, and real duty-session mutation through the facade or standalone `SetJobDuty`; standalone mutations accept only a current source or stable citizen identifier;
- provider-local client player/group snapshots plus generation-fenced load, update, and unload projection;
- optional repository-owned `qbx_core` historical facade.

The provider emits Qbox group, duty, and money updates only when their separate cataloged surfaces are authorized; base lifecycle access does not enable those update families. Its shared QBCore load/update/unload events are published only when the coordinator assigns QBX that global family. The global server load payload is data-only and never carries consumer-bound `Functions`; caller-bound server exports are the only path to privileged facade methods. QB has priority when both providers have a started, authorized lifecycle path. QBX takes over when QB is stopped, excluded, or denied, and a running handoff stays silent instead of replaying a global unload/load. Provider recovery rehydrates only the provider-local projection and suppresses duplicate public load events.

Client `GetPlayerData` and `GetGroups` access is a separate surface. The coordinator sends a detached player snapshot only when at least one active consumer resolves `qbx.client.player_data`; otherwise it clears the provider-local client state. QBX client callbacks remain unsupported. Direct exports compare their immediate client resource name with that list, while the repository `qbx_core` facade can forward only a listed consumer through a dedicated `*ForConsumer` export. This is compatibility API admission, not confidentiality or server-trusted client identity; the delivered projection remains detached and non-sensitive.

The provider exposes only the supported `cash` and `bank` alias names. Their native targets are controlled centrally: both use `usd` asset accounts with minor unit `0`; the catalog prefixes `cash` and `bank` are expanded into deterministic owner-scoped keys for the active character. Provider-local currency or account-key overrides are not accepted.

The checked-in metadata catalog admits only integer `hunger` values from `0` through `100`, stored as `needs.hunger`. It does not expose the full Qbox metadata or player-data blob. A successful mapped write queues one refresh fenced to the exact source, character, session, and source generation.

`GetOfflinePlayer` never grants write authority, including when the identified character is currently connected. Its detached object exposes read-only money and metadata helpers; every money, metadata, job, gang, or duty mutator returns `COMPAT_OFFLINE_MUTATION_UNSUPPORTED`. Group filters accept at most 32 bounded entries and reject sparse, mixed, nested, metatable-backed, or out-of-range values.

The standalone primary-job and primary-gang exports are deliberately partial. They require an online character, a mapped active membership already present in the authoritative Groups projection, and the current projected grade. Standalone group, duty, money, and metadata mutations also resolve only a current source or stable citizen identifier. None creates memberships, selects an unreviewed grade, or provides offline mutation.

## Explicitly unsupported

Callback registration, standalone add/remove-membership exports, Jobs/Gangs/Vehicles registries, routing-bucket management, permission/admin methods, and a QBCore-object compatibility layer are cataloged as `UNSUPPORTED`.

The provider does not collapse QB and Qbox internal behavior. All shared state is derived from the same canonical Synex character, Accounts, and Groups state, so concurrently enabled providers cannot maintain competing authoritative copies.

The authoritative names and statuses are in [`surfaces/qbx.json`](../../libraries/synex_bridge/compatibility/surfaces/qbx.json) and the generated [matrix](matrix.md).
