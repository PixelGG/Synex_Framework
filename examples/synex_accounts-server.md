# Server-only Accounts consumer example

> [!WARNING]
> `synex_accounts` is an Experimental Alpha. This example demonstrates the current server boundary; it is not production deployment or client-event code.

A consuming resource must declare the dependency, consumed contract, and required capability in its own `synex.resource.json`. The following fragment is documentation only:

```json
{
  "capabilities": {
    "request": ["synex.accounts.read"]
  },
  "contracts": {
    "provide": [],
    "consume": ["synex.accounts.get"]
  },
  "dependencies": {
    "required": [
      { "name": "synex_core", "version": ">=0.1.0" },
      { "name": "synex_accounts", "version": ">=0.1.0" }
    ],
    "optional": [],
    "development": []
  }
}
```

Resolve the account and authenticated character inside trusted server code, then invoke the server-local contract:

```lua
local function readAccount(accountId, characterId)
    local result, callError = exports.synex_core:Invoke(
        'synex.accounts.get',
        '1.0.0',
        {
            account_id = accountId,
            actor_kind = 'character',
            actor_ref = characterId,
        },
        { timeoutMs = 3000 }
    )

    if callError then
        print(('[example] Accounts read failed: %s'):format(callError.code))
        return nil, callError
    end

    return result, nil
end
```

Do not accept `accountId`, `characterId`, ownership, prices, amounts, currencies, or permissions from a client as authoritative. A network-facing gameplay resource must bind the current Core session, revalidate authority after every yield, apply rate limits, and decide which bounded fields may be returned to the client.

The raw Cfx boundary can represent a failed first return as `false, error`; always test the error slot. See the [Accounts reference](../docs/reference/accounts.md) and [Public API](../docs/api/README.md) for the current contract and caller rules.
