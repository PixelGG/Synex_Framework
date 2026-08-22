# Read-only control plane

`synex_control` is a dependency-free NUI for bounded Synex operational snapshots. It is a read surface, not an admin dashboard, and contains no actions that mutate players, resources, configuration, entities, accounts, or database state.

## Access and startup

Start `synex_core` before `synex_control`, then grant the dedicated ACE only to operators who may inspect runtime data:

```cfg
ensure synex_core
ensure synex_control

add_ace group.admin synex.control.view allow
```

An authorized in-game operator opens the panel with:

```text
/synex-control
```

Console execution intentionally does not open a client UI. An unauthorized command, refresh, or search request receives no snapshot.

## Data shown

Each refresh reads current data from capability-gated public surfaces:

- `Diagnostics.getControlSnapshot()` for bounded Core runtime, resource, dependency, contract, capability, RPC/service/event, hook, database, session, character, performance, security, and compatibility projections;
- `Diagnostics.run()` for current doctor checks and migration status fallback;
- `synex.groups@1.get_control_summary`, `synex.accounts@1.get_control_summary`, and `synex.entities@1.getControlSummary` for optional domain-owned aggregates;
- `Diagnostics.search()` for an exact `trace`, `character`, `transaction`, or `resource` lookup submitted by an operator.

The navigation exposes 21 fixed sections: overview, runtime, resources, dependencies, contracts, capabilities, RPC/services, hooks, database, migrations, sessions, characters, groups, accounts, ledger, entities, audit, tracing, performance, security, and compatibility. A section is marked `UNAVAILABLE` when its owner is stopped, its capability is denied, or the running version does not expose that read model. The panel never substitutes zeros, cached examples, generated charts, health claims, or sample resource data.

Normal snapshots are cached server-side for one second. Exact searches bypass that cache. The timestamp is the UTC time at which the server assembled the response.

Snapshots are bounded before JSON serialization: depth, entry count, key length, and string length have fixed ceilings. Keys associated with credentials, authorization, identifiers, licenses, passwords, secrets, tokens, connection strings, or webhooks are redacted. Responses are sent only to the requesting player.

## Security boundary

NUI and client input are untrusted even though this surface is read-only.

- The server performs the `synex.control.view` ACE check on every open and refresh.
- The NUI can request only `close`, `refresh`, and `search`. Close and refresh ignore request content; search accepts a closed object containing one allowed kind and a bounded exact value.
- Refresh and search have independent client throttles and share a server token bucket. The server keeps no browser-provided identity or authorization state.
- The client accepts the snapshot event only from the server event source and never accepts a snapshot from NUI input.
- Browser messages are accepted only from the current NUI origins, and values are rendered with DOM `textContent`.
- `synex_control` declares `synex.runtime.read`, `synex.metrics.read`, `synex.audit.summary`, `synex.groups.read`, `synex.accounts.integrity.read`, and `synex.entities.read`; Core policy still has final authority for every read.
- No mutating contract, export, network event, or NUI callback is present. A future operation requires its own versioned Core contract and explicit capability; it must not be added to the read path.

## Closed-state guarantee

The initial document contains an empty `#root`. While closed:

- `html`, `body`, and `#root` are transparent;
- all three are non-interactive with `pointer-events: none`;
- no panel, overlay, or full-screen background exists in the DOM;
- NUI focus is false.

Opening builds the panel with DOM APIs and enables input. Closing or stopping the client resource clears `#root`, removes the open marker, and releases keyboard and mouse focus. Server-provided values are assigned through `textContent`; they are never inserted as HTML.

## Deliberate limitations

- The panel has no independent historical storage, alerting, charts, service controls, or write operations. Exact audit search reads the Core-owned durable audit log and does not persist a browser search history.
- It does not replace server logs or external observability.
- Core sections require Core to be started; domain sections also require their corresponding service provider. Every section remains subject to its declared capability and operator policy.
- ACE authorization controls the player-facing panel; it does not make arbitrary server resources a sandbox. Cfx resources installed on the same server remain trusted server code.

## Platform references

- [Cfx.re NUI callbacks](https://docs.fivem.net/docs/scripting-manual/nui-development/nui-callbacks/)
- [Cfx.re secure event guidance](https://docs.fivem.net/docs/developers/server-security/)
- [Cfx.re `RegisterNetEvent`](https://docs.fivem.net/docs/scripting-reference/runtimes/lua/functions/RegisterNetEvent/)
