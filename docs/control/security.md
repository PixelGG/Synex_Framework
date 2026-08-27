# Control security boundary

`synex_control` is a privileged diagnostics surface. NUI and client messages are untrusted even though every implemented operation is read-only.

## Request controls

- Real connected player source required.
- Base and route-specific ACE checks on every request.
- Closed root objects, fixed transport operations, and provider/view/input/search metadata validated by Core before projection.
- Request IDs, identifiers, cursors, filters, sort fields, strings, page sizes, and encoded request bytes are bounded.
- Weighted per-player server token bucket and bounded concurrent work.
- One exact provider namespace/operation resolved server-side; no NUI-selected Lua method, event, export, SQL, or resource name.
- Raw provider cursors remain on the server; the browser receives only player- and request-scope-bound opaque handles with a 120-second TTL.
- Responses use `TriggerClientEvent` only for the requesting source.
- Browser messages are accepted only from the current NUI origin, `nui-game-internal`, or the resource-specific `cfx-nui` origin, then pass the versioned response validator before store/render use.

## Sanitization

All Core, domain, search, audit, and provider output passes one sanitizer before NUI transport. It handles:

- nested secrets and composed keys such as `api_key`, `access_token`, `refresh_token`, `private_key`, credentials, passwords, connection strings, and webhooks;
- identifier masking unless the operator also has `synex.control.identifiers`;
- cyclic and over-deep tables;
- oversized arrays, maps, strings, and keys;
- callables, userdata, unsupported values, and non-finite numbers;
- a final encoded response ceiling of 32 KiB.

Provider messages, stack traces, SQL, query parameters, local paths, raw registries, and secret values are never public error details.

## Security findings history

The `security` view requires `synex.control.security` and merges two bounded read models:

- deterministic current findings for aggregated stale-session authority, slow hooks, and capability preflight;
- a newest-first, process-local Runtime history for capability denial, contract validation, rate-limit rejection, event authorization, and hook authorization; foreign-call denials use the applicable event/hook authorization category.

The first page reserves at least one Runtime slot when Runtime history is non-empty; numeric keyset continuation pages contain Runtime findings only. A page accepts at most 50 rows. The Runtime ring defaults to 512 entries and is hard-clamped to 32 through 2,048; retained, dropped, and retention-truncation metadata make overwrites explicit. A Core restart clears the ring.

Runtime projection is restricted to timestamp, category, severity, code, resource or scope, operation, and a bounded summary. The internal finding ID is used only as the server-side cursor and is not rendered as finding data. Payloads, details, trace/request/session/source identifiers, secrets, and cross-domain records are absent; `identifiersExposed`, `payloadsExposed`, and `crossDomainDataExposed` are all `false`. Stale sessions are grouped by safe state/reason with an occurrence count after a bounded scan of at most 512 active sessions; individual Session IDs are not returned.

If the Runtime diagnostics API is absent, invalid, or throws, only `runtimeHistory` and its coverage become `UNAVAILABLE`; deterministic findings, RBAC, metrics, and other Security-view data remain available. Fuzzing and static analysis are repository gates, so their Runtime coverage is explicitly `NOT_RUNTIME` / `REPOSITORY_TEST_GATE`.

## Support diagnostic bundle

The TypeScript diagnostic-bundle builder applies the same protection contract to the complete artifact body before hashing or writing it: secret-bearing key and recognizable credential-value redaction, identifier masking, depth 10, 2,048 entries globally, 512-byte strings, 96-byte keys, and explicit cycle/non-finite replacements. It normalizes unpaired surrogates to well-formed Unicode before applying the UTF-8 byte bounds. Symbol-keyed fields are omitted and counted as replacements; accessors become a safe marker without executing a getter. It is a separate implementation of the shared protection contract, not the Lua runtime sanitizer itself.

`createDiagnosticBundle` can receive an optional caller-supplied `runtimeEvidence` value. The CLI exposes that path as `doctor --bundle --runtime-evidence <file>` for a repository-contained operator JSON file; the option is invalid without `--bundle`. The imported value passes through the same full-body sanitizer. The command does not open Control or collect live FXServer evidence automatically; without supplied evidence the bundle states `UNAVAILABLE` with reason `RUNTIME_CONTROL_EVIDENCE_NOT_SUPPLIED`. Imported evidence is not independently verified, which prevents a static support artifact from being mistaken for a collected runtime snapshot.

## NUI lifecycle

The initial document contains an empty `#root`. While closed, `html`, `body`, and `#root` are transparent and non-interactive, the application surface is absent, no refresh timer runs, and Lua holds no NUI focus.

The browser must call `ready` before an authorized open can set focus. Close, access revocation, render failure, and resource stop clear pending state and call both `SetNuiFocusKeepInput(false)` and `SetNuiFocus(false, false)`. Browser values are rendered through DOM APIs and `textContent`, never provider HTML.

Resource start/stop notifications contain only a bounded resource/state invalidation hint. They clear cached data and cursor handles but grant no authority; every catalog or view refresh caused by that hint passes the normal server checks again.

## Read-only invariant

Control exposes no resource restart/stop, SQL console, entity spawn/delete, account posting/reconciliation/repair, outbox retry, group mutation, migration execution, player moderation, or configuration mutation. The provider operation named `simulate` is explanation-only. A future maintenance product requires a separate contract and threat model.
