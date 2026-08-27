# Synex Control overview

> [!WARNING]
> `synex_control` is Development / Experimental Alpha. Its implementation and headless gates do not replace the pending FXServer/CEF/OneSync acceptance of the exact candidate.

`synex_control` is the optional, read-only operations and diagnostics surface for Synex. It discovers bounded diagnostic providers through `synex_core`, requests only the active view, sanitizes the result, and sends it only to the requesting operator.

It is deliberately not an admin or maintenance console. It cannot restart resources, execute SQL, mutate groups, move money, repair a ledger, spawn or delete entities, run migrations, or alter player state.

## Runtime boundary

```text
synex_core ControlProviders registry
            ^
            | owner/epoch-bound read-only registration
      +-----+---------+----------+---------------+
      |               |          |               |
   groups          accounts   entities   compatibility/bridge
      +---------------+----------+---------------+
                      |
              synex_control + self diagnostics
                      |
            sanitized lazy read-only NUI
```

- Domain and bridge providers depend on Core, never on Control; Control registers only its own process-local health provider.
- Control requires Core but remains non-critical and optional.
- Control never reads a domain table directly or stores copies of domain data.
- A stopped, timed-out, restarted, or unhealthy provider is isolated as unavailable; it must not take the rest of the panel down.
- `synex_bridge` can register the optional `compatibility` provider without making the bridge depend on Control.
- Missing telemetry is rendered as unavailable. No sample metrics, traces, charts, or health claims are generated.

## Opening the panel

Core and Control must be started in that order. The player principal needs the base ACE:

```cfg
ensure synex_core
ensure synex_control

add_ace group.admin synex.control.view allow
```

An authorized in-game operator opens the panel with:

```text
/synex-control
```

Console execution does not open a client UI. The browser must complete its ready handshake before Lua grants NUI focus.

## Read path

1. The server authorizes the command and sends a targeted open signal.
2. The ready browser requests the bounded provider catalog and compact `overview` independently.
3. The catalog supplies authorized navigation metadata; overview samples only compact summaries for at most 12 providers.
4. Selecting a view sends a correlated `section`, `page`, `inspect`, or `search` request.
5. Core invokes one exact provider namespace and operation.
6. Control applies schema, depth, entry, string, redaction, masking, and final byte limits.
7. The response is sent only to the requesting player and stale browser responses are ignored.

Provider cursors never cross the browser boundary directly. Control replaces them with player- and request-scope-bound opaque handles that expire after 120 seconds. A Synex resource start or stop clears cached catalog/overview data and cursor state, then sends a bounded invalidation signal to open viewers so the catalog and active view can be requested again.

See [architecture](architecture.md), [provider contract](providers.md), [diagnostics](diagnostics.md), [permissions](permissions.md), and [security](security.md) before enabling the resource.
