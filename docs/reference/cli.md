# Developer CLI

The Synex CLI operates on repository files and explicitly configured operator adapters. It does not download or execute remote framework code, does not discover secrets from committed configuration, and does not imply a production certification.

From a source checkout, use:

```text
node --experimental-strip-types tools/cli/src/bin.ts <command>
```

After `npm run build`, the compiled entry point is `.build/tools/cli/src/bin.js`. Add `--root <repository>` when invoking it outside the repository root. Machine-readable commands accept `--json` where shown by `--help`.

## FXServer Accounts operator commands

The runtime `synex` command is separate from the Node developer CLI above. The current Core implementation exposes these exact Accounts forms:

```text
synex doctor accounts
synex ledger
synex accounts status
synex accounts trace <transaction>
synex accounts inspect <account>
synex accounts outbox [limit]
synex accounts outbox-retry <event-uuid> <idempotency-uuid>
synex accounts reconcile <currency> <idempotency-uuid>
```

They execute only from source `0` (server console), are registered as restricted Cfx commands, validate at most four bounded arguments, and emit structured output. `outbox` defaults to 25 rows and accepts `1..50`; transaction and account inspectors require their public UUIDs.

Doctor, ledger/status, trace, inspect, and outbox are bounded reads through capability-declared Accounts service methods. `synex accounts reconcile` is intentionally mutating: it requires a currency and UUID idempotency key, invokes `synex.accounts.integrity.run`, and transactionally stores the reconciliation run, findings, Accounts audit, and outbox evidence. `synex accounts outbox-retry` is the second explicit mutation: it invokes the separately privileged `synex.accounts.outbox.retry` operation for one dead event, is idempotent per caller/key, and records durable retry evidence plus Core audit. Neither command edits balances, rewrites ledger history, freezes accounts, or creates/destroys supply. There is no NUI mutation button or automatic repair.

## FXServer Notify diagnostics

The runtime command also exposes three read-only forms for the Experimental Alpha Notify resource:

```text
synex doctor notify
synex notify status
synex notify doctor
```

They call the capability-gated `synex.notify@1` diagnostics surface and return bounded lifecycle, owner, action-token, health and finding aggregates. They never emit a notification, target a player, reveal notification text or action tokens, or provide a production spam simulator. The commands report `UNAVAILABLE` while `synex_notify` is stopped and `DEGRADED` when its optional `synex_ui` transport is unavailable.

The runtime command exposes bounded read-only Interact diagnostics:

```text
synex doctor interact
synex interact status
synex interact doctor
synex interact inspect <namespaced-key>
synex interact trace <trace-id>
```

`status` returns aggregate registry/runtime pressure, `doctor` returns bounded findings, and `inspect` resolves one exact Smart Object or Action Graph without player, target, adapter request or domain payloads. These commands do not issue a lease, run a graph, reserve a slot or mutate gameplay state. They report the optional resource state through the same fail-closed service boundary used by other domain commands.

## FXServer Security diagnostics

The runtime command exposes bounded, read-only Security operations:

```text
synex doctor security
synex security status
synex security doctor
synex security detectors
synex security case <case-id>
```

They call the capability-gated `synex.security@1` service. Output is limited to
health, detector state, redacted findings, case summaries, bounded timelines,
and enforcement provenance. No command applies a restriction, kick, or ban, and
no command exposes unrestricted client telemetry. The commands report
`UNAVAILABLE` while the Experimental Alpha resource is stopped.

## Build and contracts

```text
synex build
synex test
synex contract generate [--check] [--json]
synex contract check [--against <directory>] [--json]
synex validate [path] [--json]
```

Generation is deterministic and `--check` fails on generated drift. Contract comparison reports incompatible schema or version changes; it does not rewrite the compared tree.

## World bundle tooling

```text
synex world validate [--json]
synex world doctor [--json]
synex doctor world [--json]
synex world bundles [--json]
synex world inspect <namespaced-key> [--json]
synex world locate <x> <y> <z> [--json]
synex world graph <namespaced-key> [--json]
synex world overlaps [--json]
```

These commands load every declared `worldBundles` file from repository resource manifests and validate the closed schema, owner namespaces, references, parent/dependency cycles and supported geometry. `inspect` and `graph` are exact-key reads. `locate` reports statically containing/nearby definitions at bounded coordinates. `overlaps` is a capped axis-aligned broad-phase report, not proof of a semantic conflict.

The offline doctor always keeps runtime status `UNKNOWN` unless static validation already fails. It cannot verify Cfx resource state, client IPL/interior activation, DoorSystem entities, routing buckets or live presence. See the [World development guide](../world/development.md).

## Inspect and create

```text
synex inspect [resource] <path-or-name> [--json]
synex inspect graph [--json]
synex create resource <synex_name> [--path <parent>] [--json]
synex permissions [path] [--json]
```

The graph includes required/optional dependencies and service relationships, unresolved requirements, cycles, and unused contract/service declarations. `permissions` compares requested, operator-granted, denied, statically used, undeclared, and unused capabilities. Creation is confined to the selected repository path and refuses an existing target.

## Diagnose and certify

```text
synex doctor [path] [--bundle] [--runtime-evidence <file>] [--output <file>] [--json]
synex security scan [path] [--json]
synex security fuzz [path] [--json]
synex certify <repository|resource|path> [--output <file>] [--json]
```

`doctor --bundle` writes a bounded redacted support artifact containing repository versions, static health/dependency/migration checks, safe configuration projections, and warnings. The complete artifact body is sanitized before it is hashed or written. The TypeScript sanitizer implements the same protection contract as Control's Lua sanitizer through secret-key and recognizable secret-value redaction, identifier masking, depth 10, a global 2,048-entry budget, 512-byte strings, 96-byte keys, and explicit cycle/non-finite replacements. It normalizes unpaired surrogates to well-formed Unicode before applying the UTF-8 byte bounds. Symbol-keyed fields are omitted and counted as replacements; accessors become a safe marker without executing a getter. It remains a separate implementation.

`doctor --bundle --runtime-evidence <file>` imports a repository-contained operator JSON file into the diagnostics field. The option is rejected without `--bundle`, and the imported value is sanitized with the complete artifact body. The CLI does not open Control or collect a live provider snapshot by itself; without the option, diagnostics explicitly report `UNAVAILABLE` with reason `RUNTIME_CONTROL_EVIDENCE_NOT_SUPPLIED`. Imported data remains operator-supplied evidence, not independent runtime certification. Doctor and certification also inspect `controlProvider` declarations for duplicate namespaces, operation/view mismatches, missing `synex.control.provider.register`, and an invalid dependency from a provider domain to `synex_control`. Those checks do not invoke a provider or validate runtime timeout, restart, redaction, output-bound or NUI behavior. The static scanner and executable contract fuzzer produce review evidence; neither proves a resource secure. Certification reports `PASS`, `WARN`, or `FAIL` with concrete checks and hashes and makes no marketing score or production guarantee.

## Core production-beta evidence

```text
SYNEX_TEST_DATABASE_LIVE=1
SYNEX_TEST_DATABASE_URL=mysql://.../synex_test_<name>
npm run evidence:core-beta
```

This gate accepts only a clean Git revision and a disposable database named `synex_test_[a-z0-9_]+`. The first production-beta profile requires MariaDB; `mysql://` is the connector URL syntax and does not declare MySQL Server support. The artifact records the exact commit, the tracked `core/synex_core` tree hashes, bounded command timings and hashed output metadata for `check`, live-database tests, the security scan, repository certification, and the high-severity dependency audit. Raw command output and database credentials are not written. Evidence may be created only below the ignored `.temp/` or `artifacts/` roots.

Use `node --experimental-strip-types tools/core-beta-evidence.ts --help` for the optional repository-root and output-path arguments.

The artifact covers the single-instance MariaDB profile of `synex_core` only. Multi-instance/`kick_old`, MySQL Server, and all downstream resources—including the Experimental Alpha Groups and server-only Accounts engines—are explicit out-of-scope items and do not block this profile. Every downstream resource needs its own release decision; the Core evidence runner is not Accounts acceptance.

The artifact's manual fields are always `NOT_RUN` because this command does not launch FXServer or a FiveM client and does not execute the listed manual lifecycle gates. `NOT_RUN` describes the automated artifact's execution boundary; it must not be rewritten to mirror separate operator evidence. The final post-documentation `npm ci`, check, test, security, and certification run passed; server and client evidence remain separate. The automated artifact never asserts release readiness. Certification warnings are accepted only from the tool's explicit allowlist, while unknown or semantically different warning classes fail the gate.

## Disposable Core live test

```text
synex live-test prepare --probe <external-synex_core_probe-directory> [--output <.temp/live-test/directory>] [--json]
```

This command builds an ignored, deployment-shaped Core acceptance bundle without changing the tracked production capability policy. It accepts only a reviewed, server-only `synex_core_probe` outside the repository that requests the four exact Connection Gate and Saga test capabilities. The output contains `server-data/resources`, schemas, a credential-free startup configuration fragment, hashes, run-scoped KVP isolation metadata, and safeguard evidence. The KVP runtime protocol is two-phase: first PASS retains the exact run-scoped key and returns `restartRequired = true`; after restarting only the probe in the same Core process, second PASS requires a greater owner epoch, deletes the key, and returns `restartRequired = false`, `kvpCleaned = true`. Every FAIL path deletes the exact key. Use the bundle only with isolated infrastructure and remove it after the run. See [Testing](../testing.md#disposable-core-live-test-bundle) for the probe contract and runtime acceptance rules.

## Compatibility and upgrades

```text
synex compat status [--json]
synex compat matrix [--json]
synex compat scan [path] [--json]
synex compat explain [path] [--json]
synex compat profile <profile-id> [--json]
synex compat adapters [--json]
synex compat observe [path] [--runtime-evidence <file>] [--json]
synex compat doctor [--runtime-evidence <file>] [--json]
synex compat execute <profile-id> [--output artifacts/compatibility/<profile-id>.execution.json] [--json]
synex compat certify <profile-id> --runtime-evidence <file> --execution-evidence <file> --output <declared-artifact> [--json]
synex compat drift [--online] [--timeout <ms>] [--json]
synex upgrade-check [path] [--against <repository>] [--json]
synex migrate <qb|qbx|esx> --dry-run --source <file> --mapping <file>
```

`compat status` summarizes the checked-in provider surfaces, profiles, consumers, money policies, and mappings. `matrix` renders their deterministic status table. The current catalog has no profiles, enabled consumers, group mappings, or money policies; all surfaces are `PARTIAL` or `UNSUPPORTED`. Three bounded `hunger` metadata definitions and six cash/bank account aliases are present, but none authorizes a money write.

`scan` identifies framework signatures, catalog surface candidates, domain dependencies, and direct legacy-table SQL in bounded, non-symlink Lua, JavaScript, TypeScript, and `fxmanifest.lua` files without modifying them. Ordinary comments are removed before matching. `explain` resolves scan results against the catalog, `profile` reports one exact script/profile definition, and `adapters` shows required adapter evidence. Static findings are migration aids, not proof that a resource is compatible.

`compat observe` combines a static scan with optional runtime evidence while keeping both sources separate, and it can never return `CERTIFIED`. Without evidence it returns `UNKNOWN` unless the static scan or catalog doctor already proves the target `UNSUPPORTED`. `compat doctor` reports invalid, missing, or ambiguous account/group/grade mappings, provider- and entity-scoped legacy-ID collisions, active money-policy ambiguity or broken consumer/account bindings, profile-selected money surfaces with no active policy, conflicting providers, missing adapters, profile drift, and invalid certification claims. With complete runtime evidence it also checks expected/duplicate providers, resource identity, state/health, required capability grants, stale consumer bindings and telemetry, optional callback cleanup counters, historical-facade conflicts, exact provider/profile versions, telemetry truncation, terminal-counter bounds, and sampled unsupported/deprecated rates. Checks that need unavailable runtime or callback evidence are emitted as `UNKNOWN`/deferred rather than silently passing.

The runtime-evidence file is bounded to 1 MiB, must be a non-symlink regular JSON file inside the repository, and must satisfy the closed [`runtime-evidence.schema.json`](../../libraries/synex_bridge/compatibility/schemas/runtime-evidence.schema.json). The developer CLI does not query process-local provider usage or Core metric histograms; the file remains operator-supplied evidence. Rate checks require a complete, untruncated row with at least 20 calls and warn at 5% unsupported or 25% deprecated calls. Callback cleanup can be evaluated only when a provider supplies pending/registration counts and both declared capacities.

`compat execute` runs only tracked `tests/compatibility/*.test.ts` or `*.test.mjs` files named by the exact profile. The CLI fixes the Node executable and arguments, applies a 120-second limit per file, bounds captured output, and never evaluates a command from profile data. TypeScript flows require the matching `.build` output from `npm run build`. Missing environments, skipped tests, and partial suites remain `SKIP`/`UNKNOWN`; the evidence artifact uses the fixed ignored `artifacts/compatibility/<profile-id>.execution.json` path.

`compat certify` remains a separate fail-closed verifier. It emits `CERTIFIED` only when one authored/effective `CERTIFIED` profile, one closed execution artifact, and one runtime-evidence candidate match the exact provider version, profile version, separately reviewed target-framework API range, script version, required adapters, complete error-free runtime evidence, and exact tracked test set with current SHA-256 and `PASS`, while the tracked local review lock also passes. `--output` must match the profile's declared `certificationArtifact`. The resulting closed artifact binds those facts plus the profile, surface, consumer-authorization, money-policy, review-lock, and schema files in a SHA-256 fingerprint that the runtime recomputes; a merely non-empty file is never sufficient. Neither command starts or inspects FXServer. Offline `compat drift` validates the local catalogs and commit/source pins without network access and therefore reports upstream `UNKNOWN`. `--online` explicitly compares bounded official main-branch sources with those pins; network failures remain `UNKNOWN`, mismatches fail, and a match does not certify a surface or invent `targetFrameworkApiRange`.

Upgrade checking compares manifests, Core/API ranges, contracts, migrations, capabilities, and deprecation evidence. The migration command is dry-run unless the explicit review/materialization/import flags described in [Legacy data migration](../compatibility/migration.md) are supplied. See the [compatibility boundary](../compatibility/README.md) and generated [matrix](../compatibility/matrix.md) before enabling any bridge resource.

## Benchmark

```text
synex benchmark [--iterations <count>] [--baseline <file>] [--output <file>] [--json]
```

This is a deterministic local headless microbenchmark for regression comparison. The Groups measurements execute the actual Lua organization-read, membership-read, effective-capability, online-member index, on-duty index, and stored-policy paths. Accounts covers balance, available-balance, access-check, transfer, multi-leg posting, hold creation/capture, and reconciliation. Entities covers registry, binding, logical-owner, spatial, spawn-validation, state, and bucket paths. World executes its actual spatial-index, coherent-context, registry and access modules against a fixed fixture of 50,000 Anchors, 10,000 Zones, 5,000 Doors and 1,000 Locations. Its paths are `queryAt`, `queryNearby` at 10 m and 100 m, Context resolution, Anchor resolution, Door resolution and Access; requested iterations are capped at 5,000 for those seven paths. Bridge covers bounded compatibility projection/callback DTO copies, indexed account-mapping resolution, consumer/profile/surface/adapter resolution, and telemetry aggregation. All run inside an embedded Wasmoon VM with deterministic in-memory fixtures or adapters. They exclude MariaDB I/O and locking, FXServer/Cfx networking, FiveM natives, OneSync scope/replication and scheduling, workers, client rendering, external framework runtimes, and production concurrency. The report is therefore not a server-capacity, competitor, compatibility-certification, concurrency, or production-performance claim.

## Managed reload

```text
synex dev reload <resource> [--adapter <plan|local|remote>] [--timeout <ms>] [--force] [--json]
```

The default `plan` adapter performs no external action. It resolves required dependents, blocks cycles and unresolved dependencies, then emits ordered `QUIESCE`, `DRAIN`, `SNAPSHOT`, `RELOAD`, `VALIDATE`, `RESTORE`, and `READY` stages. Without `--force`, every impacted resource must declare compatible state-snapshot support.

The `local` adapter executes only the absolute regular file named by `SYNEX_RELOAD_EXECUTABLE`, with a bounded JSON argument template from `SYNEX_RELOAD_ARGUMENTS_JSON`; no shell is used. The `remote` adapter requires `SYNEX_RELOAD_ENDPOINT` plus `SYNEX_RELOAD_TOKEN`, uses HTTPS except for loopback HTTP, refuses redirects/URL credentials, and bounds response size and timeout. Those adapters are operator-owned control integrations, not a built-in remote Synex control plane. A failed stage triggers one best-effort `ABORT` notification.

Runtime snapshot handoff remains bounded, in-memory, schema-versioned, same-Core only, and single-use. Durable state must be committed before an adapter acknowledges quiesce.
