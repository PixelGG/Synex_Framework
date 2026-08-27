# Compatibility profiles

A profile describes one reviewed third-party script/version against one exact Synex compatibility-provider version and a reviewed upstream target. It contains metadata only; proprietary source files must never be committed.

The strict schema in [`profiles.schema.json`](../../libraries/synex_bridge/compatibility/schemas/profiles.schema.json) requires:

- profile ID and profile schema version;
- script name and exact tested version, or `null` while evidence is unknown;
- provider, exact `providerVersion`, mode, authored status, and failure policy;
- a semantic `targetFrameworkApiRange` when the upstream publishes a defensible API version range, otherwise `null` plus the exact reviewed upstream repository and 40-character revision;
- optional vendor metadata, required domains, exports and events, classified direct-SQL assumptions, known limitations, and structured tested-flow status/environment requirements;
- `certificationArtifact` (omitted unless a CLI certificate is intended; required for authored `CERTIFIED`);
- required surfaces with accepted statuses;
- required adapters with a semantic version range, or `null` while that adapter version is deliberately unpinned;
- required executable catalogs with name, semantic-version range, owning domain, and exact positive revision;
- checked-in test paths and public source-evidence URLs.

For certification execution, every `evidence.tests` entry is one profile flow and must be a tracked `tests/compatibility/*.test.ts` or `*.test.mjs` Node test. Profile data never supplies an executable, argument, shell fragment, or environment value. TypeScript flows use their repository build output; unavailable builds and test-level skips remain `UNKNOWN`.

An enabled consumer in [`consumers.json`](../../libraries/synex_bridge/compatibility/consumers.json) must bind to a profile with the same provider and mode. Missing profiles, wrong providers, provider-version drift, a target range or exact upstream pin different to the reviewed surface catalog, unaccepted surface status, missing adapter versions, or a missing/domain-mismatched/version-mismatched/revision-stale catalog fail resolution. A surface can select only a catalog declared by that profile. The installed `synex_bridge_<provider>` resource metadata must match `providerVersion` exactly. When `script.testedVersion` is non-null, the consumer resource's declared `version` metadata must also match exactly. The Core API range requested by the central bridge is unrelated to these bindings.

Profiles also enforce closed companion-surface dependencies. Provider job, gang,
duty, money, group, and account update-event surfaces require that provider's
shared lifecycle surface. QB core-object filtering requires the QB core-object
surface. QB and ESX client callback invocation require both the matching client
player-data surface and server callback-registration surface. A profile that
omits one of these companions is rejected as incomplete before it can activate.
This prevents a callback-only capability from causing Accounts or Groups data to
be read for a full player projection. Client player-data alone remains valid: it
activates only the provider-local, consumer-allowlisted projection and does not
publish the provider's public load or unload event family.

## Status meaning

- `CERTIFIED`: exact provider version, semantic upstream target-framework range, and script version passed the certification harness and runtime artifact verifier with current checked-in evidence. Exact-commit-only targets remain at most `COMPATIBLE` until the certificate format supports that binding;
- `COMPATIBLE`: the bounded required interfaces were checked, without full deployment certification;
- `PARTIAL`: named core paths work but required surfaces, adapters, or executable catalogs remain incomplete;
- `UNSUPPORTED`: the reviewed integration cannot be admitted;
- `UNKNOWN`: evidence is insufficient.

Changing the tested script version requires a new reviewed profile/evidence match. At runtime, a declared resource-version mismatch fails closed; in the CLI certification harness, mismatched profile, provider, script, target-range, or test evidence returns `UNKNOWN`. Static scanning or directory presence cannot promote a profile.

No profile ships in the checked-in catalog, so no third-party script currently has a compatibility or certification claim.
