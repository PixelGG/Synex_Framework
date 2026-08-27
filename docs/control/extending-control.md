# Extending Synex Control

Use a provider when a Synex resource owns diagnostics that cannot be represented by the Core provider. Do not add resource-specific SQL or `GetResourceState` branches to `synex_control`.

## Checklist

1. Define a compact summary and bounded read models in the owning resource.
2. Add an exact `controlProvider` descriptor to its `synex.resource.json`; assign an `accessClass` to every view.
3. Request `synex.control.provider.register`; do not depend on `synex_control`.
4. Declare closed bounded `input.fields` for every operator value the view needs. A search view also declares its kinds, modes, and per-kind access class.
5. Register the identical metadata and only the read-operation allowlist through `api.ControlProviders.register`.
6. Use keyset/cursor paging and server-side filter/sort allowlists. Return the raw cursor only to Control; Control converts it to a scoped opaque browser handle.
7. Return public error codes without payloads, SQL, paths, or stack traces.
8. Add static and runtime tests for schema/descriptor parity, access and input metadata, bounds, timeout, restart, unavailable state, redaction, pagination, huge logical datasets, and mutation absence.
9. Document actual views and explicit unavailable telemetry.
10. Run `npm run check`, the focused provider/Control tests, `npm test`, `npm run security`, and `npm run certify`.
11. Complete the real FXServer/CEF acceptance before promoting maturity.

Provider output is sanitized again by Control, but that is defense in depth rather than permission to emit secrets. A provider should project only the fields an operator view needs.

Adding a new presentation type requires a reviewed Core schema, Control renderer, accessibility behavior, payload contract, and tests. A provider cannot introduce it through metadata alone.

See also [Creating a Synex resource](../development/creating-resources.md#expose-optional-control-diagnostics) and the complete [provider contract](providers.md).
