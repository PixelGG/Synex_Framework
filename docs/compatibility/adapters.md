# Domain adapters and catalogs

The compatibility kernel contains two bounded extension registries:

- a catalog registry for reviewed Jobs, Gangs, Items, Vehicles, Locations, or similar read models owned by their native domain;
- a domain adapter registry for operations such as inventory, interaction, banking UI, vehicles, or notifications.

The bridge does not implement those domains itself. A registration declares owner, owner epoch, semantic version, provider scope, domain, status, and a closed list of operations. Catalogs additionally declare an authority (`domain` or `compatibility/static`) and a positive revision. Every declared operation must have exactly one callable implementation; unknown handlers and partial implementations are rejected. The closed interface vocabulary contains `identity`, `accounts`, `groups`, `metadata`, `inventory`, `vehicles`, `interaction`, `notifications`, `ui`, `banking`, and `provider`. The last six are extension interfaces only; their presence does not claim that an implementation or catalog exists.

Registrations are bounded globally, per owner, and by owner count. A different owner cannot replace an existing major-version slot. Resource stop removes definitions and executable references for that exact epoch.

Consumers resolve an adapter only when:

1. the profile declares the adapter and accepted version range;
2. the selected surface references the same adapter name;
3. a registered implementation with status `CERTIFIED`, `COMPATIBLE`, or `PARTIAL` satisfies the requested provider and version range;
4. the requested operation belongs to its closed operation set, resolved through the selected implementation's major version.

Otherwise the request returns `COMPAT_ADAPTER_MISSING`. No empty inventory, fake vehicle catalog, or no-op interaction is presented as a successful native domain.

The checked-in repository registers no compatibility domain adapter or executable catalog by default. In particular, the bridge never synthesizes Jobs, Gangs, Items, Vehicles, or Locations rows when their owning domain has not registered a reviewed catalog.

## Generic server invocation

An enabled server consumer calls its selected official provider, never the kernel registry directly:

```lua
local result, invokeError = exports.synex_bridge_qb:InvokeCompatibilityAdapter({
    surface = 'qb.inventory.item_lookup',
    operation = 'item.get',
    payload = { item = 'water' },
})
```

The example describes the request shape only. That surface and adapter are not present in the checked-in catalog, so the repository's default configuration rejects it.

The request is a closed object containing exactly `surface`, `operation`, and `payload`. A consumer cannot submit a capability list. The resolver selects the consumer, provider, profile, surface, adapter version, and operation. The selected surface's `requiredCapability` and `adapterOperations[].nativeCapabilities` are the complete authoritative policy; the coordinator checks the compatibility capability and every native capability for the immediate consumer before invoking the handler.

`synex_bridge_qb`, `synex_bridge_qbx`, and `synex_bridge_esx` each expose `InvokeCompatibilityAdapter(request)`. Their `InvokeCompatibilityAdapterForConsumer(consumer, request)` variants exist only for the corresponding repository-owned historical-name facade, whose immediate caller is authenticated before forwarding. That facade is privileged trusted-computing-base code because the provider can authenticate the facade but cannot independently recover the facade's original caller; deploy only the exact reviewed facade tree described in the [security boundary](security.md). No client network event is added for domain-adapter invocation.

Handlers receive detached `(context, payload)` objects. Context contains only schema version, trace, provider/resource, consumer, resolved profile, surface, adapter identity, and operation. Payload and successful result must be bounded canonical object DTOs. Metatables, callable values, cycles, sparse/mixed containers, non-finite numbers, excessive depth/entries/bytes, and unknown request fields are rejected. Handler exceptions and malformed `false`/`nil` results become closed public errors; private handler text and stack traces are not returned.

Provider usage records the consumer, resolved operation, terminal outcome, and latency, and emits the same bounded Core compatibility metrics used by the legacy facades. Consumer stop removes its process-local usage rows. Adapter owner stop removes the exact owner/epoch registrations and callable references, so a request fails with `COMPAT_ADAPTER_MISSING` until the owner registers again.

## Catalog execution boundary

Executable catalogs use a separate registry, resolver, telemetry, and Control path. The invoking owner registers an exact operation map through `RegisterCompatibilityCatalog` only after Core grants that resource `synex.compat.catalog.register`; the default operator policy grants this capability to no resource. A profile must bind the catalog name, semantic-version range, domain, and exact positive revision; its selected surface must reference that same catalog and declare a closed `catalogOperations[].nativeCapabilities` policy. Resolution rejects an absent provider match, domain mismatch, a catalog status not admitted by the consumer mode, version mismatch, stale revision, undeclared operation, or ambiguous profile binding. In particular, `strict` never admits a `PARTIAL` catalog even when the profile and surface themselves are otherwise compatible.

Each official provider exposes both server-only operations:

- `ResolveCompatibilityCatalog({ surface, operation })` returns detached catalog/profile/surface metadata only;
- `InvokeCompatibilityCatalog({ surface, operation, payload })` invokes the resolved handler with a detached bounded object payload.

The corresponding `*ForConsumer` forms are restricted to the repository-owned historical-name facade and authenticate that immediate facade caller before forwarding its observed consumer. A direct consumer cannot supply another resource name. Neither request accepts catalog identity, version, revision, authority, provider, or capability fields; all of them come from the enabled consumer/profile/surface and live registry. This makes the profile's exact revision the invocation fence instead of trusting a caller-selected revision.

Both the compatibility capability and every catalog-operation native capability are checked for the consumer before the handler runs. Resolve performs the same checks as Invoke, so it cannot be used to enumerate unauthorized catalog metadata. Payloads and results are bounded canonical object DTOs; exceptions and private handler errors are reduced to the closed public error catalog. No client network endpoint is added.

After authorization, adapter execution and catalog resolve/invoke run inside the coordinator's caller-restricted Core tracing boundary with the same trace ID. The retained span has only the closed coordinator operation plus provider, consumer-resource, and API labels; handler context, payload, catalog metadata, and result values are not retained.

A live replacement in the same catalog major-version slot must increase its revision. The old profile revision then fails with `COMPAT_VERSION_CONFLICT` until the reviewed profile is updated. Catalog-owner stop removes its definition and executable references; consumer stop removes that consumer's catalog-resolution telemetry. The read-only `catalog_usage` Control view reports only bounded provider/consumer/action counts, terminal outcomes, latency, truncation, and the number of registered runtime catalogs. If its owner/series bound drops evidence, `evidenceTruncated` remains true for the process lifetime instead of presenting an incomplete snapshot as complete. It never reports catalog payloads, result values, trace IDs, player identifiers, or private errors.
