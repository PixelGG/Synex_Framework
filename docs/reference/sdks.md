# Lua and TypeScript SDKs

Generated SDK artifacts share one canonical contract source hash. `npm run generate` updates them; `npm run generate:check` fails when committed outputs drift.

## Lua SDK

The Lua SDK is server-side and calls the core exports under the immediate consumer resource identity. Load its generated registry before `synex.lua` in a resource manifest, then connect:

```lua
local client, connectError = SynexLuaSDK.connect('^1.0.0')
if not client then error(connectError.message) end

local snapshot, requestError = client:request('synex.accounts.get_snapshot', {
    account_id = accountId
})
```

`request(name, ...)` selects the latest generated descriptor. `requestVersion(name, version, ...)` pins an exact descriptor. Neither path bypasses runtime contract validation or capability policy.

Source and usage notes live in [`packages/sdk-lua`](../../packages/sdk-lua/README.md).

## TypeScript SDK

The TypeScript package provides generated input/output/error types plus a small transport-agnostic `SynexClient`:

```ts
const client = new SynexClient(transport);
const snapshot = await client.request("synex.accounts.get_snapshot", {
  account_id: accountId,
});
```

The repository does not ship a browser, NUI, HTTP, or Cfx transport implementation for this client. The host must provide a `SynexTransport` whose `request(contract, version, input)` crosses an already authorized server-side boundary. Do not expose the transport directly to untrusted NUI code or treat generated types as runtime validation.

Version-specific calls use the generated `name@version` key. Current contracts are experimental even though their contract versions use semantic `1.0.0` identifiers.

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
