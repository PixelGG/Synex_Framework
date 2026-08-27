# Control provider contract

A Control provider is a read-only diagnostics adapter owned by the resource whose state it describes. A domain or bridge provider requires Core and must not depend on `synex_control`; Control's process-local self-health provider is the only natural exception.

## Descriptor declaration

Declare metadata in `synex.resource.json` and request the registration capability:

```json
{
  "controlProvider": {
    "schemaVersion": 1,
    "namespace": "example",
    "label": "Example Domain",
    "category": "domain",
    "version": "1.0.0",
    "operations": ["summary", "list", "inspect", "search"],
    "views": [
      {
        "id": "overview",
        "label": "Example overview",
        "operation": "summary",
        "presentation": "key-value",
        "accessClass": "general",
        "order": 10
      },
      {
        "id": "records",
        "label": "Records",
        "operation": "list",
        "presentation": "table",
        "accessClass": "general",
        "order": 20,
        "description": "Bounded keyset page of current records."
      },
      {
        "id": "record",
        "label": "Record inspector",
        "operation": "inspect",
        "presentation": "detail",
        "accessClass": "general",
        "order": 30,
        "input": {
          "fields": [{
            "key": "id",
            "label": "Record ID",
            "source": "id",
            "type": "string",
            "format": "identifier",
            "required": true,
            "minLength": 1,
            "maxLength": 64
          }]
        }
      },
      {
        "id": "search",
        "label": "Record search",
        "operation": "search",
        "presentation": "table",
        "accessClass": "general",
        "order": 40,
        "search": {
          "kinds": [{
            "id": "record",
            "modes": ["exact"],
            "accessClass": "general"
          }]
        }
      }
    ]
  },
  "capabilities": {
    "request": ["synex.control.provider.register"]
  }
}
```

The descriptor is closed and schema-versioned. It requires namespace, label, category, version, one through eight unique operations and one through 32 views. Each view references a declared operation, one mandatory `accessClass`, and one fixed presentation primitive:

```text
metrics  key-value  table  detail  timeline  graph  findings
```

`input` is optional, but when present it declares one through eight closed, bounded fields. Every field requires `key`, `label`, `source`, `type`, `format`, and `required`; the input inherits the containing view's access class. A `search` view must declare `search.kinds`, and every kind separately declares its exact/prefix modes and mandatory access class. Control uses these trusted declarations for server authorization and browser forms; the browser cannot add a field or lower an access class.

## Runtime registration

Register through the caller-bound Core facade. Runtime metadata, ordered views, access classes, input/search metadata, and operation names must exactly match the descriptor.

```lua
local metadata, registrationError = api.ControlProviders.register({
    schemaVersion = 1,
    namespace = 'example',
    label = 'Example Domain',
    category = 'domain',
    version = '1.0.0',
    views = {
        {
            id = 'overview', label = 'Example overview', operation = 'summary',
            presentation = 'key-value', accessClass = 'general', order = 10,
        },
        {
            id = 'records',
            label = 'Records',
            operation = 'list',
            presentation = 'table',
            accessClass = 'general',
            order = 20,
            description = 'Bounded keyset page of current records.',
        },
        {
            id = 'record', label = 'Record inspector', operation = 'inspect',
            presentation = 'detail', accessClass = 'general', order = 30,
            input = { fields = {{
                key = 'id', label = 'Record ID', source = 'id',
                type = 'string', format = 'identifier', required = true,
                minLength = 1, maxLength = 64,
            }}},
        },
        {
            id = 'search', label = 'Record search', operation = 'search',
            presentation = 'table', accessClass = 'general', order = 40,
            search = { kinds = {{
                id = 'record', modes = { 'exact' }, accessClass = 'general',
            }}},
        },
    },
    operations = {
        summary = function(request, context)
            return repository:getBoundedSummary(request, context)
        end,
        list = function(request, context)
            return repository:listAfter(request.cursor, request.limit, request.filters)
        end,
        inspect = function(request, context)
            return repository:inspect(request.id, context)
        end,
        search = function(request, context)
            return repository:searchExact(request.query.value, request.limit, context)
        end,
    },
})
```

Registration is bound to the calling resource and current owner epoch. A resource stop/restart removes its handlers; a provider must reacquire Core and register again. Registration failure must remain a visible unavailable state. It must not cause the domain to expose a broad fallback service or make Control query provider tables.

Across a Cfx resource boundary, return `value, nil` for success and `false, error` for failure so the error survives positional result transport. Do not throw private database or adapter details through the provider funcref.

## Handler context

Core invokes a handler as `handler(request, context)`. The context is read-only and contains:

```text
caller      provider      namespace      operation
traceId     deadlineAt    readOnly=true  mode=observe|explain
```

Providers must check the deadline before expensive stages and keep reads bounded. On FXServer the registry isolates yielding reads in their own coroutine, returns a timeout at the deadline, keeps that provider busy until the late coroutine exits, and discards its result. Non-yielding Lua work still cannot be forcibly interrupted.

## Output requirements

- Plain JSON-compatible values only.
- Bounded depth, strings, keys and total entries.
- Complete Core invoke envelope no larger than 32 KiB.
- Stable cursor/keyset pagination; no unbounded offset scan.
- Server-side filter and sort allowlists.
- Compact `summary`; it must not execute every detail query.
- No secrets, credentials, connection details, raw registries, callables, userdata or database adapter objects.
- No raw player identifiers unless a justified view requires an identifier projection; Control masks them by default.
- Bounded public errors; SQL, paths, queries, parameters, stack traces and private payloads stay server-side.
- `simulate` explains a policy result only and never persists a decision.

Control sanitizes output again before NUI transport. That is defense in depth, not permission for a provider to emit sensitive data.

## Static and runtime verification

`synex validate`, `synex doctor` and `synex certify` statically check descriptor shape, namespace uniqueness, operation/view consistency, registration capability and the rule that a provider domain cannot depend on `synex_control`.

Static certification does not execute handlers. Provider acceptance also needs runtime coverage for registration mismatch, unavailable and restarted owners, busy/timeout/circuit behavior, malformed and oversized output, sanitization, cursor bounds, large logical datasets and absence of mutation paths. Real FXServer/CEF acceptance remains required before maturity promotion.
