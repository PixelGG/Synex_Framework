# Lua and TypeScript SDKs

Generated SDK artifacts share one canonical contract source hash. `npm run generate` updates them; `npm run generate:check` fails when committed outputs drift.

> [!WARNING]
> The SDKs and generated consumer integrations are experimental surfaces outside `synex_core` Production-Beta certification. Accounts is a server-only Experimental Alpha, and its examples may change before a separate release decision.

## Lua SDK

The Lua SDK is server-side and calls the core exports under the immediate consumer resource identity. Load its generated registry before `synex.lua` in a resource manifest, then connect:

```lua
local client, connectError = SynexLuaSDK.connect('^1.0.0')
if not client then error(connectError.message) end

local snapshot, requestError = client:request('synex.accounts.get', {
    account_id = accountId,
    actor_kind = 'character',
    actor_ref = characterId
})
```

`request(name, ...)` selects the latest generated descriptor. `requestVersion(name, version, ...)` pins an exact descriptor. Both methods normalize a raw `Invoke` failure from Cfx's `false, error` transport form back to the SDK convention `nil, error`; callers should check `requestError`. Neither path bypasses runtime contract validation or capability policy.

This consumer SDK does not adapt callbacks registered by a provider. A provider callback crossing back into Core must return `false, error` on failure, or the provider must supply its own boundary adapter; the repository currently includes no provider-side adapter.

Source and usage notes live in [`packages/sdk-lua`](../../packages/sdk-lua/README.md).

## TypeScript SDK

The TypeScript package provides generated input/output/error types plus a small transport-agnostic `SynexClient`:

```ts
const client = new SynexClient(transport);
const snapshot = await client.request("synex.accounts.get", {
  account_id: accountId,
  actor_kind: "character",
  actor_ref: characterId,
});
```

The repository does not ship a browser, NUI, HTTP, or Cfx transport implementation for this client. The host must provide a `SynexTransport` whose `request(contract, version, input)` crosses an already authorized server-side boundary. Do not expose the transport directly to untrusted NUI code or treat generated types as runtime validation.

Version-specific calls use the generated `name@version` key. Current contracts are experimental even though their contract versions use semantic version identifiers.

## Generated outputs

```text
packages/contracts/generated/runtime/contracts.json
packages/contracts/generated/lua/contracts.lua
packages/contracts/generated/docs/contracts.md
packages/sdk-lua/generated/contracts.lua
packages/sdk-ts/src/generated/contracts.ts
core/synex_core/shared/generated_contracts.lua
```

Generated artifacts are deterministic: they contain a source hash and no timestamp or workstation path. Edit canonical `*.contracts.json` files, never these outputs.
