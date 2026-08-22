# Synex Lua SDK

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
