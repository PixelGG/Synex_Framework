# Developer CLI

The Synex CLI operates on repository files and explicitly configured operator adapters. It does not download or execute remote framework code, does not discover secrets from committed configuration, and does not imply a production certification.

From a source checkout, use:

```text
node --experimental-strip-types tools/cli/src/bin.ts <command>
```

After `npm run build`, the compiled entry point is `.build/tools/cli/src/bin.js`. Add `--root <repository>` when invoking it outside the repository root. Machine-readable commands accept `--json` where shown by `--help`.

## Build and contracts

```text
synex build
synex test
synex contract generate [--check] [--json]
synex contract check [--against <directory>] [--json]
synex validate [path] [--json]
```

Generation is deterministic and `--check` fails on generated drift. Contract comparison reports incompatible schema or version changes; it does not rewrite the compared tree.

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
synex doctor [path] [--bundle] [--output <file>] [--json]
synex security scan [path] [--json]
synex security fuzz [path] [--json]
synex certify <repository|resource|path> [--output <file>] [--json]
```

`doctor --bundle` writes a bounded redacted support artifact containing repository versions, static health/dependency/migration checks, safe configuration projections, and warnings. The static scanner and executable contract fuzzer produce review evidence; neither proves a resource secure. Certification reports `PASS`, `WARN`, or `FAIL` with concrete checks and hashes and makes no marketing score or production guarantee.

## Core production-beta evidence

```text
SYNEX_TEST_DATABASE_LIVE=1
SYNEX_TEST_DATABASE_URL=mysql://.../synex_test_<name>
npm run evidence:core-beta
```

This gate accepts only a clean Git revision and a disposable database named `synex_test_[a-z0-9_]+`. The first production-beta profile requires MariaDB; `mysql://` is the connector URL syntax and does not declare MySQL Server support. The artifact records the exact commit, the tracked `core/synex_core` tree hashes, bounded command timings and hashed output metadata for `check`, live-database tests, the security scan, repository certification, and the high-severity dependency audit. Raw command output and database credentials are not written. Evidence may be created only below the ignored `.temp/` or `artifacts/` roots.

Use `node --experimental-strip-types tools/core-beta-evidence.ts --help` for the optional repository-root and output-path arguments.

The artifact covers the single-instance MariaDB profile of `synex_core` only. Multi-instance/`kick_old`, MySQL Server, and all downstream resources—including `synex_entities`, `synex_accounts`, and `synex_groups`—are explicit out-of-scope items and do not block this profile. Downstream resources remain rework snapshots.

The artifact's manual fields are always `NOT_RUN` because this command does not launch FXServer or a FiveM client and does not execute the listed manual lifecycle gates. `NOT_RUN` describes the automated artifact's execution boundary; it must not be rewritten to mirror separate operator evidence. The final post-documentation `npm ci`, check, test, security, and certification run passed; server and client evidence remain separate. The automated artifact never asserts release readiness. Certification warnings are accepted only from the tool's explicit allowlist, while unknown or semantically different warning classes fail the gate.

## Disposable Core live test

```text
synex live-test prepare --probe <external-synex_core_probe-directory> [--output <.temp/live-test/directory>] [--json]
```

This command builds an ignored, deployment-shaped Core acceptance bundle without changing the tracked production capability policy. It accepts only a reviewed, server-only `synex_core_probe` outside the repository that requests the four exact Connection Gate and Saga test capabilities. The output contains `server-data/resources`, schemas, a credential-free startup configuration fragment, hashes, run-scoped KVP isolation metadata, and safeguard evidence. The KVP runtime protocol is two-phase: first PASS retains the exact run-scoped key and returns `restartRequired = true`; after restarting only the probe in the same Core process, second PASS requires a greater owner epoch, deletes the key, and returns `restartRequired = false`, `kvpCleaned = true`. Every FAIL path deletes the exact key. Use the bundle only with isolated infrastructure and remove it after the run. See [Testing](../testing.md#disposable-core-live-test-bundle) for the probe contract and runtime acceptance rules.

## Compatibility and upgrades

```text
synex compat scan [path] [--json]
synex upgrade-check [path] [--against <repository>] [--json]
synex migrate <qb|qbx|esx> --dry-run --source <file> --mapping <file>
```

Compatibility scanning identifies native, bridge, minor-change, and rewrite candidates without modifying resources. Upgrade checking compares manifests, Core/API ranges, contracts, migrations, capabilities, and deprecation evidence. The migration command is dry-run unless the explicit review/materialization/import flags described in [Legacy data migration](../compatibility/migration.md) are supplied.

## Benchmark

```text
synex benchmark [--iterations <count>] [--baseline <file>] [--output <file>] [--json]
```

This is a deterministic local headless microbenchmark for regression comparison. Its report is not an FXServer, OneSync, SQL, competitor, or production-performance claim.

## Managed reload

```text
synex dev reload <resource> [--adapter <plan|local|remote>] [--timeout <ms>] [--force] [--json]
```

The default `plan` adapter performs no external action. It resolves required dependents, blocks cycles and unresolved dependencies, then emits ordered `QUIESCE`, `DRAIN`, `SNAPSHOT`, `RELOAD`, `VALIDATE`, `RESTORE`, and `READY` stages. Without `--force`, every impacted resource must declare compatible state-snapshot support.

The `local` adapter executes only the absolute regular file named by `SYNEX_RELOAD_EXECUTABLE`, with a bounded JSON argument template from `SYNEX_RELOAD_ARGUMENTS_JSON`; no shell is used. The `remote` adapter requires `SYNEX_RELOAD_ENDPOINT` plus `SYNEX_RELOAD_TOKEN`, uses HTTPS except for loopback HTTP, refuses redirects/URL credentials, and bounds response size and timeout. Those adapters are operator-owned control integrations, not a built-in remote Synex control plane. A failed stage triggers one best-effort `ABORT` notification.

Runtime snapshot handoff remains bounded, in-memory, schema-versioned, same-Core only, and single-use. Durable state must be committed before an adapter acknowledges quiesce.
