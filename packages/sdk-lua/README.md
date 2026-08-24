# Synex Lua SDK

> [!WARNING]
> This SDK is an experimental consumer surface outside the `synex_core` Production-Beta certification boundary. The account call below targets the current `synex_accounts` rework snapshot and is not a supported deployment example.

The Lua SDK is a server-side, generated-contract client for Synex resources.
Load `generated/contracts.lua` before `synex.lua`, then bind the SDK from the
calling resource. The underlying `synex_core` export captures that immediate
resource as the security principal.

```lua
local client, err = SynexLuaSDK.connect('^1.0.0')
if not client then error(err.message) end

local snapshot, requestError = client:request('synex.accounts.get_snapshot', {
    account_id = accountId
})
```

`request` selects the latest generated version for a contract name.
`requestVersion` pins an exact `name@version` descriptor. Generated metadata
does not bypass runtime schema validation or capability checks.

Both request methods normalize the raw Cfx `Invoke` failure tuple
`false, error` back to `nil, error`; use the second return value as the error
signal. This consumer SDK does not adapt provider callbacks. A callback that
crosses back into Core must return `false, error` on failure, or use a separate
provider-side adapter; no such adapter is shipped here.
