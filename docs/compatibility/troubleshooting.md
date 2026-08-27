# Compatibility troubleshooting

Start with repository-local diagnostics:

```text
node --experimental-strip-types tools/cli/src/bin.ts compat status
node --experimental-strip-types tools/cli/src/bin.ts compat doctor
node --experimental-strip-types tools/cli/src/bin.ts compat explain path/to/consumer
node --experimental-strip-types tools/cli/src/bin.ts compat observe path/to/consumer --runtime-evidence path/to/evidence.json
node --experimental-strip-types tools/cli/src/bin.ts compat drift
```

The offline command is the normal deterministic gate. Use `compat drift --online --timeout 10000` only when network observation is intended. `UPSTREAM_SOURCE_DRIFT` means a watched official source differs from its reviewed commit pin; `UPSTREAM_SOURCE_UNKNOWN` means the bounded request could not establish a result and must not be treated as a pass.

Use `--json` when the output is consumed by automation. The CLI does not connect to FXServer unless a future command explicitly says so; an operator evidence file is bounded diagnostic input, not trusted certification.

## Common failures

| Code | Meaning | Check |
| --- | --- | --- |
| `COMPAT_CONSUMER_DENIED` | Consumer is absent, disabled, mismatched, or unauthenticated | `consumers.json`, immediate caller, facade path |
| `COMPAT_PROVIDER_DISABLED` | Provider or consumer epoch is disabled | provider selection, failure policy, resource state |
| `COMPAT_PROFILE_INCOMPLETE` | Profile/version/evidence/requirements cannot admit the operation | profile script version, API range, required surfaces/adapters/catalogs |
| `COMPAT_API_UNSUPPORTED` | Surface is not in the accepted profile subset | generated matrix and provider page |
| `COMPAT_API_DEPRECATED` | `strict` rejected a deprecated surface | use native Synex or a reviewed non-strict migration profile |
| `COMPAT_MAPPING_MISSING` | Required account/group/identity mapping is absent | mapping registry and exact provider/type/key |
| `COMPAT_MAPPING_AMBIGUOUS` | More than one reviewed mapping/account/primary candidate matches | remove duplicates; never rely on ordering |
| `COMPAT_ADAPTER_MISSING` | Required native domain adapter/version is unavailable | profile range, adapter registration, resource health |
| `COMPAT_CATALOG_UNAVAILABLE` | Required executable catalog/operation is absent or stopped | profile catalog name/domain/range/revision, registration owner, resource health |
| `COMPAT_VERSION_CONFLICT` | A live executable catalog revision differs from the exact profile fence | review and update the profile revision; do not bypass the fence |
| `COMPAT_MONEY_POLICY_DENIED` | No exact active transfer, mint, or burn policy matches the provider, consumer, alias, direction, and reason | `money-policies.json`; account aliases alone never authorize a write |
| `COMPAT_PROJECTION_UNAVAILABLE` | A complete bounded player/account/group projection cannot be proven | active session, domain availability, event-invalidation binding, truncation, all active membership mappings |
| `COMPAT_OFFLINE_MUTATION_UNSUPPORTED` | A caller tried to mutate the detached QBX offline read model | resolve the character online and use an authorized mapped online operation; do not retry against the offline facade |
| `COMPAT_DTO_LIMIT` | A request or callback payload exceeded a central bound | depth, entries, strings, argument count, and encoded bytes |
| `COMPAT_FRAMEWORK_CONFLICT` | A real upstream resource occupies a historical facade name or the facade marker is not the exact expected value | started resources, selected facade tree, and facade marker |
| `COMPAT_STALE_SESSION` | Async work belongs to an old session, source generation, or character selection | reconnect or reselect the character and find the delayed caller retaining stale state |
| `COMPAT_CALLBACK_TIMEOUT` | Registered handler did not complete in the bounded window | handler ownership, provider health, callback pressure |

## Doctor evidence checks

The structured `checks` array separates a proven pass or finding from unavailable evidence. Account/group coverage becomes actionable only for an enabled consumer or expected runtime provider whose catalog exposes the related surface. Identity collision checks are scoped by provider and entity kind; the CLI does not claim to inspect persistent identity rows.

Complete runtime evidence can prove stale consumer bindings and telemetry. Callback cleanup additionally requires pending/registration counters and both capacities from each provider; otherwise `runtime.callback-cleanup` remains `UNKNOWN`. Unsupported/deprecated-rate checks require an untruncated sample of at least 20 calls and warn at 5% unsupported or 25% deprecated calls. These thresholds identify migration pressure and do not certify a provider or consumer.

| Doctor code | Meaning | Check |
| --- | --- | --- |
| `ACCOUNT_MAPPING_MISSING`, `GROUP_MAPPING_MISSING` | A deployed provider exposes the domain but has no enabled mapping | provider surfaces, enabled consumers/expected providers, reviewed mapping catalog |
| `GROUP_GRADE_MAPPING_MISSING`, `GROUP_GRADE_MAPPING_INVALID`, `GROUP_GRADE_MAPPING_AMBIGUOUS` | A group grade map is absent, malformed, or not one-to-one | every legacy grade and native grade key must be unique |
| `LEGACY_ID_COLLISION`, `LEGACY_ID_NATIVE_COLLISION` | Static provider/entity-scoped identity mappings are not one-to-one | reviewed identity entries; persistent rows require separate runtime/database evidence |
| `RUNTIME_STALE_CONSUMER_BINDING`, `RUNTIME_STALE_CONSUMER_TELEMETRY` | Runtime state remains for a consumer that is not actively configured/bound | complete provider consumer and telemetry snapshot |
| `RUNTIME_STALE_CALLBACK_PENDING`, `RUNTIME_STALE_CALLBACK_REGISTRATION` | Callback work remains without an active provider/consumer binding | all four callback health counters and consumer bindings |
| `RUNTIME_UNSUPPORTED_RATE_HIGH`, `RUNTIME_DEPRECATED_RATE_HIGH` | A bounded telemetry sample exceeded an operational migration threshold | complete, untruncated row and minimum sample size |
| `RUNTIME_FRAMEWORK_RESOURCE_CONFLICT` | A historical facade conflicts with a real framework resource | exact provider conflict evidence |
| `RUNTIME_PROVIDER_VERSION_MISMATCH`, `RUNTIME_PROFILE_VERSION_MISMATCH`, `RUNTIME_PROFILE_BINDING_MISMATCH` | Runtime and checked-in provider/profile bindings differ | exact provider, profile, and target API versions |
| `PROFILE_CATALOG_MISSING` | A required surface selects a catalog not bound by its profile | profile `requiredCatalogs` and the selected surface |

## Default installation behavior

The repository intentionally ships with no enabled consumer, no profile, no group mapping, no money policy, no domain adapter, and no executable catalog. A denial in this state is expected fail-closed behavior, not proof that the provider failed to start. The checked-in bounded metadata mappings are definitions only and do not authorize a consumer.

Provider or consumer restart can legitimately refresh the provider-local client projection without another public player-loaded event. If public lifecycle delivery remains suspended, verify that both the provider and at least one configured lifecycle consumer are `starting` or `started` and that the consumer passes the lifecycle profile and capability gates. In mixed QB/QBX mode, QB receives the shared QBCore family only while its path is eligible; otherwise an eligible QBX path is the fallback.

If lifecycle load/unload works but client `GetPlayerData`, callbacks, or one update-event family does not, inspect that exact catalog surface rather than broadening the lifecycle grant. Client player data, client callback invocation, and each job, gang/group, duty, money, or account update family are independently resolved. Client allowlists are only local compatibility API admission and must not be treated as a confidentiality or server-authorization mechanism. Do not work around these fences by broadcasting a callable facade or by marking an unrelated resource as a historical facade.

## Real acceptance

Before enabling a consumer, test the exact script version on an isolated FXServer with the actual provider/facade layout, native domains, database, join/reconnect lifecycle, callback traffic, and required gameplay flow. Keep the result `UNKNOWN` or `PARTIAL` until that evidence exists.
