# Synex Contract Reference

Source hash: `63fc97bec257cb54f15f7735448cd83fbde85834c33f2e9c98441f00c14375bb`

| Contract | Version | Kind | Provider | Network | Stability | Capability |
| --- | --- | --- | --- | --- | --- | --- |
| `synex.accounts.burn` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.burn` |
| `synex.accounts.capture_hold` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.hold` |
| `synex.accounts.create` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.create` |
| `synex.accounts.create_access_role` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.access.manage` |
| `synex.accounts.create_hold` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.hold` |
| `synex.accounts.credit` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.transfer` |
| `synex.accounts.debit` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.transfer` |
| `synex.accounts.get_access` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.access.read` |
| `synex.accounts.get_hold` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.read` |
| `synex.accounts.get_integrity` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.integrity.read` |
| `synex.accounts.get_snapshot` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.read` |
| `synex.accounts.grant_access` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.access.manage` |
| `synex.accounts.mint` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.mint` |
| `synex.accounts.register_currency` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.configure` |
| `synex.accounts.release_hold` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.hold` |
| `synex.accounts.reverse` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.reverse` |
| `synex.accounts.revoke_access` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.access.manage` |
| `synex.accounts.run_reconciliation` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.integrity.run` |
| `synex.accounts.transfer` | `1.0.0` | rpc | `synex_accounts` | none | experimental | `synex.accounts.transfer` |
| `synex.entities.bucket.create` | `1.0.0` | service | `synex_entities` | none | experimental | `synex.entities.bucket.create` |
| `synex.entities.bucket.destroy` | `1.0.0` | service | `synex_entities` | none | experimental | `synex.entities.bucket.destroy` |
| `synex.entities.bucket.move_entity` | `1.0.0` | service | `synex_entities` | none | experimental | `synex.entities.bucket.entity.move` |
| `synex.entities.bucket.move_player` | `1.0.0` | service | `synex_entities` | none | experimental | `synex.entities.bucket.player.move` |
| `synex.entities.delete` | `1.0.0` | service | `synex_entities` | none | experimental | `synex.entities.delete` |
| `synex.entities.get` | `1.0.0` | service | `synex_entities` | none | experimental | `synex.entities.read` |
| `synex.entities.health` | `1.0.0` | service | `synex_entities` | none | experimental | `synex.entities.read` |
| `synex.entities.resolve_persistent` | `1.0.0` | service | `synex_entities` | none | experimental | `synex.entities.read` |
| `synex.entities.spawn` | `1.0.0` | service | `synex_entities` | none | experimental | `synex.entities.spawn` |
| `synex.example.echo` | `1.0.0` | service | `synex_example` | none | experimental | — |
| `synex.groups.add_membership` | `1.0.0` | rpc | `synex_groups` | none | experimental | `synex.groups.manage` |
| `synex.groups.change_membership` | `1.0.0` | rpc | `synex_groups` | none | experimental | `synex.groups.manage` |
| `synex.groups.check_capability` | `1.0.0` | rpc | `synex_groups` | none | experimental | `synex.groups.read` |
| `synex.groups.create` | `1.0.0` | rpc | `synex_groups` | none | experimental | `synex.groups.manage` |
| `synex.groups.create_grade` | `1.0.0` | rpc | `synex_groups` | none | experimental | `synex.groups.grades.manage` |
| `synex.groups.get` | `1.0.0` | rpc | `synex_groups` | none | experimental | `synex.groups.read` |
| `synex.groups.get_read_model` | `1.0.0` | rpc | `synex_groups` | none | experimental | `synex.groups.read` |
| `synex.groups.remove_membership` | `1.0.0` | rpc | `synex_groups` | none | experimental | `synex.groups.manage` |
| `synex.groups.set_grade_capability` | `1.0.0` | rpc | `synex_groups` | none | experimental | `synex.groups.grades.manage` |
| `synex.groups.set_primary_membership` | `1.0.0` | rpc | `synex_groups` | none | experimental | `synex.groups.memberships.primary` |
| `synex.identity.characters.create` | `1.0.0` | service | `synex_core` | none | experimental | `synex.characters.create` |
| `synex.identity.characters.delete` | `1.0.0` | service | `synex_core` | none | experimental | `synex.characters.delete` |
| `synex.identity.characters.list` | `1.0.0` | service | `synex_core` | none | experimental | `synex.identity.read` |
| `synex.identity.characters.select` | `1.0.0` | service | `synex_core` | none | experimental | `synex.characters.select` |
| `synex.identity.session.by_source` | `1.0.0` | service | `synex_core` | none | experimental | `synex.identity.read` |
| `synex.runtime.status` | `1.0.0` | service | `synex_core` | none | experimental | `synex.runtime.read` |

## `synex.accounts.burn`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `ACCOUNT_NOT_FOUND`, `ACCOUNT_UNAVAILABLE`, `CURRENCY_MISMATCH`, `INVALID_LEDGER_ROLE`, `INSUFFICIENT_FUNDS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "amount_minor": {
      "maximum": 9007199254740991,
      "minimum": 1,
      "type": "integer"
    },
    "burn_account_id": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    },
    "reference": {
      "maxLength": 128,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "account_id",
    "burn_account_id",
    "amount_minor"
  ],
  "type": "object"
}
```

### Output

```json
{
  "properties": {
    "credit_minor": {
      "type": "integer"
    },
    "debit_minor": {
      "type": "integer"
    },
    "posting_id": {
      "type": "string"
    },
    "transaction_id": {
      "type": "string"
    }
  },
  "required": [
    "transaction_id",
    "posting_id",
    "debit_minor",
    "credit_minor"
  ],
  "type": "object"
}
```

## `synex.accounts.capture_hold`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `HOLD_NOT_FOUND`, `HOLD_EXPIRED`, `HOLD_TERMINAL`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "hold_id": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    },
    "reference": {
      "maxLength": 128,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "hold_id"
  ],
  "type": "object"
}
```

### Output

```json
{
  "properties": {
    "amount_minor": {
      "type": "integer"
    },
    "credit_account_id": {
      "type": "string"
    },
    "debit_account_id": {
      "type": "string"
    },
    "hold_id": {
      "type": "string"
    },
    "posting_id": {
      "type": "string"
    },
    "state": {
      "type": "string"
    },
    "transaction_id": {
      "type": "string"
    }
  },
  "required": [
    "hold_id",
    "state",
    "transaction_id",
    "posting_id",
    "debit_account_id",
    "credit_account_id",
    "amount_minor"
  ],
  "type": "object"
}
```

## `synex.accounts.create`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `CURRENCY_NOT_FOUND`, `CURRENCY_UNAVAILABLE`, `ACCOUNT_KEY_EXISTS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "account_key": {
      "maxLength": 64,
      "minLength": 3,
      "type": "string"
    },
    "account_role": {
      "enum": [
        "asset",
        "mint",
        "burn"
      ]
    },
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "currency_code": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    },
    "owner_kind": {
      "enum": [
        "system",
        "user",
        "character",
        "group"
      ]
    },
    "owner_ref": {
      "maxLength": 64,
      "minLength": 1,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "currency_code",
    "account_role",
    "owner_kind",
    "owner_ref"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "account_role": {
      "type": "string"
    },
    "available_minor": {
      "const": 0
    },
    "booked_minor": {
      "const": 0
    },
    "currency_code": {
      "type": "string"
    },
    "owner_kind": {
      "type": "string"
    },
    "owner_ref": {
      "type": "string"
    },
    "reserved_minor": {
      "const": 0
    },
    "sequence": {
      "const": 0
    },
    "status": {
      "const": "active"
    }
  },
  "required": [
    "account_id",
    "currency_code",
    "account_role",
    "owner_kind",
    "owner_ref",
    "status",
    "booked_minor",
    "reserved_minor",
    "available_minor",
    "sequence"
  ],
  "type": "object"
}
```

## `synex.accounts.create_access_role`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `ACCOUNT_NOT_FOUND`, `ACCESS_ROLE_EXISTS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "display_name": {
      "maxLength": 96,
      "minLength": 1,
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "permissions": {
      "items": {
        "enum": [
          "view",
          "deposit",
          "withdraw",
          "transfer",
          "history",
          "manage",
          "close"
        ]
      },
      "maxItems": 7,
      "minItems": 1,
      "type": "array",
      "uniqueItems": true
    },
    "role_key": {
      "maxLength": 48,
      "minLength": 2,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "account_id",
    "role_key",
    "display_name",
    "permissions"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "display_name": {
      "type": "string"
    },
    "permissions": {
      "items": {
        "enum": [
          "view",
          "deposit",
          "withdraw",
          "transfer",
          "history",
          "manage",
          "close"
        ]
      },
      "maxItems": 7,
      "type": "array",
      "uniqueItems": true
    },
    "role_id": {
      "type": "string"
    },
    "role_key": {
      "type": "string"
    },
    "version": {
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "role_id",
    "account_id",
    "role_key",
    "display_name",
    "permissions",
    "version"
  ],
  "type": "object"
}
```

## `synex.accounts.create_hold`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `ACCOUNT_NOT_FOUND`, `ACCOUNT_UNAVAILABLE`, `CURRENCY_MISMATCH`, `INSUFFICIENT_FUNDS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "amount_minor": {
      "maximum": 9007199254740991,
      "minimum": 1,
      "type": "integer"
    },
    "capture_account_id": {
      "type": "string"
    },
    "expires_in_seconds": {
      "maximum": 604800,
      "minimum": 1,
      "type": "integer"
    },
    "idempotency_key": {
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    },
    "reference": {
      "maxLength": 128,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "account_id",
    "capture_account_id",
    "amount_minor",
    "expires_in_seconds"
  ],
  "type": "object"
}
```

### Output

```json
{
  "properties": {
    "account_id": {
      "type": "string"
    },
    "amount_minor": {
      "type": "integer"
    },
    "capture_account_id": {
      "type": "string"
    },
    "currency_code": {
      "type": "string"
    },
    "expires_in_seconds": {
      "type": "integer"
    },
    "hold_id": {
      "type": "string"
    },
    "state": {
      "type": "string"
    }
  },
  "required": [
    "hold_id",
    "account_id",
    "capture_account_id",
    "amount_minor",
    "currency_code",
    "state",
    "expires_in_seconds"
  ],
  "type": "object"
}
```

## `synex.accounts.credit`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `ACCOUNT_NOT_FOUND`, `ACCOUNT_UNAVAILABLE`, `CURRENCY_MISMATCH`, `INVALID_LEDGER_ROLE`, `INSUFFICIENT_FUNDS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "amount_minor": {
      "maximum": 9007199254740991,
      "minimum": 1,
      "type": "integer"
    },
    "counterparty_account_id": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    },
    "reference": {
      "maxLength": 128,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "counterparty_account_id",
    "account_id",
    "amount_minor"
  ],
  "type": "object"
}
```

### Output

```json
{
  "properties": {
    "credit_minor": {
      "type": "integer"
    },
    "debit_minor": {
      "type": "integer"
    },
    "posting_id": {
      "type": "string"
    },
    "transaction_id": {
      "type": "string"
    }
  },
  "required": [
    "transaction_id",
    "posting_id",
    "debit_minor",
    "credit_minor"
  ],
  "type": "object"
}
```

## `synex.accounts.debit`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `ACCOUNT_NOT_FOUND`, `ACCOUNT_UNAVAILABLE`, `CURRENCY_MISMATCH`, `INVALID_LEDGER_ROLE`, `INSUFFICIENT_FUNDS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "amount_minor": {
      "maximum": 9007199254740991,
      "minimum": 1,
      "type": "integer"
    },
    "counterparty_account_id": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    },
    "reference": {
      "maxLength": 128,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "account_id",
    "counterparty_account_id",
    "amount_minor"
  ],
  "type": "object"
}
```

### Output

```json
{
  "properties": {
    "credit_minor": {
      "type": "integer"
    },
    "debit_minor": {
      "type": "integer"
    },
    "posting_id": {
      "type": "string"
    },
    "transaction_id": {
      "type": "string"
    }
  },
  "required": [
    "transaction_id",
    "posting_id",
    "debit_minor",
    "credit_minor"
  ],
  "type": "object"
}
```

## `synex.accounts.get_access`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: no
- Errors: `VALIDATION_FAILED`, `ACCOUNT_NOT_FOUND`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "principal_kind": {
      "enum": [
        "system",
        "resource",
        "user",
        "character",
        "group"
      ]
    },
    "principal_ref": {
      "maxLength": 128,
      "minLength": 2,
      "type": "string"
    }
  },
  "required": [
    "account_id",
    "principal_kind",
    "principal_ref"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "grant_id": {
      "type": "string"
    },
    "grant_version": {
      "minimum": 1,
      "type": "integer"
    },
    "granted": {
      "type": "boolean"
    },
    "permissions": {
      "items": {
        "enum": [
          "view",
          "deposit",
          "withdraw",
          "transfer",
          "history",
          "manage",
          "close"
        ]
      },
      "maxItems": 7,
      "type": "array",
      "uniqueItems": true
    },
    "principal_kind": {
      "type": "string"
    },
    "principal_ref": {
      "type": "string"
    },
    "role_display_name": {
      "type": "string"
    },
    "role_id": {
      "type": "string"
    },
    "role_key": {
      "type": "string"
    },
    "valid_until": {
      "type": "string"
    }
  },
  "required": [
    "account_id",
    "principal_kind",
    "principal_ref",
    "granted",
    "permissions"
  ],
  "type": "object"
}
```

## `synex.accounts.get_hold`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: no
- Errors: `VALIDATION_FAILED`, `HOLD_NOT_FOUND`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "hold_id": {
      "type": "string"
    }
  },
  "required": [
    "hold_id"
  ],
  "type": "object"
}
```

### Output

```json
{
  "properties": {
    "account_id": {
      "type": "string"
    },
    "amount_minor": {
      "type": "integer"
    },
    "capture_account_id": {
      "type": "string"
    },
    "created_at": {
      "type": "string"
    },
    "event_id": {
      "type": "string"
    },
    "event_occurred_at": {
      "type": "string"
    },
    "expires_at": {
      "type": "string"
    },
    "hold_id": {
      "type": "string"
    },
    "metadata_json": {
      "type": "string"
    },
    "state": {
      "type": "string"
    }
  },
  "required": [
    "hold_id",
    "account_id",
    "capture_account_id",
    "amount_minor",
    "state",
    "metadata_json",
    "expires_at",
    "created_at",
    "event_id",
    "event_occurred_at"
  ],
  "type": "object"
}
```

## `synex.accounts.get_integrity`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: no
- Errors: `VALIDATION_FAILED`, `CURRENCY_NOT_FOUND`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "currency_code": {
      "maxLength": 16,
      "minLength": 2,
      "type": "string"
    }
  },
  "required": [
    "currency_code"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "currency_code": {
      "type": "string"
    },
    "currency_id": {
      "type": "string"
    },
    "cutoff_posting_id": {
      "maxLength": 20,
      "minLength": 1,
      "type": "string"
    },
    "finding_count": {
      "maximum": 5,
      "minimum": 0,
      "type": "integer"
    },
    "findings": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "aggregate_id": {
            "maxLength": 128,
            "type": "string"
          },
          "aggregate_type": {
            "maxLength": 32,
            "type": "string"
          },
          "created_at": {
            "type": "string"
          },
          "details_json": {
            "maxLength": 4096,
            "type": "string"
          },
          "finding_id": {
            "type": "string"
          },
          "rule": {
            "enum": [
              "ledger_imbalance",
              "snapshot_sum_drift",
              "negative_asset_balance",
              "reserved_exceeds_booked",
              "orphan_transaction"
            ]
          },
          "severity": {
            "const": "warn"
          }
        },
        "required": [
          "finding_id",
          "rule",
          "severity",
          "details_json",
          "created_at"
        ],
        "type": "object"
      },
      "maxItems": 16,
      "type": "array"
    },
    "generated_at": {
      "type": "string"
    },
    "model_version": {
      "minimum": 1,
      "type": "integer"
    },
    "negative_asset_count": {
      "maxLength": 20,
      "minLength": 1,
      "type": "string"
    },
    "orphan_transaction_count": {
      "maxLength": 20,
      "minLength": 1,
      "type": "string"
    },
    "posting_count": {
      "maxLength": 20,
      "minLength": 1,
      "type": "string"
    },
    "reserved_exceeds_booked_count": {
      "maxLength": 20,
      "minLength": 1,
      "type": "string"
    },
    "status": {
      "enum": [
        "healthy",
        "warn"
      ]
    },
    "total_booked_minor": {
      "maxLength": 38,
      "minLength": 1,
      "type": "string"
    },
    "total_credit_minor": {
      "maxLength": 38,
      "minLength": 1,
      "type": "string"
    },
    "total_debit_minor": {
      "maxLength": 38,
      "minLength": 1,
      "type": "string"
    },
    "transaction_count": {
      "maxLength": 20,
      "minLength": 1,
      "type": "string"
    }
  },
  "required": [
    "currency_id",
    "currency_code",
    "model_version",
    "cutoff_posting_id",
    "transaction_count",
    "posting_count",
    "total_debit_minor",
    "total_credit_minor",
    "total_booked_minor",
    "negative_asset_count",
    "reserved_exceeds_booked_count",
    "orphan_transaction_count",
    "finding_count",
    "status",
    "generated_at",
    "findings"
  ],
  "type": "object"
}
```

## `synex.accounts.get_snapshot`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: no
- Errors: `VALIDATION_FAILED`, `ACCOUNT_NOT_FOUND`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    }
  },
  "required": [
    "account_id"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "account_key": {
      "type": "string"
    },
    "account_role": {
      "type": "string"
    },
    "available_minor": {
      "type": "integer"
    },
    "booked_minor": {
      "type": "integer"
    },
    "currency_code": {
      "type": "string"
    },
    "minor_unit": {
      "type": "integer"
    },
    "owner_kind": {
      "type": "string"
    },
    "owner_ref": {
      "type": "string"
    },
    "reserved_minor": {
      "minimum": 0,
      "type": "integer"
    },
    "sequence": {
      "minimum": 0,
      "type": "integer"
    },
    "snapshot_created_at": {
      "type": "string"
    },
    "status": {
      "type": "string"
    },
    "version": {
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "account_id",
    "currency_code",
    "minor_unit",
    "account_role",
    "owner_kind",
    "owner_ref",
    "status",
    "booked_minor",
    "reserved_minor",
    "available_minor",
    "sequence",
    "version",
    "snapshot_created_at"
  ],
  "type": "object"
}
```

## `synex.accounts.grant_access`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `ACCESS_ROLE_NOT_FOUND`, `ACCESS_GRANT_EXISTS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "principal_kind": {
      "enum": [
        "system",
        "resource",
        "user",
        "character",
        "group"
      ]
    },
    "principal_ref": {
      "maxLength": 128,
      "minLength": 2,
      "type": "string"
    },
    "role_id": {
      "type": "string"
    },
    "valid_for_seconds": {
      "maximum": 31536000,
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "idempotency_key",
    "account_id",
    "role_id",
    "principal_kind",
    "principal_ref"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "grant_id": {
      "type": "string"
    },
    "principal_kind": {
      "type": "string"
    },
    "principal_ref": {
      "type": "string"
    },
    "role_id": {
      "type": "string"
    },
    "status": {
      "const": "active"
    },
    "valid_for_seconds": {
      "maximum": 31536000,
      "minimum": 1,
      "type": "integer"
    },
    "version": {
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "grant_id",
    "account_id",
    "role_id",
    "principal_kind",
    "principal_ref",
    "status",
    "version"
  ],
  "type": "object"
}
```

## `synex.accounts.mint`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `ACCOUNT_NOT_FOUND`, `ACCOUNT_UNAVAILABLE`, `CURRENCY_MISMATCH`, `INVALID_LEDGER_ROLE`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "amount_minor": {
      "maximum": 9007199254740991,
      "minimum": 1,
      "type": "integer"
    },
    "idempotency_key": {
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    },
    "mint_account_id": {
      "type": "string"
    },
    "reference": {
      "maxLength": 128,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "mint_account_id",
    "account_id",
    "amount_minor"
  ],
  "type": "object"
}
```

### Output

```json
{
  "properties": {
    "credit_minor": {
      "type": "integer"
    },
    "debit_minor": {
      "type": "integer"
    },
    "posting_id": {
      "type": "string"
    },
    "transaction_id": {
      "type": "string"
    }
  },
  "required": [
    "transaction_id",
    "posting_id",
    "debit_minor",
    "credit_minor"
  ],
  "type": "object"
}
```

## `synex.accounts.register_currency`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `CURRENCY_EXISTS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "currency_code": {
      "pattern": "^[a-z][a-z0-9_]{1,15}$",
      "type": "string"
    },
    "display_name": {
      "maxLength": 64,
      "minLength": 1,
      "type": "string"
    },
    "idempotency_key": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "minor_unit": {
      "maximum": 6,
      "minimum": 0,
      "type": "integer"
    }
  },
  "required": [
    "idempotency_key",
    "currency_code",
    "display_name",
    "minor_unit"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "currency_code": {
      "type": "string"
    },
    "currency_id": {
      "type": "string"
    },
    "display_name": {
      "type": "string"
    },
    "minor_unit": {
      "type": "integer"
    },
    "status": {
      "const": "active"
    }
  },
  "required": [
    "currency_id",
    "currency_code",
    "display_name",
    "minor_unit",
    "status"
  ],
  "type": "object"
}
```

## `synex.accounts.release_hold`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `HOLD_NOT_FOUND`, `HOLD_TERMINAL`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "hold_id": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    },
    "reference": {
      "maxLength": 128,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "hold_id"
  ],
  "type": "object"
}
```

### Output

```json
{
  "properties": {
    "account_id": {
      "type": "string"
    },
    "amount_minor": {
      "type": "integer"
    },
    "hold_id": {
      "type": "string"
    },
    "state": {
      "type": "string"
    }
  },
  "required": [
    "hold_id",
    "state",
    "account_id",
    "amount_minor"
  ],
  "type": "object"
}
```

## `synex.accounts.reverse`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `TRANSACTION_NOT_FOUND`, `TRANSACTION_ALREADY_REVERSED`, `REVERSAL_NOT_REVERSIBLE`, `ACCOUNT_UNAVAILABLE`, `INSUFFICIENT_FUNDS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "idempotency_key": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    },
    "reason": {
      "maxLength": 256,
      "minLength": 1,
      "type": "string"
    },
    "transaction_id": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "transaction_id",
    "reason"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "amount_minor": {
      "maximum": 9007199254740991,
      "minimum": 1,
      "type": "integer"
    },
    "credit_account_id": {
      "type": "string"
    },
    "currency_code": {
      "type": "string"
    },
    "debit_account_id": {
      "type": "string"
    },
    "original_transaction_id": {
      "type": "string"
    },
    "posting_id": {
      "type": "string"
    },
    "reversal_id": {
      "type": "string"
    },
    "transaction_id": {
      "type": "string"
    }
  },
  "required": [
    "reversal_id",
    "original_transaction_id",
    "transaction_id",
    "posting_id",
    "debit_account_id",
    "credit_account_id",
    "amount_minor",
    "currency_code"
  ],
  "type": "object"
}
```

## `synex.accounts.revoke_access`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `ACCESS_GRANT_NOT_FOUND`, `ACCESS_GRANT_REVOKED`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "grant_id": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "reason": {
      "maxLength": 256,
      "minLength": 1,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "grant_id",
    "reason",
    "actor_ref"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "account_id": {
      "type": "string"
    },
    "grant_id": {
      "type": "string"
    },
    "principal_kind": {
      "type": "string"
    },
    "principal_ref": {
      "type": "string"
    },
    "role_id": {
      "type": "string"
    },
    "status": {
      "const": "revoked"
    },
    "version": {
      "minimum": 2,
      "type": "integer"
    }
  },
  "required": [
    "grant_id",
    "account_id",
    "role_id",
    "principal_kind",
    "principal_ref",
    "status",
    "version"
  ],
  "type": "object"
}
```

## `synex.accounts.run_reconciliation`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `CURRENCY_NOT_FOUND`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "currency_code": {
      "maxLength": 16,
      "minLength": 2,
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "currency_code"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "currency_code": {
      "type": "string"
    },
    "currency_id": {
      "type": "string"
    },
    "cutoff_posting_id": {
      "maxLength": 20,
      "minLength": 1,
      "type": "string"
    },
    "finding_count": {
      "maximum": 5,
      "minimum": 0,
      "type": "integer"
    },
    "findings": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "rule": {
            "enum": [
              "ledger_imbalance",
              "snapshot_sum_drift",
              "negative_asset_balance",
              "reserved_exceeds_booked",
              "orphan_transaction"
            ]
          },
          "severity": {
            "const": "warn"
          }
        },
        "required": [
          "rule",
          "severity"
        ],
        "type": "object"
      },
      "maxItems": 5,
      "type": "array"
    },
    "model_version": {
      "minimum": 2,
      "type": "integer"
    },
    "posting_count": {
      "maxLength": 20,
      "minLength": 1,
      "type": "string"
    },
    "run_id": {
      "type": "string"
    },
    "status": {
      "enum": [
        "healthy",
        "warn"
      ]
    },
    "total_booked_minor": {
      "maxLength": 38,
      "minLength": 1,
      "type": "string"
    },
    "total_credit_minor": {
      "maxLength": 38,
      "minLength": 1,
      "type": "string"
    },
    "total_debit_minor": {
      "maxLength": 38,
      "minLength": 1,
      "type": "string"
    },
    "transaction_count": {
      "maxLength": 20,
      "minLength": 1,
      "type": "string"
    }
  },
  "required": [
    "run_id",
    "currency_id",
    "currency_code",
    "model_version",
    "cutoff_posting_id",
    "transaction_count",
    "posting_count",
    "total_debit_minor",
    "total_credit_minor",
    "total_booked_minor",
    "status",
    "finding_count",
    "findings"
  ],
  "type": "object"
}
```

## `synex.accounts.transfer`

- Version: `1.0.0`
- Provider: `synex_accounts`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `ACCOUNT_NOT_FOUND`, `ACCOUNT_UNAVAILABLE`, `CURRENCY_MISMATCH`, `INVALID_LEDGER_ROLE`, `INSUFFICIENT_FUNDS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "maxLength": 128,
      "type": "string"
    },
    "amount_minor": {
      "maximum": 9007199254740991,
      "minimum": 1,
      "type": "integer"
    },
    "destination_account_id": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    },
    "reference": {
      "maxLength": 128,
      "type": "string"
    },
    "source_account_id": {
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "source_account_id",
    "destination_account_id",
    "amount_minor"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "credit_account_id": {
      "type": "string"
    },
    "credit_minor": {
      "type": "integer"
    },
    "currency_code": {
      "type": "string"
    },
    "debit_account_id": {
      "type": "string"
    },
    "debit_minor": {
      "type": "integer"
    },
    "posting_id": {
      "type": "string"
    },
    "transaction_id": {
      "type": "string"
    },
    "transaction_kind": {
      "type": "string"
    }
  },
  "required": [
    "transaction_id",
    "posting_id",
    "transaction_kind",
    "debit_account_id",
    "credit_account_id",
    "debit_minor",
    "credit_minor",
    "currency_code"
  ],
  "type": "object"
}
```

## `synex.entities.bucket.create`

- Version: `1.0.0`
- Provider: `synex_entities`
- Idempotent: no
- Errors: `CONFLICT`, `FORBIDDEN`, `INVALID_ARGUMENT`, `RATE_LIMITED`, `STALE_RESOURCE`, `UNAVAILABLE`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "purpose": {
      "maxLength": 64,
      "minLength": 1,
      "type": "string"
    }
  },
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "bucket": {
      "minimum": 1,
      "type": "integer"
    },
    "generation": {
      "maxLength": 64,
      "minLength": 8,
      "pattern": "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
      "type": "string"
    },
    "lockdown": {
      "const": "strict"
    },
    "populationEnabled": {
      "const": false
    }
  },
  "required": [
    "bucket",
    "generation",
    "lockdown",
    "populationEnabled"
  ],
  "type": "object"
}
```

## `synex.entities.bucket.destroy`

- Version: `1.0.0`
- Provider: `synex_entities`
- Idempotent: yes
- Errors: `CONFLICT`, `FORBIDDEN`, `INVALID_ARGUMENT`, `NOT_FOUND`, `RATE_LIMITED`, `STALE_BUCKET`, `STALE_ENTITY`, `STALE_RESOURCE`, `UNAVAILABLE`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "bucket": {
      "minimum": 1,
      "type": "integer"
    },
    "generation": {
      "maxLength": 64,
      "minLength": 8,
      "pattern": "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
      "type": "string"
    }
  },
  "required": [
    "bucket",
    "generation"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "bucket": {
      "type": "integer"
    },
    "destroyed": {
      "const": true
    }
  },
  "required": [
    "bucket",
    "destroyed"
  ],
  "type": "object"
}
```

## `synex.entities.bucket.move_entity`

- Version: `1.0.0`
- Provider: `synex_entities`
- Idempotent: yes
- Errors: `CONFLICT`, `FORBIDDEN`, `INVALID_ARGUMENT`, `NOT_FOUND`, `RATE_LIMITED`, `STALE_BUCKET`, `STALE_ENTITY`, `STALE_RESOURCE`, `UNAVAILABLE`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "bucket": {
      "minimum": 0,
      "type": "integer"
    },
    "bucketGeneration": {
      "oneOf": [
        {
          "const": 0
        },
        {
          "maxLength": 64,
          "minLength": 8,
          "pattern": "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
          "type": "string"
        }
      ]
    },
    "entityId": {
      "maxLength": 64,
      "minLength": 8,
      "type": "string"
    },
    "generation": {
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "entityId",
    "generation",
    "bucket",
    "bucketGeneration"
  ],
  "type": "object"
}
```

### Output

```json
{
  "type": "object"
}
```

## `synex.entities.bucket.move_player`

- Version: `1.0.0`
- Provider: `synex_entities`
- Idempotent: yes
- Errors: `CONFLICT`, `FORBIDDEN`, `INVALID_ARGUMENT`, `NOT_FOUND`, `RATE_LIMITED`, `STALE_BUCKET`, `STALE_RESOURCE`, `UNAVAILABLE`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "bucket": {
      "minimum": 0,
      "type": "integer"
    },
    "bucketGeneration": {
      "oneOf": [
        {
          "const": 0
        },
        {
          "maxLength": 64,
          "minLength": 8,
          "pattern": "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
          "type": "string"
        }
      ]
    },
    "source": {
      "maximum": 65535,
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "source",
    "bucket",
    "bucketGeneration"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "bucket": {
      "type": "integer"
    },
    "source": {
      "type": "integer"
    }
  },
  "required": [
    "source",
    "bucket"
  ],
  "type": "object"
}
```

## `synex.entities.delete`

- Version: `1.0.0`
- Provider: `synex_entities`
- Idempotent: yes
- Errors: `CONFLICT`, `FORBIDDEN`, `INVALID_ARGUMENT`, `NOT_FOUND`, `RATE_LIMITED`, `STALE_ENTITY`, `STALE_RESOURCE`, `UNAVAILABLE`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "entityId": {
      "maxLength": 64,
      "minLength": 8,
      "type": "string"
    },
    "generation": {
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "entityId",
    "generation"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "deleted": {
      "const": true
    },
    "entityId": {
      "type": "string"
    }
  },
  "required": [
    "entityId",
    "deleted"
  ],
  "type": "object"
}
```

## `synex.entities.get`

- Version: `1.0.0`
- Provider: `synex_entities`
- Idempotent: yes
- Errors: `FORBIDDEN`, `INVALID_ARGUMENT`, `NOT_FOUND`, `RATE_LIMITED`, `STALE_ENTITY`, `STALE_RESOURCE`, `UNAVAILABLE`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "entityId": {
      "maxLength": 64,
      "minLength": 8,
      "type": "string"
    },
    "generation": {
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "entityId",
    "generation"
  ],
  "type": "object"
}
```

### Output

```json
{
  "type": "object"
}
```

## `synex.entities.health`

- Version: `1.0.0`
- Provider: `synex_entities`
- Idempotent: yes
- Errors: `FORBIDDEN`, `RATE_LIMITED`, `STALE_RESOURCE`, `UNAVAILABLE`

### Input

```json
{
  "additionalProperties": false,
  "type": "object"
}
```

### Output

```json
{
  "type": "object"
}
```

## `synex.entities.resolve_persistent`

- Version: `1.0.0`
- Provider: `synex_entities`
- Idempotent: yes
- Errors: `CONFLICT`, `FORBIDDEN`, `INVALID_ARGUMENT`, `NOT_FOUND`, `RATE_LIMITED`, `STALE_ENTITY`, `STALE_RESOURCE`, `UNAVAILABLE`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "persistentKey": {
      "maxLength": 128,
      "minLength": 1,
      "type": "string"
    }
  },
  "required": [
    "persistentKey"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "bucket": {
      "minimum": 0,
      "type": "integer"
    },
    "entityId": {
      "maxLength": 64,
      "minLength": 8,
      "type": "string"
    },
    "entityType": {
      "enum": [
        "vehicle",
        "ped",
        "object"
      ]
    },
    "generation": {
      "minimum": 1,
      "type": "integer"
    },
    "model": {
      "maximum": 4294967295,
      "minimum": 0,
      "type": "integer"
    },
    "netId": {
      "maximum": 65535,
      "minimum": 1,
      "type": "integer"
    },
    "networkOwner": {
      "maximum": 65535,
      "minimum": -1,
      "type": "integer"
    },
    "persistent": {
      "const": true
    }
  },
  "required": [
    "entityId",
    "generation",
    "netId",
    "entityType",
    "model",
    "bucket",
    "persistent"
  ],
  "type": "object"
}
```

## `synex.entities.spawn`

- Version: `1.0.0`
- Provider: `synex_entities`
- Idempotent: no
- Errors: `CONFLICT`, `FORBIDDEN`, `INTERNAL_ERROR`, `INVALID_ARGUMENT`, `NOT_FOUND`, `RATE_LIMITED`, `STALE_BUCKET`, `STALE_ENTITY`, `STALE_RESOURCE`, `UNAVAILABLE`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "bucket": {
      "maximum": 2147483647,
      "minimum": 0,
      "type": "integer"
    },
    "bucketGeneration": {
      "oneOf": [
        {
          "const": 0
        },
        {
          "maxLength": 64,
          "minLength": 8,
          "pattern": "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
          "type": "string"
        }
      ]
    },
    "doorFlag": {
      "type": "boolean"
    },
    "entityType": {
      "enum": [
        "vehicle",
        "ped",
        "object"
      ]
    },
    "heading": {
      "maximum": 360,
      "minimum": -360,
      "type": "number"
    },
    "model": {
      "maximum": 4294967295,
      "minimum": -2147483648,
      "type": "integer"
    },
    "owner": {
      "additionalProperties": false,
      "properties": {
        "id": {
          "maxLength": 64,
          "minLength": 1,
          "type": "string"
        },
        "type": {
          "enum": [
            "character",
            "resource",
            "system",
            "user"
          ]
        }
      },
      "required": [
        "type",
        "id"
      ],
      "type": "object"
    },
    "pedType": {
      "maximum": 29,
      "minimum": 0,
      "type": "integer"
    },
    "persistent": {
      "type": "boolean"
    },
    "persistentKey": {
      "maxLength": 128,
      "minLength": 1,
      "type": "string"
    },
    "position": {
      "additionalProperties": false,
      "properties": {
        "x": {
          "maximum": 20000,
          "minimum": -20000,
          "type": "number"
        },
        "y": {
          "maximum": 20000,
          "minimum": -20000,
          "type": "number"
        },
        "z": {
          "maximum": 20000,
          "minimum": -20000,
          "type": "number"
        }
      },
      "required": [
        "x",
        "y",
        "z"
      ],
      "type": "object"
    },
    "vehicleType": {
      "enum": [
        "automobile",
        "bike",
        "boat",
        "heli",
        "plane",
        "submarine",
        "trailer"
      ]
    }
  },
  "required": [
    "entityType",
    "model",
    "position",
    "owner"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "bucket": {
      "minimum": 0,
      "type": "integer"
    },
    "entityId": {
      "maxLength": 64,
      "minLength": 8,
      "type": "string"
    },
    "entityType": {
      "enum": [
        "vehicle",
        "ped",
        "object"
      ]
    },
    "generation": {
      "minimum": 1,
      "type": "integer"
    },
    "model": {
      "maximum": 4294967295,
      "minimum": 0,
      "type": "integer"
    },
    "netId": {
      "maximum": 65535,
      "minimum": 1,
      "type": "integer"
    },
    "networkOwner": {
      "maximum": 65535,
      "minimum": -1,
      "type": "integer"
    },
    "persistent": {
      "type": "boolean"
    }
  },
  "required": [
    "entityId",
    "generation",
    "netId",
    "entityType",
    "model",
    "bucket",
    "persistent"
  ],
  "type": "object"
}
```

## `synex.example.echo`

- Version: `1.0.0`
- Provider: `synex_example`
- Idempotent: yes
- Errors: `INVALID_ARGUMENT`, `NOT_READY`, `PROVIDER_UNAVAILABLE`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "message": {
      "maxLength": 128,
      "minLength": 1,
      "type": "string"
    }
  },
  "required": [
    "message"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "message": {
      "maxLength": 128,
      "type": "string"
    },
    "provider": {
      "const": "synex_example"
    }
  },
  "required": [
    "message",
    "provider"
  ],
  "type": "object"
}
```

## `synex.groups.add_membership`

- Version: `1.0.0`
- Provider: `synex_groups`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `MEMBERSHIP_EXISTS`, `GRADE_NOT_FOUND`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "type": "string"
    },
    "group_id": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "role_key": {
      "maxLength": 48,
      "minLength": 2,
      "type": "string"
    },
    "subject_id": {
      "type": "string"
    },
    "subject_kind": {
      "enum": [
        "user",
        "character"
      ]
    }
  },
  "required": [
    "idempotency_key",
    "group_id",
    "subject_kind",
    "subject_id",
    "role_key"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "group_id": {
      "type": "string"
    },
    "membership_id": {
      "type": "string"
    },
    "role_key": {
      "type": "string"
    },
    "status": {
      "type": "string"
    },
    "version": {
      "type": "integer"
    }
  },
  "required": [
    "membership_id",
    "group_id",
    "status",
    "version"
  ],
  "type": "object"
}
```

## `synex.groups.change_membership`

- Version: `1.0.0`
- Provider: `synex_groups`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `MEMBERSHIP_NOT_FOUND`, `MEMBERSHIP_REMOVED`, `GRADE_NOT_FOUND`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "type": "string"
    },
    "group_id": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "role_key": {
      "maxLength": 48,
      "minLength": 2,
      "type": "string"
    },
    "subject_id": {
      "type": "string"
    },
    "subject_kind": {
      "enum": [
        "user",
        "character"
      ]
    }
  },
  "required": [
    "idempotency_key",
    "group_id",
    "subject_kind",
    "subject_id",
    "role_key"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "group_id": {
      "type": "string"
    },
    "membership_id": {
      "type": "string"
    },
    "role_key": {
      "type": "string"
    },
    "status": {
      "type": "string"
    },
    "version": {
      "type": "integer"
    }
  },
  "required": [
    "membership_id",
    "group_id",
    "status",
    "version"
  ],
  "type": "object"
}
```

## `synex.groups.check_capability`

- Version: `1.0.0`
- Provider: `synex_groups`
- Idempotent: no
- Errors: `VALIDATION_FAILED`, `MEMBERSHIP_NOT_FOUND`, `READ_MODEL_TOO_LARGE`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "capability": {
      "maxLength": 128,
      "minLength": 1,
      "type": "string"
    },
    "group_id": {
      "type": "string"
    },
    "subject_id": {
      "type": "string"
    },
    "subject_kind": {
      "enum": [
        "user",
        "character"
      ]
    }
  },
  "required": [
    "group_id",
    "subject_kind",
    "subject_id",
    "capability"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "allowed": {
      "type": "boolean"
    },
    "capability": {
      "type": "string"
    },
    "denied": {
      "type": "boolean"
    },
    "grade_id": {
      "type": "string"
    },
    "group_id": {
      "type": "string"
    },
    "matched_rules": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "capability": {
            "type": "string"
          },
          "effect": {
            "enum": [
              "allow",
              "deny"
            ]
          }
        },
        "required": [
          "capability",
          "effect"
        ],
        "type": "object"
      },
      "maxItems": 128,
      "type": "array"
    },
    "membership_id": {
      "type": "string"
    },
    "read_model_version": {
      "type": "integer"
    }
  },
  "required": [
    "group_id",
    "membership_id",
    "grade_id",
    "capability",
    "allowed",
    "denied",
    "read_model_version",
    "matched_rules"
  ],
  "type": "object"
}
```

## `synex.groups.create`

- Version: `1.0.0`
- Provider: `synex_groups`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `GROUP_EXISTS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "created_by_ref": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "display_name": {
      "maxLength": 96,
      "minLength": 1,
      "type": "string"
    },
    "group_key": {
      "pattern": "^[a-z][a-z0-9_]{2,63}$",
      "type": "string"
    },
    "group_type": {
      "pattern": "^[a-z][a-z0-9_]{1,31}$",
      "type": "string"
    },
    "idempotency_key": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "metadata_json": {
      "maxLength": 4096,
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "group_key",
    "display_name",
    "group_type"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "group_id": {
      "type": "string"
    },
    "group_key": {
      "type": "string"
    },
    "status": {
      "const": "active"
    },
    "version": {
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "group_id",
    "group_key",
    "status",
    "version"
  ],
  "type": "object"
}
```

## `synex.groups.create_grade`

- Version: `1.0.0`
- Provider: `synex_groups`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `GROUP_NOT_FOUND`, `GROUP_UNAVAILABLE`, `GRADE_EXISTS`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "display_name": {
      "maxLength": 96,
      "minLength": 1,
      "type": "string"
    },
    "grade_key": {
      "pattern": "^[a-z][a-z0-9_]{1,47}$",
      "type": "string"
    },
    "group_id": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "idempotency_key": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "rank_value": {
      "maximum": 32767,
      "minimum": -32768,
      "type": "integer"
    }
  },
  "required": [
    "idempotency_key",
    "group_id",
    "grade_key",
    "display_name",
    "rank_value"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "display_name": {
      "type": "string"
    },
    "grade_id": {
      "type": "string"
    },
    "grade_key": {
      "type": "string"
    },
    "group_id": {
      "type": "string"
    },
    "rank_value": {
      "type": "integer"
    },
    "status": {
      "const": "active"
    },
    "version": {
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "grade_id",
    "group_id",
    "grade_key",
    "display_name",
    "rank_value",
    "status",
    "version"
  ],
  "type": "object"
}
```

## `synex.groups.get`

- Version: `1.0.0`
- Provider: `synex_groups`
- Idempotent: no
- Errors: `VALIDATION_FAILED`, `GROUP_NOT_FOUND`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "group_id": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    }
  },
  "required": [
    "group_id"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "created_at": {
      "type": "string"
    },
    "created_by_ref": {
      "type": [
        "string",
        "null"
      ]
    },
    "display_name": {
      "type": "string"
    },
    "group_id": {
      "type": "string"
    },
    "group_key": {
      "type": "string"
    },
    "group_type": {
      "type": "string"
    },
    "metadata_json": {
      "type": "string"
    },
    "read_model_version": {
      "minimum": 1,
      "type": "integer"
    },
    "status": {
      "type": "string"
    },
    "updated_at": {
      "type": "string"
    },
    "version": {
      "type": "integer"
    }
  },
  "required": [
    "group_id",
    "group_key",
    "display_name",
    "group_type",
    "status",
    "metadata_json",
    "version",
    "read_model_version",
    "created_at",
    "updated_at"
  ],
  "type": "object"
}
```

## `synex.groups.get_read_model`

- Version: `1.0.0`
- Provider: `synex_groups`
- Idempotent: no
- Errors: `VALIDATION_FAILED`, `MEMBERSHIP_NOT_FOUND`, `READ_MODEL_TOO_LARGE`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "group_id": {
      "type": "string"
    },
    "subject_id": {
      "type": "string"
    },
    "subject_kind": {
      "enum": [
        "user",
        "character"
      ]
    }
  },
  "required": [
    "group_id",
    "subject_kind",
    "subject_id"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "capabilities": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "capability": {
            "type": "string"
          },
          "effect": {
            "enum": [
              "allow",
              "deny"
            ]
          },
          "version": {
            "type": "integer"
          }
        },
        "required": [
          "capability",
          "effect",
          "version"
        ],
        "type": "object"
      },
      "maxItems": 128,
      "type": "array"
    },
    "grade_display_name": {
      "type": "string"
    },
    "grade_id": {
      "type": "string"
    },
    "grade_key": {
      "type": "string"
    },
    "grade_version": {
      "type": "integer"
    },
    "group_id": {
      "type": "string"
    },
    "group_key": {
      "type": "string"
    },
    "invalidated_at": {
      "type": "string"
    },
    "is_primary": {
      "type": "boolean"
    },
    "membership_id": {
      "type": "string"
    },
    "membership_status": {
      "type": "string"
    },
    "membership_version": {
      "type": "integer"
    },
    "primary_version": {
      "type": "integer"
    },
    "rank_value": {
      "type": "integer"
    },
    "read_model_version": {
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "group_id",
    "group_key",
    "read_model_version",
    "invalidated_at",
    "membership_id",
    "membership_status",
    "membership_version",
    "grade_id",
    "grade_key",
    "grade_display_name",
    "rank_value",
    "grade_version",
    "is_primary",
    "capabilities"
  ],
  "type": "object"
}
```

## `synex.groups.remove_membership`

- Version: `1.0.0`
- Provider: `synex_groups`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `MEMBERSHIP_NOT_FOUND`, `MEMBERSHIP_REMOVED`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "type": "string"
    },
    "group_id": {
      "type": "string"
    },
    "idempotency_key": {
      "type": "string"
    },
    "subject_id": {
      "type": "string"
    },
    "subject_kind": {
      "enum": [
        "user",
        "character"
      ]
    }
  },
  "required": [
    "idempotency_key",
    "group_id",
    "subject_kind",
    "subject_id"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "group_id": {
      "type": "string"
    },
    "membership_id": {
      "type": "string"
    },
    "status": {
      "const": "removed"
    },
    "version": {
      "type": "integer"
    }
  },
  "required": [
    "membership_id",
    "group_id",
    "status",
    "version"
  ],
  "type": "object"
}
```

## `synex.groups.set_grade_capability`

- Version: `1.0.0`
- Provider: `synex_groups`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `GRADE_NOT_FOUND`, `GRADE_CAPABILITY_LIMIT`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "capability": {
      "maxLength": 128,
      "minLength": 1,
      "type": "string"
    },
    "effect": {
      "enum": [
        "allow",
        "deny"
      ]
    },
    "grade_id": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "idempotency_key": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    }
  },
  "required": [
    "idempotency_key",
    "grade_id",
    "capability",
    "effect"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "capability": {
      "type": "string"
    },
    "effect": {
      "enum": [
        "allow",
        "deny"
      ]
    },
    "grade_id": {
      "type": "string"
    },
    "group_id": {
      "type": "string"
    }
  },
  "required": [
    "grade_id",
    "group_id",
    "capability",
    "effect"
  ],
  "type": "object"
}
```

## `synex.groups.set_primary_membership`

- Version: `1.0.0`
- Provider: `synex_groups`
- Idempotent: yes
- Errors: `VALIDATION_FAILED`, `IDEMPOTENCY_CONFLICT`, `OPERATION_IN_PROGRESS`, `MEMBERSHIP_NOT_FOUND`, `WRITE_CONFLICT`, `DATABASE_ERROR`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "actor_ref": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "group_id": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "idempotency_key": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "subject_id": {
      "pattern": "^[0-9a-f-]{36}$",
      "type": "string"
    },
    "subject_kind": {
      "enum": [
        "user",
        "character"
      ]
    }
  },
  "required": [
    "idempotency_key",
    "group_id",
    "subject_kind",
    "subject_id"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "group_id": {
      "type": "string"
    },
    "membership_id": {
      "type": "string"
    },
    "primary_version": {
      "minimum": 1,
      "type": "integer"
    },
    "subject_id": {
      "type": "string"
    },
    "subject_kind": {
      "type": "string"
    }
  },
  "required": [
    "membership_id",
    "group_id",
    "subject_kind",
    "subject_id",
    "primary_version"
  ],
  "type": "object"
}
```

## `synex.identity.characters.create`

- Version: `1.0.0`
- Provider: `synex_core`
- Idempotent: no
- Errors: `CAPABILITY_DENIED`, `CHARACTER_SLOT_UNAVAILABLE`, `DATABASE_ERROR`, `INVALID_CHARACTER_NAME`, `INVALID_SESSION_STATE`, `SESSION_NOT_FOUND`, `SESSION_PERSISTENCE_PENDING`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "dateOfBirth": {
      "maxLength": 10,
      "minLength": 10,
      "type": "string"
    },
    "firstName": {
      "maxLength": 64,
      "minLength": 1,
      "type": "string"
    },
    "lastName": {
      "maxLength": 64,
      "minLength": 1,
      "type": "string"
    },
    "sessionId": {
      "maxLength": 36,
      "type": "string"
    },
    "slot": {
      "maximum": 64,
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "sessionId",
    "slot",
    "firstName",
    "lastName"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "dateOfBirth": {
      "maxLength": 10,
      "type": "string"
    },
    "firstName": {
      "maxLength": 64,
      "type": "string"
    },
    "id": {
      "maxLength": 36,
      "type": "string"
    },
    "lastName": {
      "maxLength": 64,
      "type": "string"
    },
    "metadata": {
      "type": "object"
    },
    "slot": {
      "minimum": 1,
      "type": "integer"
    },
    "status": {
      "maxLength": 16,
      "type": "string"
    },
    "userId": {
      "maxLength": 36,
      "type": "string"
    },
    "version": {
      "minimum": 1,
      "type": "integer"
    }
  },
  "required": [
    "id",
    "userId",
    "slot",
    "status",
    "firstName",
    "lastName",
    "metadata",
    "version"
  ],
  "type": "object"
}
```

## `synex.identity.characters.delete`

- Version: `1.0.0`
- Provider: `synex_core`
- Idempotent: no
- Errors: `CAPABILITY_DENIED`, `CHARACTER_DELETE_BLOCKED`, `CHARACTER_DELETE_PREFLIGHT_FAILED`, `CHARACTER_NOT_FOUND`, `DATABASE_ERROR`, `INVALID_SESSION_STATE`, `SESSION_NOT_FOUND`, `SESSION_PERSISTENCE_PENDING`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "characterId": {
      "maxLength": 36,
      "type": "string"
    },
    "sessionId": {
      "maxLength": 36,
      "type": "string"
    }
  },
  "required": [
    "sessionId",
    "characterId"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "characterId": {
      "maxLength": 36,
      "type": "string"
    },
    "planId": {
      "maxLength": 36,
      "type": "string"
    },
    "state": {
      "enum": [
        "completed",
        "reconciling"
      ],
      "type": "string"
    }
  },
  "required": [
    "planId",
    "characterId",
    "state"
  ],
  "type": "object"
}
```

## `synex.identity.characters.list`

- Version: `1.0.0`
- Provider: `synex_core`
- Idempotent: yes
- Errors: `CAPABILITY_DENIED`, `DATABASE_ERROR`, `SESSION_NOT_FOUND`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "sessionId": {
      "maxLength": 36,
      "type": "string"
    }
  },
  "required": [
    "sessionId"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "characters": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "dateOfBirth": {
            "maxLength": 10,
            "type": "string"
          },
          "firstName": {
            "maxLength": 64,
            "type": "string"
          },
          "id": {
            "maxLength": 36,
            "type": "string"
          },
          "lastName": {
            "maxLength": 64,
            "type": "string"
          },
          "metadata": {
            "type": "object"
          },
          "slot": {
            "minimum": 1,
            "type": "integer"
          },
          "status": {
            "maxLength": 16,
            "type": "string"
          },
          "userId": {
            "maxLength": 36,
            "type": "string"
          },
          "version": {
            "minimum": 1,
            "type": "integer"
          }
        },
        "required": [
          "id",
          "userId",
          "slot",
          "status",
          "firstName",
          "lastName",
          "metadata",
          "version"
        ],
        "type": "object"
      },
      "maxItems": 64,
      "type": "array"
    }
  },
  "required": [
    "characters"
  ],
  "type": "object"
}
```

## `synex.identity.characters.select`

- Version: `1.0.0`
- Provider: `synex_core`
- Idempotent: no
- Errors: `CAPABILITY_DENIED`, `CHARACTER_ALREADY_ACTIVE`, `CHARACTER_LOAD_FAILED`, `CHARACTER_NOT_FOUND`, `INVALID_SESSION_STATE`, `SESSION_NOT_FOUND`, `SESSION_PERSISTENCE_PENDING`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "characterId": {
      "maxLength": 36,
      "type": "string"
    },
    "sessionId": {
      "maxLength": 36,
      "type": "string"
    }
  },
  "required": [
    "sessionId",
    "characterId"
  ],
  "type": "object"
}
```

### Output

```json
{
  "properties": {
    "character": {
      "type": "object"
    },
    "session": {
      "type": "object"
    }
  },
  "required": [
    "session",
    "character"
  ],
  "type": "object"
}
```

## `synex.identity.session.by_source`

- Version: `1.0.0`
- Provider: `synex_core`
- Idempotent: yes
- Errors: `CAPABILITY_DENIED`, `NOT_READY`

### Input

```json
{
  "additionalProperties": false,
  "properties": {
    "source": {
      "minimum": 0,
      "type": "integer"
    }
  },
  "required": [
    "source"
  ],
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "found": {
      "type": "boolean"
    },
    "session": {
      "additionalProperties": false,
      "properties": {
        "characterId": {
          "maxLength": 36,
          "type": "string"
        },
        "id": {
          "maxLength": 36,
          "type": "string"
        },
        "source": {
          "minimum": 0,
          "type": "integer"
        },
        "sourceGeneration": {
          "minimum": 1,
          "type": "integer"
        },
        "state": {
          "maxLength": 32,
          "type": "string"
        },
        "userId": {
          "maxLength": 36,
          "type": "string"
        },
        "version": {
          "minimum": 1,
          "type": "integer"
        }
      },
      "required": [
        "id",
        "userId",
        "state",
        "source",
        "sourceGeneration",
        "version"
      ],
      "type": "object"
    }
  },
  "required": [
    "found"
  ],
  "type": "object"
}
```

## `synex.runtime.status`

- Version: `1.0.0`
- Provider: `synex_core`
- Idempotent: yes
- Errors: `CAPABILITY_DENIED`, `NOT_READY`

### Input

```json
{
  "additionalProperties": false,
  "properties": {},
  "type": "object"
}
```

### Output

```json
{
  "additionalProperties": false,
  "properties": {
    "operational": {
      "type": "boolean"
    },
    "reasons": {
      "type": "object"
    },
    "recentTransitions": {
      "items": {
        "type": "object"
      },
      "maxItems": 64,
      "type": "array"
    },
    "revision": {
      "minimum": 0,
      "type": "integer"
    },
    "state": {
      "maxLength": 32,
      "type": "string"
    }
  },
  "required": [
    "state",
    "revision",
    "operational",
    "reasons",
    "recentTransitions"
  ],
  "type": "object"
}
```
