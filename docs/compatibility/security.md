# Compatibility security

The bridge treats legacy consumers and all client payloads as untrusted. Compatibility never grants superuser semantics and never bypasses native Synex authority.

## Two independent gates

Every admitted operation requires both:

1. a configured compatibility consumer/profile/surface capability; and
2. every native Core capability assigned to that operation for the immediate consumer resource.

The coordinator and the native provider both enforce these gates before a domain service or RPC is called. Provider-owned native capabilities permit the provider to reach Core, but never substitute for the consumer's grants. Deny rules still win. Caller-supplied consumer names are rejected except at the narrow historical-facade hop, where the repository facade must be the immediate caller and forwards the consumer it observed.

## Historical facades are trusted-computing-base code

`qb-core`, `qbx_core`, and `es_extended` compatibility facades are intentionally privileged. Cfx authenticates only the immediate caller, so the provider can prove that the repository facade called a `*ForConsumer` export but cannot independently prove which resource called into that facade. The reviewed facade closes that gap by deriving the consumer from `GetInvokingResource()` and never accepting a caller-supplied principal.

This is a deployment trust boundary, not a sandbox. Replacing or modifying a historical facade can delegate another resource's grants and must be treated like modifying `synex_bridge` or a provider. Use only the exact reviewed repository facade, protect its files and start order, never grant its historical name to an unrelated resource, and re-run security plus exact-candidate facade tests after any facade change. The metadata marker prevents accidental coexistence with a real framework; it is not a cryptographic integrity check.

The native capability policy is closed and operation-specific:

| Compatibility operation | Required native consumer capabilities |
| --- | --- |
| Core/shared object and callback operations | `synex.identity.read` |
| Full player, identifier lookup, enumeration, offline read, or lifecycle projection | `synex.identity.read`, `synex.accounts.read`, `synex.groups.read` |
| Money-only projection | `synex.identity.read`, `synex.accounts.read` |
| Groups-only projection | `synex.identity.read`, `synex.groups.read` |
| Metadata read or mapped CAS mutation | `synex.identity.read` |
| Permission projection | `synex.identity.read`, `synex.permissions.read` |
| Money mutation | `synex.identity.read`, `synex.accounts.read`, plus policy-selected `synex.accounts.transfer`, `synex.accounts.mint`, or `synex.accounts.burn` |
| Job/gang grade and primary mutation | `synex.identity.read`, `synex.groups.read`, `synex.groups.compatibility.set_primary_grade` |
| Duty-session mutation | `synex.identity.read`, `synex.groups.read`, `synex.groups.duty` |
| Runtime telemetry | `synex.runtime.read` |

An operation without an explicit native policy is rejected as `COMPAT_API_UNSUPPORTED`. Compatibility approval with a native denial, or native approval with a compatibility denial, both stop before domain access. Cataloged sub-surfaces are not bundles: filtered QB Core Object access, client player data, client callback invocation, and every provider-specific job, gang/group, duty, money, or account update-event family are resolved independently. Base object or lifecycle access does not implicitly authorize them.

Generic domain adapters and catalogs use the same two gates. Their capability policy is stored on the selected surface as a closed operation-to-native-capabilities map. Catalog publication has a separate fail-closed owner gate: Core must explicitly grant the invoking registration owner `synex.compat.catalog.register`, which is not granted by the default policy. The request accepts no capability field, so it cannot remove, replace, or underclaim a required grant. Provider, consumer, profile, surface, operation, executable version, and handler are all resolver outputs; catalog domain, authority, and exact revision are resolver outputs as well. Resolve and Invoke both enforce the gates. Only the three official server providers may enter the coordinator invocation boundary.

## Network boundary

Each callback-capable provider creates one client-to-server callback endpoint. The shared handler validates connected source, request ID, callback name, argument count, dense array shape, DTO depth/entry/string/byte limits, rate limit, per-source/global pending capacity, configured callback consumer, callback ownership, current callback-surface authorization, active session, source generation, and active character ID. Server responses and projection messages are accepted by clients only when `source == 65535`.

Delayed responses are discarded after disconnect, source reuse, timeout, callback owner stop, provider/Core stop, or owner-generation change. No callback payload becomes an arbitrary table passthrough. The consumer name carried by a client request is still untrusted network input; these checks bind it to configuration and registration state but do not authenticate an originating client resource. The registered server callback owns business authorization and must validate the player identity, permissions, ownership, proximity, and mutation input appropriate to its action.

Public server lifecycle events are broadcasts and have no per-listener resource identity. Their player/xPlayer-shaped payloads are therefore data-only and contain no function that captures an authorized consumer. Privileged server methods are constructed only for direct exports after the immediate server resource passes both gates.

The coordinator also derives a bounded client player-data allowlist and, where cataloged, a callback allowlist restricted to consumers that also pass player-data and server callback-registration gates. A callback-only profile is incomplete and cannot activate. Player data is sent only when the player-data list is non-empty; otherwise the provider clears any retained client snapshot and both lists. Direct client exports compare `GetInvokingResource()` with the applicable list, and the repository historical facade can forward a listed consumer once. This reduces accidental cross-consumer API access, but it is not a secrecy boundary: another client resource can observe known events or alter local code, and the server never treats client resource identity as authority. Client projections therefore remain detached and non-sensitive. Provider restart refreshes this projection with `resync = true`, which suppresses a duplicate public loaded event. A consumer or Core outage without replacement follows the normal fenced public unload/load boundary instead of claiming uninterrupted authority.

Domain-adapter and catalog invocation add no client network event. Their server requests, generated contexts, payloads, handler errors, and results use separate closed byte/depth/entry/string bounds. Metatables and callables never cross the DTO boundary. Handler execution is protected, and only the closed public error catalog can leave the coordinator; thrown text and stack details remain private. A `false` or `nil` result without a valid structured error is a resolution failure, not success.

## Compatibility tracing

The three official providers and the central coordinator request the sensitive `synex.tracing.write` capability. Core binds `qb`, `qbx`, and `esx` native calls to their exact provider resource. The coordinator is separately restricted to `InvokeAdapter`, `ResolveCatalog`, and `InvokeCatalog`; it cannot emit native-provider spans. `Tracing.run` accepts only `operation`, `traceId`, `compatProvider`, `consumer`, and `legacyApi`; the operation must be the exact `compat.<provider>.<legacyApi>` value and the API name comes from the caller-specific closed Core allowlist. The consumer must still be an active resource. Unknown fields, arbitrary API names, caller-class crossover, spoofed providers, stale owners, undeclared capabilities, and denied capabilities fail closed.

Supported facade reads, provider telemetry reads, native reads, mutations, callback registration, synchronous callback dispatch, and generic adapter/catalog operations run inside this boundary. Their existing authorization trace ID is propagated to native RPC and service options, so Core records child spans under the compatibility span. Callback dispatch tracing ends when the legacy handler returns; it does not keep an owner operation open while an asynchronous response is pending.

Retained trace projections add only the bounded provider, consumer-resource, and legacy-API labels. They never retain callback arguments, adapter/catalog payloads, money metadata, requests, responses, results, or arbitrary label maps, and the existing span-retention and child-list limits remain unchanged.

Generic adapter/catalog resolve and invoke use the coordinator's own fixed trace operations and the authorization trace ID created before handler execution. Explicitly unsupported calls have no successful authorization by definition and remain visible through bounded unsupported-usage telemetry rather than fabricating an admitted trace.

## Sensitive operations

- money is an integer-minor-unit native Accounts transfer/mint/burn with an exact funding or sink policy, action-specific native capability, reason, provenance, trace, and idempotency key; transfer additionally requires an exact counterparty. Only the reviewed provider executors receive mint/burn capability, while the empty policy and consumer catalogs deny every legacy mint/burn action by default;
- group/grade/primary mutation resolves only an existing active membership and grade through one exact catalog mapping, then calls the atomic policy-aware Groups service; duty mutation uses real Groups duty sessions, while membership/group/grade creation remains unavailable;
- metadata is closed-schema, non-sensitive, bounded, and CAS-versioned;
- QBX offline player state is a detached read-only projection; every offline mutation is explicitly rejected, and QB/ESX offline lookup remains unsupported;
- read-only QB/ESX permission projection requires explicit mappings and Core RBAC, while permission assignment, revocation, and administrative mutation remain unsupported;
- direct SQL compatibility, mutable authoritative PlayerData, and client-selected authority are unsupported.

## Bounds and privacy

Registries, warnings, telemetry series, projections, lifecycle fences, callbacks, pending responses, and diagnostic pages have hard limits. Adapter and catalog registrations are owner/epoch bound and are removed with their executable references when the owner stops. Executable catalog resolution additionally requires the profile's exact catalog revision and is exposed only through the selected official provider's server-only Resolve/Invoke boundary. Metrics and Control rows never include player IDs, character IDs, account IDs, transaction IDs, raw reasons, payloads, results, or catalog contents. Public errors use a closed catalog and do not expose SQL, stack traces, configuration, or credentials.

Run `npm run security` and `npm run test:compatibility` after changing any provider, facade, surface, mapping, or transport boundary.
