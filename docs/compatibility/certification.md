# Compatibility certification

> [!WARNING]
> The current Bridge catalog has no profile and no certification artifact. Repository tests and source-pin checks do not replace exact-candidate MariaDB, FXServer, historical-facade/restart, mixed-provider, callback/event, third-party-flow, and real-client evidence. `synex_bridge` remains Experimental Alpha.

Certification is version-bound evidence, not a configuration label. A `CERTIFIED` result requires the exact profile, exact Synex provider version, exact reviewed target-framework API range, exact script version, complete required surfaces/adapters, every declared executable-catalog requirement, current hashes for every checked-in test artifact, and a passing certification evidence bundle. The Synex Core API range used by `synex_bridge` itself is a separate contract and is never used as the target-framework range.

Build the repository, execute the profile-bound flows, and then run the separate verifier:

```text
npm run build
node --experimental-strip-types tools/cli/src/bin.ts compat execute <profile-id> --output artifacts/compatibility/<profile-id>.execution.json
node --experimental-strip-types tools/cli/src/bin.ts compat certify <profile-id> --runtime-evidence path/to/runtime-evidence.json --execution-evidence artifacts/compatibility/<profile-id>.execution.json --output libraries/synex_bridge/compatibility/certifications/<profile-id>.json
```

`compat execute` runs only the tracked `tests/compatibility/*.test.ts` or `*.test.mjs` files already named by the profile's `evidence.tests`. The executable and arguments are fixed by the CLI; profile data cannot provide a shell command. Every flow has a 120-second limit and bounded captured output. A missing compiled TypeScript test, a skipped test, an unavailable dependency, or a partially skipped suite produces `SKIP`/`UNKNOWN`, never a pass. Execution evidence is written only to the derived, ignored `artifacts/compatibility/<profile-id>.execution.json` path. It does not start FXServer or a FiveM client.

`compat certify` remains a separate fail-closed verifier. It accepts closed-schema repository-local runtime and execution evidence and verifies exactly one matching certification record; authored/effective `CERTIFIED` status; exact profile, provider, provider version, reviewed target-framework range, and script version; runtime completeness and provider health; required adapters; every exact executed and runtime-reported tracked test path with `PASS` and its current SHA-256; and the tracked local review lock. `--output` must equal the profile's declared `certificationArtifact` path.

The emitted artifact has a closed schema. Its SHA-256 fingerprint binds the complete PASS check set, exact test set/hashes and tracked flags, source URLs, profile catalog (including catalog name/range/domain/revision requirements), provider surface catalog (including closed catalog-operation capability policy), consumer-authorization catalog, money-policy catalog, review lock, and certification-related schemas. The review lock separately binds the exact central compatibility-mapping catalog (`central.compatibility-mappings`), consumer catalog, and money-policy catalog bytes. At runtime, `synex_bridge` re-hashes every resource-local binding and recomputes the fingerprint before preserving `CERTIFIED`; each catalog operation additionally resolves the required live registration and exact revision. A non-empty or handwritten file, a FAIL/SKIP test, a missing tracked binding, a surface, mapping, consumer, or money-policy catalog drift, a stale live catalog revision, or a modified fingerprint cannot produce an admitted catalog call. Any missing or mismatched prerequisite returns `UNKNOWN`, a closed runtime error, or a non-zero CLI exit as appropriate.

Static source scanning answers what a consumer may use. Bounded runtime observation answers what an operator observed in a specific run. Neither can certify a script on its own. Operator-supplied runtime evidence is untrusted diagnostic input and cannot promote status.

The harness must keep these states separate:

```text
authored profile status
effective resolver status
static scan findings
runtime observations
certification result
deployment acceptance
```

If the proprietary resource or required native domain is unavailable in the test environment, the affected flow remains `UNKNOWN` or `PARTIAL`; it is never replaced with a fake pass. A complex dealership profile, for example, cannot be certified without its real player, Groups, Accounts, vehicle catalog/ownership, interaction, database, and financial flows.

Upstream documentation URLs and commit-pinned source fingerprints are checked in for the official QB, QBX, and ESX repositories. The lock detects unreviewed local surface-catalog, central mapping, consumer-authorization, money-policy, repository, branch, revision, source-set, byte-count, and SHA-256 drift. `targetFrameworkApiRange` remains `null` until a defensible upstream API-version boundary is reviewed; a Git commit is source evidence, not an invented semantic-version range.

`compat drift` is the deterministic offline review-lock check and has `networkAccess: false`, so upstream status remains `UNKNOWN`. `compat drift --online [--timeout <ms>]` is the explicit opt-in watcher: it reads only the catalog's allowlisted official `raw.githubusercontent.com` source URLs, caps each response at 256 KiB, permits a 500–30,000 ms timeout, and compares exact bytes and SHA-256 with the commit-pinned baseline. HTTP failures, redirects, timeouts, and oversized responses return `UNKNOWN`, never `PASS`; a mismatch returns `DRIFT`/`FAIL`. The standard CI gate stays offline, while the online workflow-dispatch input is disabled by default.

No profile ships in the current catalog, so the repository makes no certified third-party-script claim.

See the CLI reference for the currently available [compatibility commands](../reference/cli.md) and [testing](../testing.md) for repository gates.
