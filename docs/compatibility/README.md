# Compatibility bridges

> [!WARNING]
> `synex_bridge` and the QB, QBX, and ESX providers form an implemented Experimental Alpha Compatibility Platform. They are outside the frozen `synex_core` Production-Beta profile and have no accepted database, FXServer, client, deployment, integration, or security certification.

The bridge is a narrow, catalog-governed migration boundary for reviewed legacy consumers. It does not load QBCore, Qbox, or ESX, and it does not promise that an unchanged third-party resource will run. Every cataloged surface is currently `PARTIAL` or `UNSUPPORTED`, and every surface is deprecated in favor of a native Synex integration.

## Guide

- [Architecture](architecture.md) and [security boundary](security.md)
- Providers: [QBCore](qbcore.md), [Qbox](qbox.md), and [ESX](esx.md)
- [Modes and deployment](modes.md)
- [Mappings](mappings.md) and [domain adapters/catalogs](adapters.md)
- [Profiles](profiles.md) and [certification](certification.md)
- [Generated surface matrix](matrix.md), [migration](migration.md), and [troubleshooting](troubleshooting.md)

The checked-in configuration is deliberately fail-closed:

| Artifact | Checked-in state | Runtime effect |
| --- | --- | --- |
| [`profiles.json`](../../libraries/synex_bridge/compatibility/profiles.json) | No profiles | No script/version combination is compatible or certified. |
| [`consumers.json`](../../libraries/synex_bridge/compatibility/consumers.json) | No consumers; default mode `strict` | Every compatibility consumer is denied. |
| [`mappings.json`](../../libraries/synex_bridge/compatibility/mappings.json) | Six `PARTIAL` cash/bank aliases and three bounded `PARTIAL` hunger mappings; no identity or group mappings | Account aliases and the reviewed hunger key can be resolved. No consumer is authorized by the checked-in configuration, and active groups cannot be projected. Identity falls back to the persistent provider-specific resolver. |
| [`money-policies.json`](../../libraries/synex_bridge/compatibility/money-policies.json) | No policies | Every money mutation is denied. |

Directory presence and a `PARTIAL` surface are implementation evidence only. They are not an enablement decision.

## Catalog, profiles, and status

The machine-readable source of truth is [`libraries/synex_bridge/compatibility`](../../libraries/synex_bridge/compatibility/):

- `surfaces/{qb,qbx,esx}.json` binds the Synex provider resource/version and separately records the reviewed upstream target-framework API range before listing legacy surfaces, native mappings, required capabilities, modes, evidence, and bounded status;
- `profiles.json` binds an exact provider version, target-framework API range, and legacy script version to required surfaces, accepted statuses, required adapters, exact catalog name/version-range/domain/revision requirements, failure policy, checked-in evidence, and (for `CERTIFIED`) one CLI certificate artifact;
- `consumers.json` explicitly enables a resource, provider, profile, mode, and failure policy; an absent or disabled consumer is denied;
- `mappings.json` contains explicit identity, account, group/grade/boss-role/duty, and metadata mappings plus forbidden metadata roots;
- `money-policies.json` is the only authority for compatibility funding and sink actions;
- `schemas/*.schema.json` rejects unknown fields and malformed catalog envelopes.

The shared status vocabulary is:

- `CERTIFIED`: one exact tested script version whose required surfaces/adapters, tracked test hashes, complete runtime evidence, source evidence, and checked-in review lock all pass the certification gate;
- `COMPATIBLE`: bounded catalog compatibility without deployment certification;
- `PARTIAL`: only the named subset or semantics exist;
- `UNSUPPORTED`: deliberately rejected or absent;
- `UNKNOWN`: insufficient evidence.

Source scanning, an operator-supplied evidence file, or a handwritten `CERTIFIED` label cannot create certification. The current profile catalog is empty and the generated [compatibility matrix](matrix.md) contains only `PARTIAL` and `UNSUPPORTED` surfaces.

## Developer CLI

Run the source CLI from the repository root:

```text
node --experimental-strip-types tools/cli/src/bin.ts compat status
node --experimental-strip-types tools/cli/src/bin.ts compat matrix
node --experimental-strip-types tools/cli/src/bin.ts compat scan path/to/resource
node --experimental-strip-types tools/cli/src/bin.ts compat explain path/to/resource
node --experimental-strip-types tools/cli/src/bin.ts compat profile <profile-id>
node --experimental-strip-types tools/cli/src/bin.ts compat adapters
node --experimental-strip-types tools/cli/src/bin.ts compat observe path/to/resource
node --experimental-strip-types tools/cli/src/bin.ts compat doctor
node --experimental-strip-types tools/cli/src/bin.ts compat execute <profile-id> --output artifacts/compatibility/<profile-id>.execution.json
node --experimental-strip-types tools/cli/src/bin.ts compat certify <profile-id> --runtime-evidence path/to/evidence.json --execution-evidence artifacts/compatibility/<profile-id>.execution.json --output libraries/synex_bridge/compatibility/certifications/<profile-id>.json
node --experimental-strip-types tools/cli/src/bin.ts compat drift
node --experimental-strip-types tools/cli/src/bin.ts compat drift --online --timeout 10000
```

All commands support `--json`. `scan` reads bounded, non-symlink Lua, JavaScript, TypeScript, and `fxmanifest.lua` files, strips ordinary comments, and reports framework signatures, catalog surface candidates, domain dependencies, and direct legacy-table SQL. `explain` resolves those findings against the catalog. Neither command executes the scanned resource or infers certification.

`observe` keeps its static scan and optional operator-supplied runtime evidence in separate report fields and never returns `CERTIFIED`. `doctor` statically checks account, group, grade, and identity mappings for missing deployed-provider coverage, malformed or ambiguous entries, and provider/entity-scoped legacy-ID collisions. It also verifies that active money policies are uniquely matched and bound to an enabled consumer and account mapping, and reports profile-selected money consumers without an active policy as fail-closed coverage warnings. Provider conflicts, missing adapters, profile drift, and false certification claims remain checked as well. With complete operator evidence, it additionally checks provider state/health, required capability grants, stale or duplicate consumer bindings, stale telemetry, optional callback cleanup counters, historical-facade conflicts, exact provider/profile versions, telemetry truncation, and terminal-counter bounds. Missing runtime or callback evidence is reported as an explicit `UNKNOWN`/deferred check instead of being treated as zero activity. `execute` safely runs only tracked repository-owned Node tests already named by the exact profile, with fixed invocation, bounded output and timeout; missing build/runtime requirements and skipped assertions remain `UNKNOWN`. `certify` is the separate fail-closed verifier and requires matching closed execution and runtime evidence, exact provider/runtime version, the separately reviewed target-framework API range, tracked PASS test paths and hashes, required adapters, and the checked-in review lock. Its fingerprint directly binds the consumer-authorization and money-policy catalogs in addition to the profile, surface, review-lock, and schema bindings. It writes a runtime-usable artifact only to the path declared by that profile. Neither command launches FXServer or a FiveM client.

`--runtime-evidence <file>` is accepted only by `observe`, `doctor`, and `certify`. The file must remain inside the repository, be a non-symlink regular JSON file no larger than 1 MiB, and satisfy the closed [`runtime-evidence.schema.json`](../../libraries/synex_bridge/compatibility/schemas/runtime-evidence.schema.json). It is always operator evidence, never independent runtime observation. Offline `drift` validates checked-in catalog and commit/source pins and reports upstream `UNKNOWN`. The explicit `--online` mode contacts only the pinned projects' official raw GitHub sources with bounded timeout and response size; failures remain `UNKNOWN`, not `PASS`. The current CLI catalog summary validates and counts surfaces, profiles, consumers, money policies, and mappings.

## Runtime authorization

An operation crosses all of these gates:

```text
immediate Cfx caller
  -> official provider binding
  -> requested compatibility capability
  -> operation-to-surface mapping
  -> enabled consumer and matching profile
  -> accepted surface status for the selected mode
  -> native Synex capability and domain validation
```

The central coordinator accepts server calls only from `synex_bridge_qb`, `synex_bridge_qbx`, or `synex_bridge_esx`, and the claimed provider must match `GetInvokingResource()`. A downstream server resource cannot substitute another consumer identity. Operator capability policy remains mandatory and deny rules still win. Cataloged sub-surfaces are independent gates: for example, QB Core Object filtering does not follow from base Core Object access, and job, gang/group, duty, money/account update events do not follow from lifecycle publication. A provider emits an optional update family only when at least one active configured consumer resolves that exact surface and its native capability policy.

For server-side domain extensions, each official provider exposes `InvokeCompatibilityAdapter(request)` plus `ResolveCompatibilityCatalog(request)` and `InvokeCompatibilityCatalog(request)`. Requests contain only a cataloged surface, operation, and—on Invoke—a bounded object payload; native capability requirements come exclusively from that surface and cannot be supplied by the consumer. The coordinator resolves and invokes an owner-bound adapter or exact-revision catalog only after both capability gates pass. No adapter, executable catalog, profile, or consumer is enabled by default, and these paths add no client network endpoint. See [domain adapters and catalogs](adapters.md) for the exact boundary.

`strict` accepts only `CERTIFIED` or `COMPATIBLE` status and also rejects deprecated surfaces. Every current surface is deprecated, so none can pass `strict`. `compat` and `silent` may admit a cataloged `PARTIAL` surface, subject to the profile and consumer failure policy. With the checked-in empty profile and consumer registries, all three modes remain denied.

When both resources are running, `synex_notify` offers one server-side adapter definition for the `notifications` domain. It remains `PARTIAL` and exposes only bounded `send` with an exact session target plus canonical notification payload. The QB, QBX, and ESX providers also implement a narrow client function/export mapping for their common Notify helpers. Bridge binds every such call to the immediate consumer and projects only a local, normal, plain-text toast; legacy notification events, player targets, system origin, actions, banners, and privileged priority remain unsupported. The consumer still needs an explicit profile plus compatibility and Notify grants, while the checked-in profile/consumer registries enable none. These mappings do not persist an offline notification or certify compatibility. See the [Notify compatibility boundary](../notify/compatibility.md).

## Components and facade boundary

| Path | Responsibility |
| --- | --- |
| [`libraries/synex_bridge`](../../libraries/synex_bridge/) | Central catalog resolver, persistent identity/metadata store, policy gates, bounded telemetry, lifecycle coordination, and optional read-only Control provider. |
| [`resources/synex_bridge_qb`](../../resources/synex_bridge_qb/) | Partial QBCore-shaped online-player facade. |
| [`resources/synex_bridge_qbx`](../../resources/synex_bridge_qbx/) | Partial Qbox exports, online-player projection, and detached read-only offline projection. |
| [`resources/synex_bridge_esx`](../../resources/synex_bridge_esx/) | Partial ESX shared-object and detached xPlayer facade. |
| [`compat/facades`](../../compat/facades/) | Optional historical resource names `qb-core`, `qbx_core`, and `es_extended`. |

Direct provider exports bind the actual invoking resource as the consumer. A historical-name facade captures its own immediate caller and forwards it exactly once through a provider's `*ForConsumer` entry point; caller-supplied consumer identities are not accepted. These facades are nevertheless privileged trusted-computing-base code: a modified or replaced repository facade could forward another principal's authority. Deploy only the exact reviewed facade tree, protect its resource directory like the providers themselves, and treat a facade hash or ownership change as a security-relevant compatibility change.

Each repository-owned historical facade declares `synex_compatibility_facade 'true'` in its `fxmanifest.lua`. A native provider watches the corresponding historical name while it is `starting` or `started` and reads that exact metadata marker. If the marker is missing, unreadable, or not exactly `true`, the provider treats the resource as a real upstream framework and rejects compatibility authorization with `COMPAT_FRAMEWORK_CONFLICT`. The provider re-evaluates the fence when that resource starts or stops; it does not stop or modify the upstream resource.

The historical facades therefore replace and conflict with real upstream resources of the same name. They are not enabled by default and are not general drop-in replacements. QB and QBX can both project the same canonical Synex player, but they cannot both own the shared `QBCore:*` lifecycle family. Ownership is evaluated from live resource state and current authorization: a started, authorized QB provider/consumer pair has priority; QBX takes over when QB is stopped, excluded, or denied and an authorized QBX pair is available. A running QB/QBX handoff is silent for the shared family, so it does not fabricate another unload/load pair. Qbox-only `qbx_core:*` events remain owned by the authorized QBX lifecycle path. This keeps mixed-provider deployments truthful without publishing duplicate global QBCore lifecycle events.

## Detached online-player projection

Online player facades accept either a current source or a provider-specific stable identifier where that provider catalogs the form, and resolve it back to an `ACTIVE` Synex character with a current session fence. QB and QBX use `citizenid`; ESX uses `identifier`. QB and ESX enumeration returns only bounded active-session results. The returned objects are detached DTOs; modifying them does not mutate Synex.

QBX additionally exposes a detached `GetOfflinePlayer(citizenid)` read model. It is read-only even when that character is currently connected: money and mapped metadata may be read, while money, metadata, job, gang, and duty mutators return `COMPAT_OFFLINE_MUTATION_UNSUPPORTED`. QB and ESX do not expose offline player lookup. No form accepts a caller-selected Synex character or account owner as authority.

Account projection is exact and fail-closed:

- only reviewed provider aliases exist; the checked-in catalog currently defines `cash` and `bank` for each provider;
- aliases are provider-declared names only; their native tuples come exclusively from the central compatibility-mapping catalog (`central.compatibility-mappings`);
- both aliases use currency `usd`, asset role, and `minor_unit` `0`, with distinct deterministic owner-scoped `cash_<character>` and `bank_<character>` keys;
- the character must own exactly one active account matching the complete currency/key/role/minor-unit tuple;
- duplicate aliases or provider-scoped native tuples are rejected as ambiguous before Accounts is called;
- discovery is bounded to 50 accounts and rejects a continuation cursor instead of treating a partial page as complete.

### Persistent identity and metadata

[`identity_store.lua`](../../libraries/synex_bridge/identity_store.lua) owns the bridge's two persistent tables through Core DataPort:

- `synex_compatibility_identities` binds a provider identifier (`citizenid` for QB/QBX or `identifier` for ESX) to one Synex character. A static catalog mapping wins; otherwise a stable provider-specific identifier is generated once and persisted.
- `synex_compatibility_metadata` stores only explicitly mapped non-sensitive keys after type, range, length, and forbidden-root validation. Writes use an expected-version compare-and-swap boundary.

Metadata projection is limited to 64 stored rows per character and to the reviewed catalog allowlist. System roots such as identifiers, accounts, money, permissions, and tokens are always forbidden. The checked-in catalog maps only provider-specific `hunger` integers from `0` through `100` to `needs.hunger`; all other legacy metadata keys fail closed. A successful compatibility metadata mutation invalidates that source's projection and schedules one refresh bound to its exact source, character, session, and source-generation fence; stale queued work cannot refresh a replacement session. Character deletion removes both identity and metadata rows transactionally through the registered lifecycle participant.

### Groups, grades, and duty

The bridge calls the bounded server-side `synex.groups` `compatibility_snapshot` service for the active character. It accepts at most eight complete membership rows, at most eight roles per row, no continuation cursor, and no truncation marker. Each active membership then requires one exact reviewed mapping of:

```text
provider + native group type + native group key
  -> legacy group type + legacy group name
  -> exact native grade key / legacy numeric grade pair
  -> optional explicit native boss-role keys
  -> explicit duty support
```

Missing or ambiguous group/grade mappings fail with a compatibility mapping error; incomplete source data fails as unavailable. Every active membership must have an exact mapping, including memberships that are not selected as primary. More than one primary membership resolving to the same legacy group type is ambiguous and fails the complete projection instead of choosing one by order.

The optional `bossRoles` array contains reviewed native role keys. `isboss` becomes `true` only when the active membership carries at least one role whose key is explicitly listed by its mapping; an absent list or any unmapped role remains `false`. Duty is omitted unless the mapping explicitly supports it. The checked-in group mapping list is empty, so a character with no active memberships can project an empty group view, while any active membership prevents a complete legacy player projection until reviewed mappings exist.

Provider shapes remain intentionally different:

- QB projects one primary job and one primary gang/group with exact numeric grades; duty is represented for the mapped job only, and `isboss` comes only from mapped `bossRoles`.
- QBX exposes its mapped group set plus primary job/gang projections; job duty is retained, gang duty is not exposed in player data, and `isboss` comes only from mapped `bossRoles`.
- ESX projects one primary job. Synex groups are not treated as an ESX permission-group equivalent.

Configured mutation paths remain intentionally narrower than the legacy frameworks. QB and QBX detached player facades expose `SetJob`, `SetGang`, and `SetJobDuty`; QBX also exposes the standalone `SetJob`, `SetGang`, `SetJobDuty`, `SetPlayerPrimaryJob`, and `SetPlayerPrimaryGang` forms for an online source or stable citizen identifier as appropriate. ESX exposes the two-argument `xPlayer.setJob(name, grade)` subset. Every call needs an enabled consumer/profile, the provider write capability, the matching native Groups capability, a current source-generation fence, and one exact mapping. `SetJob`/`SetGang` resolve an already-active membership and an existing active grade, then use the policy-aware `compatibility_set_primary_grade` Groups service to change the grade and primary selection atomically. They never invite, add, remove, or create a membership, group, or grade. ESX rejects `xPlayer.setJob(name, grade, onDuty)` before writing because job and duty cannot currently be committed by one native primitive. Standalone Qbox membership add/remove remains unsupported.

Duty is real Groups state, not a compatibility boolean. Enabling duty starts or updates the mapped primary job's duty session with the cataloged duty state; disabling it stops the active session. The bridge carries membership, primary-selection, duty-session, and source-generation revisions through the native service boundary and fails on stale or ambiguous state. With the checked-in empty group mapping catalog, every group or duty mutation remains denied until an operator reviews mappings against existing Groups definitions.

### Explicit unsupported surfaces

The catalog records reviewed gaps instead of omitting them or implying fallback behavior. The generated [compatibility matrix](matrix.md) is authoritative; the following groups summarize the current explicit `UNSUPPORTED` entries:

| Provider | Explicitly unsupported surface groups |
| --- | --- |
| QB | Offline player lookup, shared Jobs/Gangs/Vehicles/Items registries, and permission mutation/admin APIs. Bounded `GetCoreObject` array filtering exists only for fields exposed by the partial compatibility object. Citizen-ID lookup, active-player enumeration, and read-only permission projection are `PARTIAL`, not unsupported. |
| QBX | Standalone membership add/remove, Jobs/Gangs/Vehicles registries, routing-bucket management, QB Core Object compatibility, callback registration, and permission/admin APIs. Citizen-ID lookup, read-only offline lookup, identifier-capable money/metadata/group/duty operations, and standalone primary-job/primary-gang mutation are `PARTIAL`. |
| ESX | Offline player lookup, inventory, combined job/duty mutation, arbitrary `GetExtendedPlayers` filters, and permission mutation/admin APIs. Identifier lookup, bounded active-player enumeration, catalog-mapped custom accounts, and read-only permission-group projection are `PARTIAL`. |

An `UNSUPPORTED` entry has no native mapping, compatibility capability, or adapter reference. Inventory, vehicle, bucket, and administrative behavior can become available only through a separately implemented and reviewed owning-domain adapter; none ships in the current catalog. ESX account names are different: the provider discovers them from reviewed account mappings and therefore admits a catalog-mapped custom account without hard-coding it, while arbitrary unmapped names still fail closed.

## Money policy boundary

An account alias is not mutation authority. Every `AddMoney` or `RemoveMoney` path requires one `ACTIVE` entry in `money-policies.json` matching the exact provider, consumer, alias, direction, and normalized legacy reason. A `transfer` policy binds the request to a reviewed counterparty account UUID. An `add` policy may instead select `mint`, and a `remove` policy may select `burn`; those explicit actions use the Accounts currency topology and cannot name a counterparty. Every policy supplies a reviewed native reason code and selects the corresponding Accounts `transfer_v2`, `mint_v2`, or `burn_v2` contract at version `2.0.0`.

There is no counterparty ConVar fallback. The checked-in policy list is empty, and the current account mappings also deny default funding and sink behavior. An otherwise authorized request therefore fails the money-policy gate with `COMPAT_MONEY_POLICY_DENIED`; the default empty consumer/profile catalogs can reject it even earlier. Explicit mint/burn additionally requires the immediate consumer's `synex.accounts.mint`/`synex.accounts.burn` capability and the provider's matching native capability. Only the reviewed provider executors receive that native capability in the checked-in policy; no consumer or money policy is enabled by default. The bridge never creates an account, converts currency, or selects a counterparty from client input.

`SetMoney` reads the authoritative amount and account sequence, returns without a ledger write when the target already matches, and otherwise posts only the required positive delta through a reviewed `transfer` policy. Mint/burn policies are rejected for `SetMoney` because those contracts do not carry the source/destination sequence fence required by this compatibility path. The transfer carries the corresponding expected source or destination sequence and reuses the exact idempotency request on its single bounded retry; no balance is assigned directly.

## Callbacks, lifecycle, restart, and diagnostics

Each callback-capable provider owns one bounded client-to-server callback transport. A request carries at most 16 dense JSON-compatible arguments and 16 KiB, with maximum nesting depth 6, 192 total values, and 1,024 bytes per string. The server admits at most eight pending calls per source and 512 per provider, applies an eight-token-per-second source bucket with a burst of 16, and terminates admitted calls after ten seconds. The client independently caps itself at eight pending calls and accepts responses only from the server. Every server completion rechecks the exact active `sessionId + sourceGeneration + characterId` fence before delivery, so disconnect, source reuse, or an in-session character switch cannot receive an earlier response. QB and ESX catalog callback registration; QBX deliberately does not.

Client callback exports are exposed only to resource names in the coordinator-produced callback allowlist, and the server binds a request to the same configured consumer, provider-local callback name, registration owner, active session, and current callback surface. This is an API-admission and compatibility boundary, not client-side confidentiality or cryptographic resource authentication: client code and the consumer string sent over the network are untrusted. A registered callback handler must still authorize the player and validate the requested gameplay action on the server before reading sensitive data or mutating native state.

Callback names are provider-local but single-owner: the same consumer may replace its own handler, while a different consumer receives `CALLBACK_NAME_CONFLICT`. Duplicate completions are ignored. A consumer stop removes its registrations, aborts its pending calls, and removes its bounded usage and warning state; disconnect clears the source bucket and generation-fenced pending calls. Provider stop clears the whole callback runtime, while the client-side `onClientResourceStop` fence discards pending handlers so late responses from a prior provider generation cannot execute after restart.

Legacy lifecycle events are published only when at least one started enabled consumer profile explicitly requires the provider's lifecycle surface and a complete player projection succeeds. Client player-data access is a separate cataloged surface: the coordinator resolves all active consumers that pass that surface and sends the sorted bounded allowlist with the detached provider projection. QB and ESX callback access is further restricted to consumers that also pass client player-data and server callback-registration gates; a callback-only profile is incomplete, and QBX client callbacks remain unsupported. Direct client exports check their immediate `GetInvokingResource()` against the applicable list; historical client facades may forward only a listed consumer through their dedicated `*ForConsumer` export. If no consumer passes the player-data surface, the provider clears the local snapshot and both access lists even when base lifecycle publication is active.

The provider-local client event accepts only server-origin delivery and carries detached, non-sensitive player data plus the allowlists, or clears the complete local projection when player-data access is absent. The allowlist prevents accidental or unsupported API use; it does not make data already delivered to a game client confidential from other client resources. Public server lifecycle payloads are likewise data-only. They never contain a consumer-bound Player/xPlayer facade or callable closure because any server resource could observe and reuse a broadcast value. Privileged server methods remain behind caller-bound server exports and their native capability gates.

Loaded delivery is bounded to 1,024 exact `sessionId + sourceGeneration` fences. A repeated commit reconciles changed data through the update path without replaying a load. Accounts and Groups domain events first derive a safe character target from `character_id`, `characterId`, or `owner_kind = character` with `owner_ref`. A valid target invalidates and refreshes only matching online projections; a missing, malformed, or conflicting identity deliberately falls back to bounded global invalidation so stale state is never preserved. Topics arriving before one zero-delay per-source refresh are coalesced, sorted, generation-fenced, and emitted only when the detached provider projection actually changed. There is no lifecycle polling thread. A reused source unloads its stale generation before the new load. The matching lifecycle unload and `playerDropped` each publish at most one unload and clear pending source work.

QB preserves the public event names but intentionally narrows the global server load value to `{ PlayerData = <detached data>, Offline = false }`; privileged Player functions remain available only through caller-bound server exports. Client `QBCore:Client:OnPlayerLoaded` receives no payload. QB job, gang, duty, and money update families each require their own cataloged surface; duty is represented through the job projection because QB does not invent Qbox-only `SetDuty` events. QBX applies the same data-only rule to its shared QBCore server load payload. Its group, duty, and money update families are independently gated, and its shared QBCore events are emitted only while it owns that family. ESX publishes a data-only xPlayer-shaped snapshot on the global server load event, gates job and account updates separately, and keeps privileged xPlayer methods behind caller-bound server exports; `isNew` is conservatively `false`, and no fabricated skin payload is supplied.

A consumer stop removes its callback registrations, pending calls, usage rows, and provider deprecation-warning keys. If another started, authorized lifecycle consumer exists for that provider, publication authority moves to it without a synthetic unload/load cycle. If no replacement exists, retained deliveries are suspended through the normal public unload path and may publish a corresponding load when an eligible consumer returns. A Core stop likewise suspends retained lifecycle entries, clears cached API/projection state, pending callbacks, subscriptions, and queued refreshes, then uses generation-fenced rebinding so an old retry cannot replace the current binding; the unload/load pair reflects the real unavailable interval. A provider restart is different: the new provider process enumerates bounded active Core sources and rehydrates its provider-local client projections with `resync = true`, and provider handlers suppress duplicate public load events during that resync.

### Bounded usage telemetry

Each provider keeps a process-local table keyed by `consumer resource + operation`, limited to 512 entries. A row contains:

- a `calls` count saturated at `9,007,199,254,740,991` plus bounded `firstSeenMs` and `lastSeenMs` timer ticks;
- one terminal count per call: `success`, `denied`, `unsupported`, `error`, `timeout`, or `rate_limited`;
- a `deprecated` count, which equals `calls` because every current provider surface is deprecated;
- saturating latency `samples` and `totalMs`, plus `maximumMs`; Control derives `averageMs`.

`firstSeenMs` and `lastSeenMs` are wrap-aware, process-relative `GetGameTimer()` ticks, not wall-clock timestamps. The data resets with the provider process and is deleted per consumer when that resource stops. Once the 512-key bound is reached, new consumer/operation keys are not recorded and the snapshot is marked truncated. The snapshot contains no arguments, payloads, player/source/session identifiers, account IDs, money amounts, reasons, trace IDs, raw errors, SQL, or parameters.

Only `synex_bridge` may read a provider's unfiltered Control usage export. An authorized compatibility consumer can request only its own filtered snapshot through the provider's consumer-facing usage export. The coordinator validates exactly one bounded snapshot from each QB, QBX, or ESX provider and exposes at most 1,536 combined rows through Control. Control cursor pages default to 20 rows and accept at most 25. A provider that is stopped or returns an invalid snapshot is `UNAVAILABLE`; its missing evidence is not represented as zero calls. A running provider reports `READY` or `DEGRADED` with bounded reasons for a framework-name conflict, provider errors, observed unsupported calls, or callback pressure, plus current callback, projection, registration, and usage capacities. The legacy-usage view reports provider, adapter resource, consumer, operation, call/terminal/deprecation counts, first/last ticks, latency samples/total/maximum/average, availability, health reasons, and truncation. A separate process-local `catalog_usage` view reports only provider, consumer, Resolve/Invoke action, terminal counts, latency, truncation, and registered executable-catalog count; it never exposes catalog records or payloads.

`compat doctor` evaluates unsupported and deprecated call rates only for complete, untruncated telemetry rows with at least 20 calls. It emits an operational warning at an unsupported rate of 5% or a deprecated rate of 25%; these are migration-pressure thresholds, not compatibility certification. Stale callback or registration findings require all four provider health counters (`callbackPending`, `callbackCapacity`, `callbackRegistrations`, and `callbackRegistrationCapacity`). If those counters are absent, that check remains `UNKNOWN`.

Every completed provider operation also writes best-effort Core metrics under its resource prefix (`synex_bridge_qb_`, `synex_bridge_qbx_`, or `synex_bridge_esx_`):

| Signal | Labels / meaning |
| --- | --- |
| `compat_calls_total` | `operation`, terminal `outcome` |
| `compat_deprecated_total` | `operation` |
| `compat_operation_duration_ms` | `operation`; Core histogram |
| `compat_denials_total`, `compat_unsupported_total`, `compat_provider_error_total` | `operation`, for the corresponding terminal class |
| `compat_adapter_missing_total`, `compat_stale_session_rejected` | `operation`, for the exact failure code |
| `compat_callbacks_total`, `compat_callback_timeout_total`, `compat_callback_rate_limit_total` | callback outcome and pressure |
| `compat_money_translation_total`, `compat_money_translation_failed` | money outcome and failed operation |
| `compat_money_retry_total` | the operation and policy action for one bounded retry of a retryable native ledger mutation |
| `compat_group_translation_total`, `compat_group_translation_failed` | group-projection outcome and failures |
| `compat_projection_cache_hit`, `compat_projection_cache_miss` | bounded online-player projection-cache activity |
| `compat_projection_invalidations_total` | the fixed Accounts or Groups topic that invalidated provider projections |

Core defaults to 2,048 metric series and clamps its configured series bound to `8..16,384`. A metric accepts at most 12 labels; the metric name is limited to 128 bytes, a label key to 64 bytes, a rendered label value to 128 bytes, and the encoded series key to 2,048 bytes. Core keeps the newest 512 observations per histogram series. A metric snapshot reports histogram `count`, `minimum`, `maximum`, and nearest-rank `p50`, `p95`, and `p99`; these quantiles belong to Core's process-local histogram, not to the Bridge Control usage row. A missing Core Metrics API or rejected metric sample is contained and does not turn the compatibility call into success or failure.

The coordinator's resolver has a separate bounded series registry (64 owners, 256 total series, 64 per owner) and 256 warning keys. Its timer is wrap- and epoch-aware; an operation that crosses a timer epoch is rejected as stale instead of producing an invalid duration. Resolver policy warnings are emitted once per consumer epoch and warning key and are suppressed in `silent` mode. On consumer stop, the coordinator invokes the Kernel owner/epoch cleanup and removes that consumer's resolver series and warning keys. Each provider independently emits its deprecation warning once per consumer/operation until that consumer stops; provider usage rows, provider warnings, and Core metrics are never suppressed by `silent` mode.

### Money tracing and idempotency

An admitted `AddMoney` or `RemoveMoney` call receives one bounded coordinator `traceId`. The provider accepts an integer amount from `1` through `9,007,199,254,740,991`, creates one UUID operation ID, and sends it as the Accounts payload `idempotency_key`, RPC `idempotencyKey`, and ledger `reference_id`. The same `traceId` is carried in the RPC options and in compatibility provenance JSON limited to 4,096 bytes. The RPC timeout is five seconds. A retryable failure may trigger one immediate retry with the exact same request and operation ID, so that bounded retry cannot post a second ledger transaction. A later independent legacy call receives a new operation ID and is not deduplicated against the earlier call.

Every admitted supported provider operation runs in a normal process-local Core span. Generic adapter and catalog calls use the coordinator's fixed `InvokeAdapter`, `ResolveCatalog`, or `InvokeCatalog` span; facade construction and provider usage reads use their exact closed provider API names. Span labels contain only provider, immediate consumer resource, and API name. Requests, payloads, results, callback arguments, money values, reasons, identifiers, and arbitrary metadata are never retained.

The optional Bridge Control provider exposes read-only overview and health; the generated surface matrix; configured consumers, profiles, and mapping metadata; provider-adapter availability; unsupported/deprecated surfaces; bounded process-local legacy and catalog usage; error and latency counters; and migration-readiness findings. Identity mapping values are redacted. Live views remain `VIEW_UNAVAILABLE` when their evidence cannot be read, and the provider-adapter view retains explicit `UNAVAILABLE` states rather than inventing zero activity. Control does not authorize compatibility, return catalog payloads, mutate state, or certify a profile.

`npm run benchmark` includes five Bridge-specific local regression paths: bounded projection copying, bounded callback-argument DTO validation, indexed account-mapping resolution, consumer/profile/surface/adapter resolution, and telemetry aggregation. These use fixed in-memory fixtures inside Wasmoon and do not execute provider resources, facades, FXServer, MariaDB, an external framework, or a FiveM client. Their timings cannot establish compatibility, server capacity, or production performance.

Headless and static tests cover resolver, policy, mapping, callable, persistence, bounded telemetry, cleanup, restart-generation behavior, consistent canonical identity/money/group projection, provider lifecycle signatures and ordering, event-update deduplication, source reuse and character switching, Core/provider rebind, provider-local client state, consumer failover, and mixed QB/QBX ownership. A real exact-candidate FXServer provider lifecycle, historical-facade conflict exercise, client callback/event smoke, and downstream deployment acceptance have not been completed. The platform therefore remains Experimental Alpha even when all repository gates pass.

## Deliberate limits

- no enabled consumer, certified profile, domain adapter, or executable catalog ships;
- no offline mutation, QB/ESX offline lookup, direct legacy SQL, arbitrary dynamic method dispatch, or mutable authoritative framework object;
- no inventory, vehicle/entity, permission/admin mutation, membership add/remove, organization creation, grade-definition creation, routing-bucket mutation, or shared Jobs/Gangs/Vehicles/Items registry authority;
- no implicit identity equivalence between providers and no implicit group or permission equivalence;
- no money write without an exact reviewed transfer, mint, or burn policy and its action-specific native capability;
- no claim that an operator evidence file or observed zero calls proves migration completion;
- no production support inherited from `synex_core`.

The bridge does not consume `synex_entities` contracts or translate Cfx handles, NetIDs, routing buckets, or network ownership into Synex authority. See the [generated matrix](matrix.md), [legacy migration workflow](migration.md), and [Entity Authority reference](../reference/entities.md) for the adjacent boundaries.
