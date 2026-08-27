return {
  ["contracts"] = {
    {
      ["capability"] = "synex.accounts.access.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_CHECK_INVALID",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["permission"] = {
            ["enum"] = {
              "balance.read",
              "history.read",
              "deposit",
              "withdraw",
              "transfer",
              "hold.create",
              "hold.capture",
              "hold.release",
              "access.read",
              "access.manage",
              "settings.manage",
              "close"
            },
            ["type"] = "string"
          },
          ["principal_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["principal_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "principal_kind",
          "principal_ref",
          "permission",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.access.check",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["account_state"] = {
            ["enum"] = {
              "active",
              "frozen",
              "closed"
            },
            ["type"] = "string"
          },
          ["allowed"] = {
            ["type"] = "boolean"
          },
          ["available_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["booked_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["grant_active"] = {
            ["type"] = "boolean"
          },
          ["grant_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["grant_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["owner"] = {
            ["type"] = "boolean"
          },
          ["permission"] = {
            ["enum"] = {
              "balance.read",
              "history.read",
              "deposit",
              "withdraw",
              "transfer",
              "hold.create",
              "hold.capture",
              "hold.release",
              "access.read",
              "access.manage",
              "settings.manage",
              "close"
            },
            ["type"] = "string"
          },
          ["permission_granted"] = {
            ["type"] = "boolean"
          },
          ["principal_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["principal_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reserved_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["resource_capability"] = {
            ["type"] = "boolean"
          },
          ["role_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["role_key"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "principal_kind",
          "principal_ref",
          "permission",
          "account_state",
          "resource_capability",
          "owner",
          "grant_active",
          "permission_granted",
          "allowed",
          "reason",
          "booked_minor",
          "reserved_minor",
          "available_minor"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.access.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_CHECK_INVALID",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["direction"] = {
            ["enum"] = {
              "incoming",
              "outgoing"
            },
            ["type"] = "string"
          },
          ["operation"] = {
            ["enum"] = {
              "balance.read",
              "history.read",
              "deposit",
              "withdraw",
              "transfer",
              "post",
              "mint",
              "burn",
              "reversal",
              "refund",
              "hold.create",
              "hold.capture",
              "hold.release",
              "access.read",
              "access.manage",
              "settings.manage",
              "close"
            },
            ["type"] = "string"
          },
          ["permission"] = {
            ["enum"] = {
              "balance.read",
              "history.read",
              "deposit",
              "withdraw",
              "transfer",
              "hold.create",
              "hold.capture",
              "hold.release",
              "access.read",
              "access.manage",
              "settings.manage",
              "close"
            },
            ["type"] = "string"
          },
          ["principal_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["principal_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "principal_kind",
          "principal_ref",
          "permission",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.access.explain",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["account_state"] = {
            ["enum"] = {
              "active",
              "frozen",
              "closed"
            },
            ["type"] = "string"
          },
          ["allowed"] = {
            ["type"] = "boolean"
          },
          ["available_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["booked_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["grant_active"] = {
            ["type"] = "boolean"
          },
          ["grant_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["grant_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["owner"] = {
            ["type"] = "boolean"
          },
          ["permission"] = {
            ["enum"] = {
              "balance.read",
              "history.read",
              "deposit",
              "withdraw",
              "transfer",
              "hold.create",
              "hold.capture",
              "hold.release",
              "access.read",
              "access.manage",
              "settings.manage",
              "close"
            },
            ["type"] = "string"
          },
          ["permission_granted"] = {
            ["type"] = "boolean"
          },
          ["principal_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["principal_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reserved_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["resource_capability"] = {
            ["type"] = "boolean"
          },
          ["role_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["role_key"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "principal_kind",
          "principal_ref",
          "permission",
          "account_state",
          "resource_capability",
          "owner",
          "grant_active",
          "permission_granted",
          "allowed",
          "reason",
          "booked_minor",
          "reserved_minor",
          "available_minor"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.access.manage",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_CLOSED",
        "ACCESS_ROLE_NOT_FOUND",
        "ACCESS_GRANT_EXISTS",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["principal_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["principal_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["role_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["valid_for_seconds"] = {
            ["maximum"] = 31536000,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["valid_from_seconds"] = {
            ["maximum"] = 31536000,
            ["minimum"] = 0,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "role_id",
          "principal_kind",
          "principal_ref",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.access.grant",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["grant_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["principal_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["principal_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["role_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "revoked"
            },
            ["type"] = "string"
          },
          ["valid_for_seconds"] = {
            ["maximum"] = 31536000,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["valid_from_seconds"] = {
            ["maximum"] = 31536000,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "grant_id",
          "account_id",
          "role_id",
          "principal_kind",
          "principal_ref",
          "status",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.access.manage",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_CLOSED",
        "ACCESS_GRANT_NOT_FOUND",
        "ACCESS_GRANT_INACTIVE",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["grant_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "grant_id",
          "expected_version",
          "reason",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.access.revoke",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["grant_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["principal_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["principal_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["role_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "revoked"
            },
            ["type"] = "string"
          },
          ["valid_for_seconds"] = {
            ["maximum"] = 31536000,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["valid_from_seconds"] = {
            ["maximum"] = 31536000,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "grant_id",
          "account_id",
          "role_id",
          "principal_kind",
          "principal_ref",
          "status",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.access.manage",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_CLOSED",
        "ACCESS_ROLE_EXISTS",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["permissions"] = {
            ["items"] = {
              ["enum"] = {
                "balance.read",
                "history.read",
                "deposit",
                "withdraw",
                "transfer",
                "hold.create",
                "hold.capture",
                "hold.release",
                "access.read",
                "access.manage",
                "settings.manage",
                "close"
              },
              ["type"] = "string"
            },
            ["maxItems"] = 12,
            ["minItems"] = 1,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["role_key"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "role_key",
          "display_name",
          "permissions",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.access.role.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["permissions"] = {
            ["items"] = {
              ["enum"] = {
                "balance.read",
                "history.read",
                "deposit",
                "withdraw",
                "transfer",
                "hold.create",
                "hold.capture",
                "hold.release",
                "access.read",
                "access.manage",
                "settings.manage",
                "close"
              },
              ["type"] = "string"
            },
            ["maxItems"] = 12,
            ["minItems"] = 1,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["role_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["role_key"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "role_id",
          "account_id",
          "role_key",
          "display_name",
          "permissions",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.balance.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["account_key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["account_role"] = {
            ["enum"] = {
              "asset",
              "mint",
              "burn"
            },
            ["type"] = "string"
          },
          ["available_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["booked_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["minor_unit"] = {
            ["maximum"] = 6,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["owner_kind"] = {
            ["enum"] = {
              "system",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["owner_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reserved_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["sequence"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["snapshot_created_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "frozen",
              "closed"
            },
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
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
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "BALANCE_HISTORY_NOT_FOUND",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "at",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.balance.get_at",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["available_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["booked_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["reserved_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["sequence"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["snapshot_created_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "booked_minor",
          "reserved_minor",
          "available_minor",
          "sequence",
          "snapshot_created_at"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.burn",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_UNAVAILABLE",
        "CURRENCY_MISMATCH",
        "INVALID_LEDGER_ROLE",
        "INSUFFICIENT_FUNDS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["burn_account_id"] = {
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "burn_account_id",
          "amount_minor"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.burn",
      ["network"] = "none",
      ["output"] = {
        ["properties"] = {
          ["credit_minor"] = {
            ["type"] = "integer"
          },
          ["debit_minor"] = {
            ["type"] = "integer"
          },
          ["posting_id"] = {
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "transaction_id",
          "posting_id",
          "debit_minor",
          "credit_minor"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.burn",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_UNAVAILABLE",
        "ACCOUNT_RESTRICTED",
        "CURRENCY_UNAVAILABLE",
        "CURRENCY_TOPOLOGY_INVALID",
        "INSUFFICIENT_FUNDS",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "POLICY_VIOLATION",
        "AMOUNT_OUT_OF_RANGE",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED",
        "CURRENCY_DISABLED",
        "ACCOUNT_FROZEN",
        "ACCOUNT_CLOSED",
        "INVALID_AMOUNT"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "amount_minor",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.burn_v2",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cumulative_refunded_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["original_transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["posted_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["refund_amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["refund_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["refundable_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["reversal_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "posted"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["transaction_kind"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "transaction_id",
          "transaction_kind",
          "currency_code",
          "entry_count",
          "entries",
          "reason_code",
          "source_resource",
          "trace_id"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "2.0.0"
    },
    {
      ["capability"] = "synex.accounts.hold",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOLD_NOT_FOUND",
        "HOLD_EXPIRED",
        "HOLD_TERMINAL",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["hold_id"] = {
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "hold_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.capture_hold",
      ["network"] = "none",
      ["output"] = {
        ["properties"] = {
          ["amount_minor"] = {
            ["type"] = "integer"
          },
          ["credit_account_id"] = {
            ["type"] = "string"
          },
          ["debit_account_id"] = {
            ["type"] = "string"
          },
          ["hold_id"] = {
            ["type"] = "string"
          },
          ["posting_id"] = {
            ["type"] = "string"
          },
          ["state"] = {
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "hold_id",
          "state",
          "transaction_id",
          "posting_id",
          "debit_account_id",
          "credit_account_id",
          "amount_minor"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_STATE_INVALID",
        "ACCOUNT_BALANCE_NOT_ZERO",
        "ACCOUNT_HAS_ACTIVE_HOLDS",
        "ACCOUNT_LIFECYCLE_BLOCKED",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "expected_version",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.close",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["previous_status"] = {
            ["enum"] = {
              "active",
              "frozen",
              "closed"
            },
            ["type"] = "string"
          },
          ["status"] = {
            ["const"] = "closed"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 2,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "account_id",
          "previous_status",
          "status",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.create",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "CURRENCY_NOT_FOUND",
        "CURRENCY_UNAVAILABLE",
        "ACCOUNT_KEY_EXISTS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["account_role"] = {
            ["enum"] = {
              "asset",
              "mint",
              "burn"
            }
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["type"] = "string"
          },
          ["owner_kind"] = {
            ["enum"] = {
              "system",
              "user",
              "character",
              "group"
            }
          },
          ["owner_ref"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "currency_code",
          "account_role",
          "owner_kind",
          "owner_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["account_role"] = {
            ["type"] = "string"
          },
          ["available_minor"] = {
            ["const"] = 0
          },
          ["booked_minor"] = {
            ["const"] = 0
          },
          ["currency_code"] = {
            ["type"] = "string"
          },
          ["owner_kind"] = {
            ["type"] = "string"
          },
          ["owner_ref"] = {
            ["type"] = "string"
          },
          ["reserved_minor"] = {
            ["const"] = 0
          },
          ["sequence"] = {
            ["const"] = 0
          },
          ["status"] = {
            ["const"] = "active"
          }
        },
        ["required"] = {
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
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.access.manage",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_CLOSED",
        "ACCESS_ROLE_EXISTS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["permissions"] = {
            ["items"] = {
              ["enum"] = {
                "view",
                "deposit",
                "withdraw",
                "transfer",
                "history",
                "manage",
                "close"
              }
            },
            ["maxItems"] = 7,
            ["minItems"] = 1,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["role_key"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "role_key",
          "display_name",
          "permissions"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.create_access_role",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["display_name"] = {
            ["type"] = "string"
          },
          ["permissions"] = {
            ["items"] = {
              ["enum"] = {
                "view",
                "deposit",
                "withdraw",
                "transfer",
                "history",
                "manage",
                "close"
              }
            },
            ["maxItems"] = 7,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["role_id"] = {
            ["type"] = "string"
          },
          ["role_key"] = {
            ["type"] = "string"
          },
          ["version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "role_id",
          "account_id",
          "role_key",
          "display_name",
          "permissions",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.hold",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_UNAVAILABLE",
        "CURRENCY_MISMATCH",
        "INSUFFICIENT_FUNDS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["capture_account_id"] = {
            ["type"] = "string"
          },
          ["expires_in_seconds"] = {
            ["maximum"] = 604800,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "capture_account_id",
          "amount_minor",
          "expires_in_seconds"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.create_hold",
      ["network"] = "none",
      ["output"] = {
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["type"] = "integer"
          },
          ["capture_account_id"] = {
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["type"] = "string"
          },
          ["expires_in_seconds"] = {
            ["type"] = "integer"
          },
          ["hold_id"] = {
            ["type"] = "string"
          },
          ["state"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "hold_id",
          "account_id",
          "capture_account_id",
          "amount_minor",
          "currency_code",
          "state",
          "expires_in_seconds"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.transfer",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_UNAVAILABLE",
        "CURRENCY_MISMATCH",
        "INVALID_LEDGER_ROLE",
        "INSUFFICIENT_FUNDS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["counterparty_account_id"] = {
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "counterparty_account_id",
          "account_id",
          "amount_minor"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.credit",
      ["network"] = "none",
      ["output"] = {
        ["properties"] = {
          ["credit_minor"] = {
            ["type"] = "integer"
          },
          ["debit_minor"] = {
            ["type"] = "integer"
          },
          ["posting_id"] = {
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "transaction_id",
          "posting_id",
          "debit_minor",
          "credit_minor"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "CURRENCY_NOT_FOUND"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["currency"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "currency"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.currency.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["burn_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["currency_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["minor_unit"] = {
            ["maximum"] = 6,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["mint_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["precision_locked_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "disabled"
            },
            ["type"] = "string"
          },
          ["topology_state"] = {
            ["enum"] = {
              "incomplete",
              "ready"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "currency_id",
          "currency_code",
          "display_name",
          "minor_unit",
          "status",
          "topology_state"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 100,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {},
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.currency.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["burn_account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["currency_code"] = {
                  ["maxLength"] = 16,
                  ["minLength"] = 2,
                  ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
                  ["type"] = "string"
                },
                ["currency_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["display_name"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["minor_unit"] = {
                  ["maximum"] = 6,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["mint_account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["precision_locked_at"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "active",
                    "disabled"
                  },
                  ["type"] = "string"
                },
                ["topology_state"] = {
                  ["enum"] = {
                    "incomplete",
                    "ready"
                  },
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "currency_id",
                "currency_code",
                "display_name",
                "minor_unit",
                "status",
                "topology_state"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 100,
            ["minItems"] = 0,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "items"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "CURRENCY_EXISTS",
        "CONCURRENT_MODIFICATION"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["minor_unit"] = {
            ["maximum"] = 6,
            ["minimum"] = 0,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "currency_code",
          "display_name",
          "minor_unit"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.currency.register",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["burn_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["currency_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["minor_unit"] = {
            ["maximum"] = 6,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["mint_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["precision_locked_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "disabled"
            },
            ["type"] = "string"
          },
          ["topology_state"] = {
            ["enum"] = {
              "incomplete",
              "ready"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "currency_id",
          "currency_code",
          "display_name",
          "minor_unit",
          "status",
          "topology_state"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "CURRENCY_NOT_FOUND",
        "CURRENCY_PRECISION_LOCKED",
        "CONCURRENT_MODIFICATION"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["currency_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["minor_unit"] = {
            ["maximum"] = 6,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "disabled"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "currency_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.currency.update",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["burn_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["currency_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["minor_unit"] = {
            ["maximum"] = 6,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["mint_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["precision_locked_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "disabled"
            },
            ["type"] = "string"
          },
          ["topology_state"] = {
            ["enum"] = {
              "incomplete",
              "ready"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "currency_id",
          "currency_code",
          "display_name",
          "minor_unit",
          "status"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.transfer",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_UNAVAILABLE",
        "CURRENCY_MISMATCH",
        "INVALID_LEDGER_ROLE",
        "INSUFFICIENT_FUNDS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["counterparty_account_id"] = {
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "counterparty_account_id",
          "amount_minor"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.debit",
      ["network"] = "none",
      ["output"] = {
        ["properties"] = {
          ["credit_minor"] = {
            ["type"] = "integer"
          },
          ["debit_minor"] = {
            ["type"] = "integer"
          },
          ["posting_id"] = {
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "transaction_id",
          "posting_id",
          "debit_minor",
          "credit_minor"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_STATE_INVALID",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "expected_version",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.freeze",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["previous_status"] = {
            ["enum"] = {
              "active",
              "frozen",
              "closed"
            },
            ["type"] = "string"
          },
          ["status"] = {
            ["const"] = "frozen"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 2,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "account_id",
          "previous_status",
          "status",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["account_key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["account_role"] = {
            ["enum"] = {
              "asset",
              "mint",
              "burn"
            },
            ["type"] = "string"
          },
          ["available_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["booked_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["minor_unit"] = {
            ["maximum"] = 6,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["owner_kind"] = {
            ["enum"] = {
              "system",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["owner_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reserved_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["sequence"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["snapshot_created_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "frozen",
              "closed"
            },
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
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
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.access.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "ACCOUNT_NOT_FOUND",
        "DATABASE_ERROR"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["principal_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            }
          },
          ["principal_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "principal_kind",
          "principal_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.get_access",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["grant_id"] = {
            ["type"] = "string"
          },
          ["grant_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["granted"] = {
            ["type"] = "boolean"
          },
          ["permissions"] = {
            ["items"] = {
              ["enum"] = {
                "view",
                "deposit",
                "withdraw",
                "transfer",
                "history",
                "manage",
                "close"
              }
            },
            ["maxItems"] = 7,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["principal_kind"] = {
            ["type"] = "string"
          },
          ["principal_ref"] = {
            ["type"] = "string"
          },
          ["role_display_name"] = {
            ["type"] = "string"
          },
          ["role_id"] = {
            ["type"] = "string"
          },
          ["role_key"] = {
            ["type"] = "string"
          },
          ["valid_until"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "principal_kind",
          "principal_ref",
          "granted",
          "permissions"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "HOLD_NOT_FOUND",
        "DATABASE_ERROR"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["hold_id"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "hold_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.get_hold",
      ["network"] = "none",
      ["output"] = {
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["type"] = "integer"
          },
          ["capture_account_id"] = {
            ["type"] = "string"
          },
          ["created_at"] = {
            ["type"] = "string"
          },
          ["event_id"] = {
            ["type"] = "string"
          },
          ["event_occurred_at"] = {
            ["type"] = "string"
          },
          ["expires_at"] = {
            ["type"] = "string"
          },
          ["hold_id"] = {
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["type"] = "string"
          },
          ["state"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
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
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.integrity.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CURRENCY_NOT_FOUND",
        "DATABASE_ERROR"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "currency_code"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.get_integrity",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["currency_code"] = {
            ["type"] = "string"
          },
          ["currency_id"] = {
            ["type"] = "string"
          },
          ["cutoff_posting_id"] = {
            ["maxLength"] = 20,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["finding_count"] = {
            ["maximum"] = 5,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["findings"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["aggregate_id"] = {
                  ["maxLength"] = 128,
                  ["type"] = "string"
                },
                ["aggregate_type"] = {
                  ["maxLength"] = 32,
                  ["type"] = "string"
                },
                ["created_at"] = {
                  ["type"] = "string"
                },
                ["details_json"] = {
                  ["maxLength"] = 4096,
                  ["type"] = "string"
                },
                ["finding_id"] = {
                  ["type"] = "string"
                },
                ["rule"] = {
                  ["enum"] = {
                    "ledger_imbalance",
                    "snapshot_sum_drift",
                    "negative_asset_balance",
                    "reserved_exceeds_booked",
                    "orphan_transaction"
                  }
                },
                ["severity"] = {
                  ["const"] = "warn"
                }
              },
              ["required"] = {
                "finding_id",
                "rule",
                "severity",
                "details_json",
                "created_at"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["type"] = "array"
          },
          ["generated_at"] = {
            ["type"] = "string"
          },
          ["model_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["negative_asset_count"] = {
            ["maxLength"] = 20,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["orphan_transaction_count"] = {
            ["maxLength"] = 20,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["posting_count"] = {
            ["maxLength"] = 20,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reserved_exceeds_booked_count"] = {
            ["maxLength"] = 20,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "healthy",
              "warn"
            }
          },
          ["total_booked_minor"] = {
            ["maxLength"] = 38,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["total_credit_minor"] = {
            ["maxLength"] = 38,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["total_debit_minor"] = {
            ["maxLength"] = 38,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["transaction_count"] = {
            ["maxLength"] = 20,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
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
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "ACCOUNT_NOT_FOUND",
        "DATABASE_ERROR"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.get_snapshot",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["account_key"] = {
            ["type"] = "string"
          },
          ["account_role"] = {
            ["type"] = "string"
          },
          ["available_minor"] = {
            ["type"] = "integer"
          },
          ["booked_minor"] = {
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["type"] = "string"
          },
          ["minor_unit"] = {
            ["type"] = "integer"
          },
          ["owner_kind"] = {
            ["type"] = "string"
          },
          ["owner_ref"] = {
            ["type"] = "string"
          },
          ["reserved_minor"] = {
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["sequence"] = {
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["snapshot_created_at"] = {
            ["type"] = "string"
          },
          ["status"] = {
            ["type"] = "string"
          },
          ["version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
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
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.access.manage",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "ACCOUNT_CLOSED",
        "ACCESS_ROLE_NOT_FOUND",
        "ACCESS_GRANT_EXISTS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["principal_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            }
          },
          ["principal_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["role_id"] = {
            ["type"] = "string"
          },
          ["valid_for_seconds"] = {
            ["maximum"] = 31536000,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "role_id",
          "principal_kind",
          "principal_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.grant_access",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["grant_id"] = {
            ["type"] = "string"
          },
          ["principal_kind"] = {
            ["type"] = "string"
          },
          ["principal_ref"] = {
            ["type"] = "string"
          },
          ["role_id"] = {
            ["type"] = "string"
          },
          ["status"] = {
            ["const"] = "active"
          },
          ["valid_for_seconds"] = {
            ["maximum"] = 31536000,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "grant_id",
          "account_id",
          "role_id",
          "principal_kind",
          "principal_ref",
          "status",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.hold",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "HOLD_NOT_FOUND",
        "HOLD_EXPIRED",
        "HOLD_NOT_ACTIVE",
        "HOLD_CAPTURE_EXCEEDS_REMAINING",
        "PARTIAL_CAPTURE_NOT_ALLOWED",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_UNAVAILABLE",
        "ACCOUNT_RESTRICTED",
        "INSUFFICIENT_FUNDS",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED",
        "ACCOUNT_FROZEN",
        "ACCOUNT_CLOSED",
        "INVALID_AMOUNT",
        "HOLD_ALREADY_TERMINAL"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["expected_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["hold_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "hold_id",
          "expected_version",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.hold.capture",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["capture_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["capture_policy"] = {
            ["enum"] = {
              "single",
              "multiple"
            },
            ["type"] = "string"
          },
          ["captured_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["created_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["event_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["event_occurred_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["expires_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["expires_in_seconds"] = {
            ["maximum"] = 604800,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["hold_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["released_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["remaining_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["state"] = {
            ["enum"] = {
              "active",
              "partially_captured",
              "captured",
              "released",
              "expired"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["transaction_kind"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "hold_id",
          "transaction_id",
          "transaction_kind",
          "currency_code",
          "entry_count",
          "entries",
          "reason_code",
          "source_resource",
          "trace_id",
          "state",
          "captured_minor",
          "remaining_minor",
          "version",
          "event_id"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.hold",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_UNAVAILABLE",
        "ACCOUNT_RESTRICTED",
        "CURRENCY_MISMATCH",
        "INVALID_LEDGER_ROLE",
        "INSUFFICIENT_FUNDS",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED",
        "ACCOUNT_FROZEN",
        "ACCOUNT_CLOSED",
        "INVALID_AMOUNT"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["capture_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["capture_policy"] = {
            ["enum"] = {
              "single",
              "multiple"
            },
            ["type"] = "string"
          },
          ["expires_in_seconds"] = {
            ["maximum"] = 604800,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "capture_account_id",
          "amount_minor",
          "capture_policy",
          "expires_in_seconds",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.hold.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["capture_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["capture_policy"] = {
            ["enum"] = {
              "single",
              "multiple"
            },
            ["type"] = "string"
          },
          ["captured_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["created_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["event_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["event_occurred_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["expires_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["expires_in_seconds"] = {
            ["maximum"] = 604800,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["hold_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["released_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["remaining_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["state"] = {
            ["enum"] = {
              "active",
              "partially_captured",
              "captured",
              "released",
              "expired"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "hold_id",
          "account_id",
          "capture_account_id",
          "currency_code",
          "amount_minor",
          "captured_minor",
          "released_minor",
          "remaining_minor",
          "state",
          "capture_policy",
          "expires_in_seconds",
          "version",
          "event_id"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "HOLD_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["hold_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "hold_id",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.hold.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["capture_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["capture_policy"] = {
            ["enum"] = {
              "single",
              "multiple"
            },
            ["type"] = "string"
          },
          ["captured_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["created_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["event_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["event_occurred_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["expires_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["expires_in_seconds"] = {
            ["maximum"] = 604800,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["hold_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["released_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["remaining_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["state"] = {
            ["enum"] = {
              "active",
              "partially_captured",
              "captured",
              "released",
              "expired"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "hold_id",
          "account_id",
          "capture_account_id",
          "currency_code",
          "amount_minor",
          "captured_minor",
          "released_minor",
          "remaining_minor",
          "state",
          "capture_policy",
          "reason_code",
          "source_resource",
          "trace_id",
          "actor_kind",
          "actor_ref",
          "metadata_json",
          "expires_at",
          "created_at",
          "version",
          "event_id",
          "event_occurred_at"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.hold",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "HOLD_NOT_FOUND",
        "HOLD_EXPIRED",
        "HOLD_NOT_ACTIVE",
        "ACCOUNT_ACCESS_DENIED",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED",
        "HOLD_ALREADY_TERMINAL"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["hold_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "hold_id",
          "expected_version",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.hold.release",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["capture_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["capture_policy"] = {
            ["enum"] = {
              "single",
              "multiple"
            },
            ["type"] = "string"
          },
          ["captured_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["created_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["event_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["event_occurred_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["expires_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["expires_in_seconds"] = {
            ["maximum"] = 604800,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["hold_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["released_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["remaining_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["state"] = {
            ["enum"] = {
              "active",
              "partially_captured",
              "captured",
              "released",
              "expired"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "hold_id",
          "account_id",
          "state",
          "released_minor",
          "amount_minor",
          "remaining_minor",
          "version",
          "event_id"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.integrity.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "CURRENCY_NOT_FOUND",
        "INTEGRITY_MODEL_NOT_FOUND"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "currency_code"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.integrity.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["active_held_minor"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["burned_minor"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["completed_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["critical_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["currency_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["cutoff_entry_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["cutoff_transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["entry_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["error_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["finding_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["findings"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["aggregate_id"] = {
                  ["maxLength"] = 128,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["aggregate_type"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["created_at"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["details_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["finding_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["rule"] = {
                  ["maxLength"] = 96,
                  ["minLength"] = 3,
                  ["type"] = "string"
                },
                ["severity"] = {
                  ["enum"] = {
                    "info",
                    "warn",
                    "error",
                    "critical"
                  },
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "finding_id",
                "rule",
                "severity",
                "details_json",
                "created_at"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 50,
            ["minItems"] = 0,
            ["type"] = "array"
          },
          ["generated_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["grant_problem_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["idempotency_problem_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["info_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["invalid_hold_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["invalid_reversal_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["invalid_topology_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["minted_minor"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["model_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["negative_asset_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["net_supply_minor"] = {
            ["maxLength"] = 37,
            ["minLength"] = 1,
            ["pattern"] = "^-?[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["orphan_transaction_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["outbox_problem_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["refund_limit_violation_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["reserved_exceeds_booked_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["run_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["sequence_problem_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["snapshot_drift_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["started_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "healthy",
              "warn",
              "error",
              "critical",
              "failed"
            },
            ["type"] = "string"
          },
          ["total_booked_minor"] = {
            ["maxLength"] = 37,
            ["minLength"] = 1,
            ["pattern"] = "^-?[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["total_entry_sum_minor"] = {
            ["maxLength"] = 37,
            ["minLength"] = 1,
            ["pattern"] = "^-?[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["transaction_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["transaction_sum_violation_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["warn_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "currency_id",
          "currency_code",
          "model_version",
          "transaction_count",
          "entry_count",
          "account_count",
          "total_entry_sum_minor",
          "minted_minor",
          "burned_minor",
          "net_supply_minor",
          "total_booked_minor",
          "active_held_minor",
          "negative_asset_count",
          "orphan_transaction_count",
          "transaction_sum_violation_count",
          "snapshot_drift_count",
          "reserved_exceeds_booked_count",
          "invalid_hold_count",
          "refund_limit_violation_count",
          "invalid_reversal_count",
          "invalid_topology_count",
          "outbox_problem_count",
          "grant_problem_count",
          "sequence_problem_count",
          "idempotency_problem_count",
          "finding_count",
          "status",
          "generated_at",
          "findings"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.integrity.run",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "CURRENCY_NOT_FOUND",
        "RECONCILIATION_IN_PROGRESS",
        "INTEGRITY_VIOLATION",
        "CONCURRENT_MODIFICATION"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "currency_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.integrity.reconcile",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["active_held_minor"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["burned_minor"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["completed_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["critical_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["currency_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["cutoff_entry_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["cutoff_transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["entry_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["error_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["finding_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["findings"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["aggregate_id"] = {
                  ["maxLength"] = 128,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["aggregate_type"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["created_at"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["details_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["finding_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["rule"] = {
                  ["maxLength"] = 96,
                  ["minLength"] = 3,
                  ["type"] = "string"
                },
                ["severity"] = {
                  ["enum"] = {
                    "info",
                    "warn",
                    "error",
                    "critical"
                  },
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "finding_id",
                "rule",
                "severity",
                "details_json",
                "created_at"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 50,
            ["minItems"] = 0,
            ["type"] = "array"
          },
          ["generated_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["grant_problem_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["idempotency_problem_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["info_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["invalid_hold_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["invalid_reversal_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["invalid_topology_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["minted_minor"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["model_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["negative_asset_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["net_supply_minor"] = {
            ["maxLength"] = 37,
            ["minLength"] = 1,
            ["pattern"] = "^-?[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["orphan_transaction_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["outbox_problem_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["refund_limit_violation_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["reserved_exceeds_booked_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["run_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["sequence_problem_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["snapshot_drift_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["started_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "healthy",
              "warn",
              "error",
              "critical",
              "failed"
            },
            ["type"] = "string"
          },
          ["total_booked_minor"] = {
            ["maxLength"] = 37,
            ["minLength"] = 1,
            ["pattern"] = "^-?[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["total_entry_sum_minor"] = {
            ["maxLength"] = 37,
            ["minLength"] = 1,
            ["pattern"] = "^-?[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["transaction_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["transaction_sum_violation_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          },
          ["warn_count"] = {
            ["maxLength"] = 36,
            ["minLength"] = 1,
            ["pattern"] = "^[0-9]{1,36}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "run_id",
          "currency_id",
          "currency_code",
          "model_version",
          "transaction_count",
          "entry_count",
          "account_count",
          "total_entry_sum_minor",
          "minted_minor",
          "burned_minor",
          "net_supply_minor",
          "total_booked_minor",
          "active_held_minor",
          "negative_asset_count",
          "orphan_transaction_count",
          "transaction_sum_violation_count",
          "snapshot_drift_count",
          "reserved_exceeds_booked_count",
          "invalid_hold_count",
          "refund_limit_violation_count",
          "invalid_reversal_count",
          "invalid_topology_count",
          "outbox_problem_count",
          "grant_problem_count",
          "sequence_problem_count",
          "idempotency_problem_count",
          "finding_count",
          "status",
          "generated_at",
          "findings"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 50,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["owner_kind"] = {
            ["enum"] = {
              "system",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["owner_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "owner_kind",
          "owner_ref",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.list_by_owner",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["account_key"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 3,
                  ["type"] = "string"
                },
                ["account_role"] = {
                  ["enum"] = {
                    "asset",
                    "mint",
                    "burn"
                  },
                  ["type"] = "string"
                },
                ["available_minor"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = -9007199254740991,
                  ["type"] = "integer"
                },
                ["booked_minor"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = -9007199254740991,
                  ["type"] = "integer"
                },
                ["currency_code"] = {
                  ["maxLength"] = 16,
                  ["minLength"] = 2,
                  ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
                  ["type"] = "string"
                },
                ["minor_unit"] = {
                  ["maximum"] = 6,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["owner_kind"] = {
                  ["enum"] = {
                    "system",
                    "user",
                    "character",
                    "group"
                  },
                  ["type"] = "string"
                },
                ["owner_ref"] = {
                  ["maxLength"] = 128,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["reserved_minor"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["sequence"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["snapshot_created_at"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "active",
                    "frozen",
                    "closed"
                  },
                  ["type"] = "string"
                },
                ["version"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
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
              },
              ["type"] = "object"
            },
            ["maxItems"] = 50,
            ["minItems"] = 0,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "items"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.mint",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_UNAVAILABLE",
        "CURRENCY_MISMATCH",
        "INVALID_LEDGER_ROLE",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["type"] = "string"
          },
          ["mint_account_id"] = {
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "mint_account_id",
          "account_id",
          "amount_minor"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.mint",
      ["network"] = "none",
      ["output"] = {
        ["properties"] = {
          ["credit_minor"] = {
            ["type"] = "integer"
          },
          ["debit_minor"] = {
            ["type"] = "integer"
          },
          ["posting_id"] = {
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "transaction_id",
          "posting_id",
          "debit_minor",
          "credit_minor"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.mint",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_UNAVAILABLE",
        "ACCOUNT_RESTRICTED",
        "CURRENCY_UNAVAILABLE",
        "CURRENCY_TOPOLOGY_INVALID",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "POLICY_VIOLATION",
        "AMOUNT_OUT_OF_RANGE",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED",
        "CURRENCY_DISABLED",
        "ACCOUNT_FROZEN",
        "ACCOUNT_CLOSED",
        "INVALID_AMOUNT"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "amount_minor",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.mint_v2",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cumulative_refunded_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["original_transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["posted_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["refund_amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["refund_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["refundable_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["reversal_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "posted"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["transaction_kind"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "transaction_id",
          "transaction_kind",
          "currency_code",
          "entry_count",
          "entries",
          "reason_code",
          "source_resource",
          "trace_id"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "2.0.0"
    },
    {
      ["capability"] = "synex.accounts.outbox.retry",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "OUTBOX_RETRY_UNAVAILABLE",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "OUTBOX_RETRY_REJECTED",
        "OUTBOX_EVENT_NOT_FOUND",
        "OUTBOX_EVENT_NOT_RETRYABLE",
        "OUTBOX_RETRY_FAILED",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["event_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "event_id",
          "reason",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.outbox.retry",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["accepted"] = {
            ["const"] = true,
            ["type"] = "boolean"
          },
          ["event_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["retry_request_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "retry_request_id",
          "event_id",
          "accepted",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.policy.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["allowed_operations"] = {
            ["items"] = {
              ["enum"] = {
                "post",
                "deposit",
                "withdraw",
                "transfer",
                "mint",
                "burn",
                "reversal",
                "refund",
                "hold.create",
                "hold.capture",
                "hold.release"
              },
              ["type"] = "string"
            },
            ["maxItems"] = 11,
            ["minItems"] = 0,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["daily_outgoing_limit_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["maximum_balance_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["minimum_balance_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["operation_mode"] = {
            ["enum"] = {
              "all",
              "allowlist"
            },
            ["type"] = "string"
          },
          ["single_transfer_limit_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "account_id",
          "operation_mode",
          "allowed_operations",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_CLOSED",
        "POLICY_INVALID",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["allowed_operations"] = {
            ["items"] = {
              ["enum"] = {
                "post",
                "deposit",
                "withdraw",
                "transfer",
                "mint",
                "burn",
                "reversal",
                "refund",
                "hold.create",
                "hold.capture",
                "hold.release"
              },
              ["type"] = "string"
            },
            ["maxItems"] = 11,
            ["minItems"] = 0,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["daily_outgoing_limit_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["expected_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["maximum_balance_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["minimum_balance_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["operation_mode"] = {
            ["enum"] = {
              "all",
              "allowlist"
            },
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["single_transfer_limit_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "expected_version",
          "operation_mode",
          "allowed_operations",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.policy.set",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["allowed_operations"] = {
            ["items"] = {
              ["enum"] = {
                "post",
                "deposit",
                "withdraw",
                "transfer",
                "mint",
                "burn",
                "reversal",
                "refund",
                "hold.create",
                "hold.capture",
                "hold.release"
              },
              ["type"] = "string"
            },
            ["maxItems"] = 11,
            ["minItems"] = 0,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["daily_outgoing_limit_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["maximum_balance_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["minimum_balance_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = -9007199254740991,
            ["type"] = "integer"
          },
          ["operation_mode"] = {
            ["enum"] = {
              "all",
              "allowlist"
            },
            ["type"] = "string"
          },
          ["single_transfer_limit_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "account_id",
          "operation_mode",
          "allowed_operations",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.post",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "TRANSACTION_UNBALANCED",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_UNAVAILABLE",
        "ACCOUNT_RESTRICTED",
        "CURRENCY_MISMATCH",
        "CURRENCY_UNAVAILABLE",
        "INVALID_LEDGER_ROLE",
        "INSUFFICIENT_FUNDS",
        "POLICY_VIOLATION",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "REFUND_ANCHOR_INVALID",
        "AMOUNT_OUT_OF_RANGE",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED",
        "CURRENCY_DISABLED",
        "ACCOUNT_FROZEN",
        "ACCOUNT_CLOSED",
        "INVALID_AMOUNT"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["postings"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "account_id",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["refund_anchor_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["refundable_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "currency_code",
          "postings",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.post",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cumulative_refunded_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["original_transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["posted_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["refund_amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["refund_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["refundable_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["reversal_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "posted"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["transaction_kind"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "transaction_id",
          "transaction_kind",
          "currency_code",
          "entry_count",
          "entries",
          "reason_code",
          "source_resource",
          "trace_id"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "REASON_CODE_NOT_FOUND"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "reason_code"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.reason.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["created_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["description"] = {
            ["maxLength"] = 512,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["owner_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "deprecated"
            },
            ["type"] = "string"
          },
          ["updated_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "reason_code",
          "owner_resource",
          "display_name",
          "status"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cursor"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 100,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["owner_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "owner_resource"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.reason.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["created_at"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["description"] = {
                  ["maxLength"] = 512,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["display_name"] = {
                  ["maxLength"] = 96,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["owner_resource"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["reason_code"] = {
                  ["maxLength"] = 96,
                  ["minLength"] = 3,
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "active",
                    "deprecated"
                  },
                  ["type"] = "string"
                },
                ["updated_at"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "reason_code",
                "owner_resource",
                "display_name",
                "status"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 100,
            ["minItems"] = 0,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "items"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "REASON_CODE_NAMESPACE_INVALID",
        "REASON_CODE_EXISTS",
        "CONCURRENT_MODIFICATION"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["description"] = {
            ["maxLength"] = 512,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "reason_code",
          "display_name"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.reason.register",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["created_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["description"] = {
            ["maxLength"] = 512,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["owner_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "deprecated"
            },
            ["type"] = "string"
          },
          ["updated_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "reason_code",
          "owner_resource",
          "display_name",
          "status"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "CURRENCY_EXISTS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["display_name"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["pattern"] = "^[0-9a-f-]{36}$",
            ["type"] = "string"
          },
          ["minor_unit"] = {
            ["maximum"] = 6,
            ["minimum"] = 0,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "currency_code",
          "display_name",
          "minor_unit"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.register_currency",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["currency_code"] = {
            ["type"] = "string"
          },
          ["currency_id"] = {
            ["type"] = "string"
          },
          ["display_name"] = {
            ["type"] = "string"
          },
          ["minor_unit"] = {
            ["type"] = "integer"
          },
          ["status"] = {
            ["const"] = "active"
          }
        },
        ["required"] = {
          "currency_id",
          "currency_code",
          "display_name",
          "minor_unit",
          "status"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.hold",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOLD_NOT_FOUND",
        "HOLD_TERMINAL",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["hold_id"] = {
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "hold_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.release_hold",
      ["network"] = "none",
      ["output"] = {
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["type"] = "integer"
          },
          ["hold_id"] = {
            ["type"] = "string"
          },
          ["state"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "hold_id",
          "state",
          "account_id",
          "amount_minor"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_CLOSED",
        "ACCOUNT_RESTRICTION_EXISTS",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reason_text"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["restriction_kind"] = {
            ["enum"] = {
              "outgoing_blocked",
              "incoming_blocked",
              "all_blocked"
            },
            ["type"] = "string"
          },
          ["valid_for_seconds"] = {
            ["maximum"] = 31536000,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["valid_from_seconds"] = {
            ["maximum"] = 31536000,
            ["minimum"] = 0,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "restriction_kind",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.restriction.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reason_text"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["restriction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["restriction_kind"] = {
            ["enum"] = {
              "outgoing_blocked",
              "incoming_blocked",
              "all_blocked"
            },
            ["type"] = "string"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "revoked",
              "expired"
            },
            ["type"] = "string"
          },
          ["terminal_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["termination_reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["valid_from"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["valid_until"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "restriction_id",
          "account_id",
          "restriction_kind",
          "status",
          "reason_code",
          "source_resource",
          "valid_from",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "ACCOUNT_RESTRICTION_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["restriction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "restriction_id",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.restriction.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reason_text"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["restriction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["restriction_kind"] = {
            ["enum"] = {
              "outgoing_blocked",
              "incoming_blocked",
              "all_blocked"
            },
            ["type"] = "string"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "revoked",
              "expired"
            },
            ["type"] = "string"
          },
          ["terminal_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["termination_reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["valid_from"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["valid_until"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "restriction_id",
          "account_id",
          "restriction_kind",
          "status",
          "reason_code",
          "source_resource",
          "valid_from",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 50,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "revoked",
              "expired"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.restriction.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["actor_kind"] = {
                  ["enum"] = {
                    "system",
                    "resource",
                    "user",
                    "character",
                    "group"
                  },
                  ["type"] = "string"
                },
                ["actor_ref"] = {
                  ["maxLength"] = 128,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["reason_code"] = {
                  ["maxLength"] = 96,
                  ["minLength"] = 3,
                  ["type"] = "string"
                },
                ["reason_text"] = {
                  ["maxLength"] = 256,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["restriction_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["restriction_kind"] = {
                  ["enum"] = {
                    "outgoing_blocked",
                    "incoming_blocked",
                    "all_blocked"
                  },
                  ["type"] = "string"
                },
                ["source_resource"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "active",
                    "revoked",
                    "expired"
                  },
                  ["type"] = "string"
                },
                ["terminal_at"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["termination_reason"] = {
                  ["maxLength"] = 256,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["trace_id"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 8,
                  ["type"] = "string"
                },
                ["valid_from"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["valid_until"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["version"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "restriction_id",
                "account_id",
                "restriction_kind",
                "status",
                "reason_code",
                "source_resource",
                "valid_from",
                "version"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 50,
            ["minItems"] = 0,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "items"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_CLOSED",
        "ACCOUNT_RESTRICTION_NOT_FOUND",
        "ACCOUNT_RESTRICTION_INACTIVE",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["restriction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["termination_reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "restriction_id",
          "expected_version",
          "reason_code",
          "termination_reason",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.restriction.revoke",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reason_text"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["restriction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["restriction_kind"] = {
            ["enum"] = {
              "outgoing_blocked",
              "incoming_blocked",
              "all_blocked"
            },
            ["type"] = "string"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "revoked",
              "expired"
            },
            ["type"] = "string"
          },
          ["terminal_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["termination_reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["valid_from"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["valid_until"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "restriction_id",
          "account_id",
          "restriction_kind",
          "status",
          "reason_code",
          "source_resource",
          "valid_from",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.reverse",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "TRANSACTION_NOT_FOUND",
        "TRANSACTION_ALREADY_REVERSED",
        "REVERSAL_NOT_REVERSIBLE",
        "ACCOUNT_UNAVAILABLE",
        "INSUFFICIENT_FUNDS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["pattern"] = "^[0-9a-f-]{36}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["pattern"] = "^[0-9a-f-]{36}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "transaction_id",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.reverse",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["credit_account_id"] = {
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["type"] = "string"
          },
          ["debit_account_id"] = {
            ["type"] = "string"
          },
          ["original_transaction_id"] = {
            ["type"] = "string"
          },
          ["posting_id"] = {
            ["type"] = "string"
          },
          ["reversal_id"] = {
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "reversal_id",
          "original_transaction_id",
          "transaction_id",
          "posting_id",
          "debit_account_id",
          "credit_account_id",
          "amount_minor",
          "currency_code"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.access.manage",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "ACCOUNT_CLOSED",
        "ACCESS_GRANT_NOT_FOUND",
        "ACCESS_GRANT_REVOKED",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["grant_id"] = {
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "grant_id",
          "reason",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.revoke_access",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["type"] = "string"
          },
          ["grant_id"] = {
            ["type"] = "string"
          },
          ["principal_kind"] = {
            ["type"] = "string"
          },
          ["principal_ref"] = {
            ["type"] = "string"
          },
          ["role_id"] = {
            ["type"] = "string"
          },
          ["status"] = {
            ["const"] = "revoked"
          },
          ["version"] = {
            ["minimum"] = 2,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "grant_id",
          "account_id",
          "role_id",
          "principal_kind",
          "principal_ref",
          "status",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.integrity.run",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "CURRENCY_NOT_FOUND",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "currency_code"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.run_reconciliation",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["currency_code"] = {
            ["type"] = "string"
          },
          ["currency_id"] = {
            ["type"] = "string"
          },
          ["cutoff_posting_id"] = {
            ["maxLength"] = 20,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["finding_count"] = {
            ["maximum"] = 5,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["findings"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["rule"] = {
                  ["enum"] = {
                    "ledger_imbalance",
                    "snapshot_sum_drift",
                    "negative_asset_balance",
                    "reserved_exceeds_booked",
                    "orphan_transaction"
                  }
                },
                ["severity"] = {
                  ["const"] = "warn"
                }
              },
              ["required"] = {
                "rule",
                "severity"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 5,
            ["type"] = "array"
          },
          ["model_version"] = {
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["posting_count"] = {
            ["maxLength"] = 20,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["run_id"] = {
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "healthy",
              "warn"
            }
          },
          ["total_booked_minor"] = {
            ["maxLength"] = 38,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["total_credit_minor"] = {
            ["maxLength"] = 38,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["total_debit_minor"] = {
            ["maxLength"] = 38,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["transaction_count"] = {
            ["maxLength"] = 20,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
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
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "TRANSACTION_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "transaction_id",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.transaction.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["cumulative_refunded_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["original_transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["posted_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["refund_amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["refund_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["refundable_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["reversal_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "posted"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["transaction_kind"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "transaction_id",
          "currency_code",
          "transaction_kind",
          "reason_code",
          "source_resource",
          "trace_id",
          "status",
          "posted_at",
          "entry_count",
          "entries"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.read",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCESS_DENIED"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 50,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "account_id",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.transaction.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["currency_code"] = {
                  ["maxLength"] = 16,
                  ["minLength"] = 2,
                  ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
                  ["type"] = "string"
                },
                ["entry_count"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 2,
                  ["type"] = "integer"
                },
                ["posted_at"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["reason_code"] = {
                  ["maxLength"] = 96,
                  ["minLength"] = 3,
                  ["type"] = "string"
                },
                ["reference_id"] = {
                  ["maxLength"] = 128,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["reference_type"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["source_resource"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "posted"
                  },
                  ["type"] = "string"
                },
                ["trace_id"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 8,
                  ["type"] = "string"
                },
                ["transaction_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["transaction_kind"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 2,
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "transaction_id",
                "currency_code",
                "transaction_kind",
                "reason_code",
                "source_resource",
                "trace_id",
                "status",
                "posted_at",
                "entry_count"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 50,
            ["minItems"] = 0,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "items"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.refund",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "TRANSACTION_NOT_FOUND",
        "TRANSACTION_NOT_REFUNDABLE",
        "REFUND_LIMIT_EXCEEDED",
        "REFUND_ANCHOR_INVALID",
        "TRANSACTION_UNBALANCED",
        "ACCOUNT_ACCESS_DENIED",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED",
        "INVALID_AMOUNT",
        "REFUND_EXCEEDS_REMAINING"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["expected_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["postings"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "account_id",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "transaction_id",
          "amount_minor",
          "postings",
          "expected_version",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.transaction.refund",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cumulative_refunded_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["original_transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["posted_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["refund_amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["refund_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["refundable_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["reversal_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "posted"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["transaction_kind"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "refund_id",
          "original_transaction_id",
          "transaction_id",
          "transaction_kind",
          "currency_code",
          "entry_count",
          "entries",
          "reason_code",
          "source_resource",
          "trace_id",
          "refund_amount_minor",
          "cumulative_refunded_minor",
          "refundable_minor"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.reverse",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "TRANSACTION_NOT_FOUND",
        "TRANSACTION_NOT_POSTED",
        "TRANSACTION_ALREADY_REVERSED",
        "REVERSAL_OF_REVERSAL",
        "ACCOUNT_ACCESS_DENIED",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED",
        "REVERSAL_NOT_ALLOWED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "transaction_id",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.transaction.reverse",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cumulative_refunded_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["original_transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["posted_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["refund_amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["refund_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["refundable_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["reversal_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "posted"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["transaction_kind"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "reversal_id",
          "original_transaction_id",
          "transaction_id",
          "transaction_kind",
          "currency_code",
          "entry_count",
          "entries",
          "reason_code",
          "source_resource",
          "trace_id"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.transfer",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_UNAVAILABLE",
        "CURRENCY_MISMATCH",
        "INVALID_LEDGER_ROLE",
        "INSUFFICIENT_FUNDS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["destination_account_id"] = {
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["source_account_id"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "source_account_id",
          "destination_account_id",
          "amount_minor"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.transfer",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["credit_account_id"] = {
            ["type"] = "string"
          },
          ["credit_minor"] = {
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["type"] = "string"
          },
          ["debit_account_id"] = {
            ["type"] = "string"
          },
          ["debit_minor"] = {
            ["type"] = "integer"
          },
          ["posting_id"] = {
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["type"] = "string"
          },
          ["transaction_kind"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "transaction_id",
          "posting_id",
          "transaction_kind",
          "debit_account_id",
          "credit_account_id",
          "debit_minor",
          "credit_minor",
          "currency_code"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.accounts.transfer",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_UNAVAILABLE",
        "ACCOUNT_RESTRICTED",
        "CURRENCY_MISMATCH",
        "CURRENCY_UNAVAILABLE",
        "INVALID_LEDGER_ROLE",
        "INSUFFICIENT_FUNDS",
        "POLICY_VIOLATION",
        "REASON_CODE_NOT_FOUND",
        "REASON_CODE_NOT_OWNED",
        "AMOUNT_OUT_OF_RANGE",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED",
        "CURRENCY_DISABLED",
        "ACCOUNT_FROZEN",
        "ACCOUNT_CLOSED",
        "INVALID_AMOUNT"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["destination_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["expected_destination_sequence"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["expected_source_sequence"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["refundable_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["source_account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "source_account_id",
          "destination_account_id",
          "amount_minor",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.transfer_v2",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cumulative_refunded_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["currency_code"] = {
            ["maxLength"] = 16,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]{1,15}$",
            ["type"] = "string"
          },
          ["entries"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["account_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["amount_minor"] = {
                  ["oneOf"] = {
                    {
                      ["maximum"] = -1,
                      ["minimum"] = -9007199254740991,
                      ["type"] = "integer"
                    },
                    {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  }
                },
                ["entry_id"] = {
                  ["maxLength"] = 36,
                  ["minLength"] = 36,
                  ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                  ["type"] = "string"
                },
                ["metadata_json"] = {
                  ["maxLength"] = 4096,
                  ["minLength"] = 2,
                  ["type"] = "string"
                },
                ["sequence"] = {
                  ["maximum"] = 16,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "entry_id",
                "account_id",
                "sequence",
                "amount_minor"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["minItems"] = 2,
            ["type"] = "array"
          },
          ["entry_count"] = {
            ["maximum"] = 16,
            ["minimum"] = 2,
            ["type"] = "integer"
          },
          ["original_transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["posted_at"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["refund_amount_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["refund_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["refundable_minor"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["reversal_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["source_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "posted"
            },
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["transaction_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["transaction_kind"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "transaction_id",
          "transaction_kind",
          "currency_code",
          "entry_count",
          "entries",
          "reason_code",
          "source_resource",
          "trace_id"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "2.0.0"
    },
    {
      ["capability"] = "synex.accounts.configure",
      ["domain"] = "synex.accounts",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CALLER_CONTEXT_INVALID",
        "PRINCIPAL_SPOOFED",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "WRITE_CONFLICT",
        "DATABASE_ERROR",
        "ACCOUNT_NOT_FOUND",
        "ACCOUNT_ACCESS_DENIED",
        "ACCOUNT_STATE_INVALID",
        "STALE_VERSION",
        "CONCURRENT_MODIFICATION",
        "ACCESS_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["actor_kind"] = {
            ["enum"] = {
              "system",
              "resource",
              "user",
              "character",
              "group"
            },
            ["type"] = "string"
          },
          ["actor_ref"] = {
            ["maxLength"] = 128,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["metadata_json"] = {
            ["maxLength"] = 4096,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reason_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["reference_id"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reference_type"] = {
            ["maxLength"] = 48,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "account_id",
          "expected_version",
          "reason_code",
          "actor_kind",
          "actor_ref"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.accounts.unfreeze",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["account_id"] = {
            ["maxLength"] = 36,
            ["minLength"] = 36,
            ["pattern"] = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            ["type"] = "string"
          },
          ["previous_status"] = {
            ["enum"] = {
              "active",
              "frozen",
              "closed"
            },
            ["type"] = "string"
          },
          ["status"] = {
            ["const"] = "active"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 2,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "account_id",
          "previous_status",
          "status",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_accounts",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.archetype.register",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "ARCHETYPE_CONFLICT",
        "ARCHETYPE_SCHEMA_INVALID"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["allowedModels"] = {
            ["items"] = {
              ["maximum"] = 4294967295,
              ["minimum"] = 0,
              ["type"] = "integer"
            },
            ["maxItems"] = 32,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["componentSchemas"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["namespace"] = {
                  ["maxLength"] = 128,
                  ["minLength"] = 3,
                  ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                  ["type"] = "string"
                },
                ["schemaVersion"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "namespace",
                "schemaVersion"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["defaultTags"] = {
            ["items"] = {
              ["maxLength"] = 128,
              ["minLength"] = 3,
              ["pattern"] = "^[a-z][a-z0-9_.-]+$",
              ["type"] = "string"
            },
            ["maxItems"] = 16,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["descriptorJson"] = {
            ["maxLength"] = 16384,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["entityType"] = {
            ["enum"] = {
              "vehicle",
              "ped",
              "object"
            }
          },
          ["name"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["persistencePolicy"] = {
            ["enum"] = {
              "temporary",
              "persistent",
              "session",
              "owner_lifetime"
            }
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["recoveryPolicy"] = {
            ["enum"] = {
              "none",
              "manual",
              "on_demand",
              "automatic"
            }
          },
          ["spawnDefaults"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["doorFlag"] = {
                ["type"] = "boolean"
              },
              ["heading"] = {
                ["maximum"] = 360,
                ["minimum"] = -360,
                ["type"] = "number"
              },
              ["model"] = {
                ["maximum"] = 4294967295,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["pedType"] = {
                ["maximum"] = 29,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["timeoutMs"] = {
                ["maximum"] = 10000,
                ["minimum"] = 250,
                ["type"] = "integer"
              },
              ["vehicleType"] = {
                ["enum"] = {
                  "automobile",
                  "bike",
                  "boat",
                  "heli",
                  "plane",
                  "submarine",
                  "trailer"
                }
              }
            },
            ["required"] = {
              "model"
            },
            ["type"] = "object"
          },
          ["stateSchemas"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["key"] = {
                  ["maxLength"] = 128,
                  ["minLength"] = 3,
                  ["pattern"] = "^[a-z][a-z0-9_.:%-]+$",
                  ["type"] = "string"
                },
                ["schemaVersion"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "key",
                "schemaVersion"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "name",
          "version",
          "entityType",
          "allowedModels",
          "persistencePolicy",
          "recoveryPolicy",
          "spawnDefaults",
          "defaultTags",
          "componentSchemas",
          "stateSchemas",
          "descriptorJson",
          "reasonCode"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.archetype.register",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["name"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["ownerResource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 7,
            ["pattern"] = "^synex_[a-z0-9_]+$",
            ["type"] = "string"
          },
          ["registered"] = {
            ["const"] = true
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "name",
          "version",
          "ownerResource",
          "registered"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 8,
        ["refillPerSecond"] = 1
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.query",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "BINDING_NOT_FOUND"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["binding"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["namespace"] = {
                ["maxLength"] = 128,
                ["minLength"] = 3,
                ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                ["type"] = "string"
              },
              ["ref"] = {
                ["maxLength"] = 128,
                ["minLength"] = 1,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              }
            },
            ["required"] = {
              "namespace",
              "ref"
            },
            ["type"] = "object"
          }
        },
        ["required"] = {
          "binding"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.binding.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["binding"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["namespace"] = {
                ["maxLength"] = 128,
                ["minLength"] = 3,
                ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                ["type"] = "string"
              },
              ["ref"] = {
                ["maxLength"] = 128,
                ["minLength"] = 1,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              }
            },
            ["required"] = {
              "namespace",
              "ref"
            },
            ["type"] = "object"
          },
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["binding"] = {
                ["additionalProperties"] = false,
                ["properties"] = {
                  ["namespace"] = {
                    ["maxLength"] = 128,
                    ["minLength"] = 3,
                    ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                    ["type"] = "string"
                  },
                  ["ref"] = {
                    ["maxLength"] = 128,
                    ["minLength"] = 1,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  }
                },
                ["required"] = {
                  "namespace",
                  "ref"
                },
                ["type"] = "object"
              },
              ["bucket"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["entityType"] = {
                ["enum"] = {
                  "vehicle",
                  "ped",
                  "object"
                }
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["materialized"] = {
                ["type"] = "boolean"
              },
              ["model"] = {
                ["maximum"] = 4294967295,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["netId"] = {
                ["maximum"] = 65535,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["networkOwner"] = {
                ["maximum"] = 65535,
                ["minimum"] = -1,
                ["type"] = "integer"
              },
              ["owner"] = {
                ["additionalProperties"] = false,
                ["properties"] = {
                  ["id"] = {
                    ["maxLength"] = 128,
                    ["minLength"] = 1,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  },
                  ["type"] = {
                    ["enum"] = {
                      "character",
                      "group",
                      "resource",
                      "system",
                      "user"
                    }
                  }
                },
                ["required"] = {
                  "type",
                  "id"
                },
                ["type"] = "object"
              },
              ["persistent"] = {
                ["type"] = "boolean"
              },
              ["resourceOwner"] = {
                ["maxLength"] = 64,
                ["minLength"] = 7,
                ["pattern"] = "^synex_[a-z0-9_]+$",
                ["type"] = "string"
              },
              ["status"] = {
                ["enum"] = {
                  "DEFINED",
                  "SPAWNING",
                  "ACTIVE",
                  "ORPHANED",
                  "RECOVERING",
                  "DORMANT",
                  "DELETING",
                  "DELETED",
                  "FAILED"
                }
              }
            },
            ["required"] = {
              "entityId",
              "generation",
              "entityType",
              "model",
              "bucket",
              "persistent",
              "materialized",
              "owner",
              "resourceOwner",
              "status"
            },
            ["type"] = "object"
          },
          ["materialized"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "binding",
          "materialized"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 60,
        ["refillPerSecond"] = 20
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.bucket.create",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INVALID_ARGUMENT",
        "RATE_LIMITED",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = false,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["purpose"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.bucket.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["generation"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["lockdown"] = {
            ["const"] = "strict"
          },
          ["populationEnabled"] = {
            ["const"] = false
          }
        },
        ["required"] = {
          "bucket",
          "generation",
          "lockdown",
          "populationEnabled"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 8,
        ["refillPerSecond"] = 1
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.bucket.create",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "BUCKET_CAPACITY_EXCEEDED",
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "RATE_LIMITED",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = false,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["capacity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["maxEntities"] = {
                ["maximum"] = 10000,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["maxPlayers"] = {
                ["maximum"] = 2048,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "maxPlayers",
              "maxEntities"
            },
            ["type"] = "object"
          },
          ["expiresAt"] = {
            ["maxLength"] = 20,
            ["minLength"] = 20,
            ["pattern"] = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$",
            ["type"] = "string"
          },
          ["lockdown"] = {
            ["enum"] = {
              "strict",
              "relaxed",
              "inactive"
            }
          },
          ["populationEnabled"] = {
            ["type"] = "boolean"
          },
          ["profile"] = {
            ["enum"] = {
              "isolated_strict",
              "session",
              "character_selection",
              "custom"
            }
          },
          ["purpose"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "profile",
          "purpose"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.bucket.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["bucket"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["generation"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              }
            },
            ["required"] = {
              "bucket",
              "generation"
            },
            ["type"] = "object"
          },
          ["capacity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["maxEntities"] = {
                ["maximum"] = 10000,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["maxPlayers"] = {
                ["maximum"] = 2048,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "maxPlayers",
              "maxEntities"
            },
            ["type"] = "object"
          },
          ["createdAt"] = {
            ["maxLength"] = 32,
            ["minLength"] = 20,
            ["type"] = "string"
          },
          ["entities"] = {
            ["maximum"] = 10000,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["expiresAt"] = {
            ["maxLength"] = 20,
            ["minLength"] = 20,
            ["type"] = "string"
          },
          ["health"] = {
            ["enum"] = {
              "READY",
              "DEGRADED",
              "UNHEALTHY"
            }
          },
          ["lockdown"] = {
            ["enum"] = {
              "strict",
              "relaxed",
              "inactive"
            }
          },
          ["ownerResource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 7,
            ["pattern"] = "^synex_[a-z0-9_]+$",
            ["type"] = "string"
          },
          ["players"] = {
            ["maximum"] = 2048,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["populationEnabled"] = {
            ["type"] = "boolean"
          },
          ["profile"] = {
            ["enum"] = {
              "isolated_strict",
              "session",
              "character_selection",
              "custom"
            }
          },
          ["purpose"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "bucket",
          "ownerResource",
          "purpose",
          "profile",
          "lockdown",
          "populationEnabled",
          "capacity",
          "players",
          "entities",
          "createdAt",
          "health"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 8,
        ["refillPerSecond"] = 1
      },
      ["stability"] = "experimental",
      ["version"] = "2.0.0"
    },
    {
      ["capability"] = "synex.entities.bucket.destroy",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "BUCKET_NOT_FOUND",
        "CONFLICT",
        "FORBIDDEN",
        "FOREIGN_BUCKET",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_BUCKET",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["generation"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "bucket",
          "generation"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.bucket.destroy",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["type"] = "integer"
          },
          ["destroyed"] = {
            ["const"] = true
          }
        },
        ["required"] = {
          "bucket",
          "destroyed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 12,
        ["refillPerSecond"] = 3
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.bucket.read",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "BUCKET_NOT_FOUND",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "STALE_BUCKET"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["bucket"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["generation"] = {
                ["oneOf"] = {
                  {
                    ["const"] = 0
                  },
                  {
                    ["maxLength"] = 64,
                    ["minLength"] = 8,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  }
                }
              }
            },
            ["required"] = {
              "bucket",
              "generation"
            },
            ["type"] = "object"
          }
        },
        ["required"] = {
          "bucket"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.bucket.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["bucket"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["generation"] = {
                ["oneOf"] = {
                  {
                    ["const"] = 0
                  },
                  {
                    ["maxLength"] = 64,
                    ["minLength"] = 8,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  }
                }
              }
            },
            ["required"] = {
              "bucket",
              "generation"
            },
            ["type"] = "object"
          },
          ["capacity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["maxEntities"] = {
                ["maximum"] = 10000,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["maxPlayers"] = {
                ["maximum"] = 2048,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "maxPlayers",
              "maxEntities"
            },
            ["type"] = "object"
          },
          ["createdAt"] = {
            ["maxLength"] = 32,
            ["minLength"] = 20,
            ["type"] = "string"
          },
          ["entities"] = {
            ["maximum"] = 10000,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["expiresAt"] = {
            ["maxLength"] = 32,
            ["minLength"] = 20,
            ["type"] = "string"
          },
          ["health"] = {
            ["enum"] = {
              "READY",
              "DEGRADED",
              "UNHEALTHY"
            }
          },
          ["lockdown"] = {
            ["enum"] = {
              "strict",
              "relaxed",
              "inactive"
            }
          },
          ["ownerResource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 7,
            ["pattern"] = "^synex_[a-z0-9_]+$",
            ["type"] = "string"
          },
          ["players"] = {
            ["maximum"] = 2048,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["populationEnabled"] = {
            ["type"] = "boolean"
          },
          ["profile"] = {
            ["enum"] = {
              "isolated_strict",
              "session",
              "character_selection",
              "custom"
            }
          },
          ["purpose"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "bucket",
          "ownerResource",
          "purpose",
          "profile",
          "lockdown",
          "populationEnabled",
          "capacity",
          "players",
          "entities",
          "createdAt",
          "health"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 60,
        ["refillPerSecond"] = 20
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.bucket.entity.move",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "BUCKET_NOT_FOUND",
        "CONFLICT",
        "FORBIDDEN",
        "FOREIGN_BUCKET",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_BUCKET",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["bucketGeneration"] = {
            ["oneOf"] = {
              {
                ["const"] = 0
              },
              {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              }
            }
          },
          ["entityId"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["generation"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entityId",
          "generation",
          "bucket",
          "bucketGeneration"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.bucket.move_entity",
      ["network"] = "none",
      ["output"] = {
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 30,
        ["refillPerSecond"] = 10
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.bucket.player.move",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "BUCKET_NOT_FOUND",
        "CONFLICT",
        "FORBIDDEN",
        "FOREIGN_BUCKET",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_BUCKET",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["bucketGeneration"] = {
            ["oneOf"] = {
              {
                ["const"] = 0
              },
              {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              }
            }
          },
          ["source"] = {
            ["maximum"] = 65535,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "source",
          "bucket",
          "bucketGeneration"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.bucket.move_player",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["type"] = "integer"
          },
          ["source"] = {
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "source",
          "bucket"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 30,
        ["refillPerSecond"] = 10
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.checkpoint",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "AUTHORITY_LEASE_CONFLICT",
        "CONCURRENT_MODIFICATION",
        "ENTITY_NOT_MATERIALIZED",
        "HOOK_REJECTED",
        "INVALID_POSITION"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["expectedVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotencyKey"] = {
            ["maxLength"] = 36,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "entity",
          "reasonCode",
          "idempotencyKey"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.checkpoint",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["checkpointId"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["checkpointedAt"] = {
            ["maxLength"] = 32,
            ["minLength"] = 20,
            ["type"] = "string"
          },
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity",
          "checkpointId",
          "version",
          "checkpointedAt"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 20,
        ["refillPerSecond"] = 5
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.component.read",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "COMPONENT_NOT_FOUND",
        "COMPONENT_SCHEMA_NOT_FOUND"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["namespace"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "entity",
          "namespace"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.component.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["namespace"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["payloadJson"] = {
            ["maxLength"] = 16384,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["persistenceMode"] = {
            ["enum"] = {
              "runtime",
              "persistent",
              "replicated"
            }
          },
          ["schemaVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity",
          "namespace",
          "schemaVersion",
          "persistenceMode",
          "payloadJson",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 60,
        ["refillPerSecond"] = 20
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.component.write",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "AUTHORITY_LEASE_CONFLICT",
        "COMPONENT_NOT_FOUND",
        "COMPONENT_OWNERSHIP_DENIED",
        "COMPONENT_SCHEMA_NOT_FOUND",
        "CONCURRENT_MODIFICATION",
        "ENTITY_NOT_FOUND"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["expectedVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotencyKey"] = {
            ["maxLength"] = 36,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["namespace"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "entity",
          "namespace",
          "expectedVersion",
          "reasonCode",
          "idempotencyKey"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.component.remove",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["namespace"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["removed"] = {
            ["const"] = true
          }
        },
        ["required"] = {
          "entity",
          "namespace",
          "removed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 30,
        ["refillPerSecond"] = 10
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.component.schema.register",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "COMPONENT_SCHEMA_INVALID",
        "SCHEMA_VERSION_CONFLICT"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["maximumBytes"] = {
            ["maximum"] = 16384,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["maximumDepth"] = {
            ["maximum"] = 16,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["namespace"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["persistenceMode"] = {
            ["enum"] = {
              "runtime",
              "persistent",
              "replicated"
            }
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["schemaJson"] = {
            ["maxLength"] = 16384,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["schemaVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "namespace",
          "schemaVersion",
          "persistenceMode",
          "maximumBytes",
          "maximumDepth",
          "schemaJson",
          "reasonCode"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.component.schema.register",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["namespace"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["ownerResource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 7,
            ["pattern"] = "^synex_[a-z0-9_]+$",
            ["type"] = "string"
          },
          ["registered"] = {
            ["const"] = true
          },
          ["schemaVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "namespace",
          "schemaVersion",
          "ownerResource",
          "registered"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 8,
        ["refillPerSecond"] = 1
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.component.write",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "AUTHORITY_LEASE_CONFLICT",
        "COMPONENT_OWNERSHIP_DENIED",
        "CONCURRENT_MODIFICATION",
        "COMPONENT_SCHEMA_MISMATCH",
        "COMPONENT_SCHEMA_NOT_FOUND",
        "ENTITY_NOT_FOUND",
        "ENTITY_QUOTA_EXCEEDED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["expectedVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["idempotencyKey"] = {
            ["maxLength"] = 36,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["namespace"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["payloadJson"] = {
            ["maxLength"] = 16384,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["schemaVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity",
          "namespace",
          "schemaVersion",
          "payloadJson",
          "expectedVersion",
          "reasonCode",
          "idempotencyKey"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.component.set",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["namespace"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["schemaVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["stored"] = {
            ["const"] = true
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity",
          "namespace",
          "schemaVersion",
          "version",
          "stored"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 30,
        ["refillPerSecond"] = 10
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.context.validate",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "BUCKET_MISMATCH",
        "DISTANCE_INVALID",
        "ENTITY_NOT_MATERIALIZED",
        "INTERACTION_CONTEXT_INVALID"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["requirements"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["components"] = {
                ["items"] = {
                  ["maxLength"] = 128,
                  ["minLength"] = 3,
                  ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                  ["type"] = "string"
                },
                ["maxItems"] = 16,
                ["type"] = "array",
                ["uniqueItems"] = true
              },
              ["maxDistance"] = {
                ["exclusiveMinimum"] = 0,
                ["maximum"] = 100,
                ["type"] = "number"
              },
              ["owner"] = {
                ["additionalProperties"] = false,
                ["properties"] = {
                  ["id"] = {
                    ["maxLength"] = 128,
                    ["minLength"] = 1,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  },
                  ["type"] = {
                    ["enum"] = {
                      "character",
                      "group",
                      "resource",
                      "system",
                      "user"
                    }
                  }
                },
                ["required"] = {
                  "type",
                  "id"
                },
                ["type"] = "object"
              },
              ["sameBucket"] = {
                ["type"] = "boolean"
              },
              ["tags"] = {
                ["items"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 3,
                  ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                  ["type"] = "string"
                },
                ["maxItems"] = 16,
                ["type"] = "array",
                ["uniqueItems"] = true
              }
            },
            ["required"] = {
              "sameBucket",
              "maxDistance"
            },
            ["type"] = "object"
          },
          ["source"] = {
            ["maximum"] = 65535,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "source",
          "entity",
          "requirements"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.context.validate",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["bucket"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["generation"] = {
                ["oneOf"] = {
                  {
                    ["const"] = 0
                  },
                  {
                    ["maxLength"] = 64,
                    ["minLength"] = 8,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  }
                }
              }
            },
            ["required"] = {
              "bucket",
              "generation"
            },
            ["type"] = "object"
          },
          ["distance"] = {
            ["maximum"] = 100,
            ["minimum"] = 0,
            ["type"] = "number"
          },
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["matchedComponents"] = {
            ["items"] = {
              ["maxLength"] = 128,
              ["minLength"] = 3,
              ["pattern"] = "^[a-z][a-z0-9_.-]+$",
              ["type"] = "string"
            },
            ["maxItems"] = 16,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["matchedTags"] = {
            ["items"] = {
              ["maxLength"] = 64,
              ["minLength"] = 3,
              ["pattern"] = "^[a-z][a-z0-9_.-]+$",
              ["type"] = "string"
            },
            ["maxItems"] = 16,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["valid"] = {
            ["const"] = true
          }
        },
        ["required"] = {
          "valid",
          "entity",
          "bucket",
          "distance"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 60,
        ["refillPerSecond"] = 20
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.delete",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "AUTHORITY_LEASE_CONFLICT",
        "CONCURRENT_MODIFICATION",
        "CONFLICT",
        "DELETE_FAILED",
        "ENTITY_NOT_FOUND",
        "FORBIDDEN",
        "HOOK_REJECTED",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entityId"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["generation"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entityId",
          "generation"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.delete",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["deleted"] = {
            ["const"] = true
          },
          ["entityId"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "entityId",
          "deleted"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 24,
        ["refillPerSecond"] = 8
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.dematerialize",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "AUTHORITY_LEASE_CONFLICT",
        "CONCURRENT_MODIFICATION",
        "DELETE_FAILED",
        "ENTITY_NOT_MATERIALIZED",
        "HOOK_REJECTED",
        "INVALID_POSITION"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["idempotencyKey"] = {
            ["maxLength"] = 36,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["policy"] = {
            ["enum"] = {
              "checkpoint",
              "retain_runtime_state",
              "discard_runtime_state"
            }
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "entity",
          "policy",
          "reasonCode",
          "idempotencyKey"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.dematerialize",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["checkpointId"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["dematerialized"] = {
            ["const"] = true
          },
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["status"] = {
            ["const"] = "DORMANT"
          }
        },
        ["required"] = {
          "entity",
          "dematerialized",
          "status"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 16,
        ["refillPerSecond"] = 4
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.read",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "FORBIDDEN",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entityId"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["generation"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entityId",
          "generation"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.get",
      ["network"] = "none",
      ["output"] = {
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 60,
        ["refillPerSecond"] = 20
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.read",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "FORBIDDEN",
        "RATE_LIMITED",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.health",
      ["network"] = "none",
      ["output"] = {
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 30,
        ["refillPerSecond"] = 10
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.materialize",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "BUCKET_NOT_FOUND",
        "CONFLICT",
        "FORBIDDEN",
        "FOREIGN_BUCKET",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "ARCHETYPE_NOT_FOUND",
        "BINDING_CONFLICT",
        "COMPONENT_SCHEMA_MISMATCH",
        "COMPONENT_SCHEMA_NOT_FOUND",
        "CONCURRENT_MODIFICATION",
        "ENTITY_ALREADY_MATERIALIZED",
        "ENTITY_NOT_FOUND",
        "AUTHORITY_LEASE_CONFLICT",
        "ENTITY_QUOTA_EXCEEDED",
        "FOREIGN_RESOURCE_OWNER",
        "HOOK_REJECTED",
        "INVALID_ENTITY_TYPE",
        "INVALID_MODEL",
        "INVALID_POSITION",
        "SPAWN_FAILED",
        "SPAWN_RATE_LIMITED",
        "SPAWN_TIMEOUT",
        "STATE_SCHEMA_MISMATCH",
        "STATE_SCHEMA_NOT_FOUND",
        "STALE_BUCKET"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["idempotencyKey"] = {
            ["maxLength"] = 36,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["spawnContext"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["bucket"] = {
                ["additionalProperties"] = false,
                ["properties"] = {
                  ["bucket"] = {
                    ["maximum"] = 2147483647,
                    ["minimum"] = 0,
                    ["type"] = "integer"
                  },
                  ["generation"] = {
                    ["oneOf"] = {
                      {
                        ["const"] = 0
                      },
                      {
                        ["maxLength"] = 64,
                        ["minLength"] = 8,
                        ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                        ["type"] = "string"
                      }
                    }
                  }
                },
                ["required"] = {
                  "bucket",
                  "generation"
                },
                ["type"] = "object"
              },
              ["recoveryMode"] = {
                ["enum"] = {
                  "manual",
                  "on_demand",
                  "automatic",
                  "handoff"
                }
              }
            },
            ["required"] = {
              "bucket"
            },
            ["type"] = "object"
          },
          ["target"] = {
            ["oneOf"] = {
              {
                ["additionalProperties"] = false,
                ["properties"] = {
                  ["entityId"] = {
                    ["maxLength"] = 64,
                    ["minLength"] = 8,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  }
                },
                ["required"] = {
                  "entityId"
                },
                ["type"] = "object"
              },
              {
                ["additionalProperties"] = false,
                ["properties"] = {
                  ["binding"] = {
                    ["additionalProperties"] = false,
                    ["properties"] = {
                      ["namespace"] = {
                        ["maxLength"] = 128,
                        ["minLength"] = 3,
                        ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                        ["type"] = "string"
                      },
                      ["ref"] = {
                        ["maxLength"] = 128,
                        ["minLength"] = 1,
                        ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                        ["type"] = "string"
                      }
                    },
                    ["required"] = {
                      "namespace",
                      "ref"
                    },
                    ["type"] = "object"
                  }
                },
                ["required"] = {
                  "binding"
                },
                ["type"] = "object"
              }
            }
          }
        },
        ["required"] = {
          "target",
          "spawnContext",
          "reasonCode",
          "idempotencyKey"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.materialize",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["materialized"] = {
            ["const"] = true
          },
          ["netId"] = {
            ["maximum"] = 65535,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["networkOwner"] = {
            ["maximum"] = 65535,
            ["minimum"] = -1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity",
          "netId",
          "materialized"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 12,
        ["refillPerSecond"] = 3
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.owner.change",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "AUTHORITY_LEASE_CONFLICT",
        "CONCURRENT_MODIFICATION",
        "FOREIGN_RESOURCE_OWNER",
        "HOOK_REJECTED",
        "INVALID_LOGICAL_OWNER",
        "OWNER_POLICY_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["expectedVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotencyKey"] = {
            ["maxLength"] = 36,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["owner"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["id"] = {
                ["maxLength"] = 128,
                ["minLength"] = 1,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["type"] = {
                ["enum"] = {
                  "character",
                  "group",
                  "resource",
                  "system",
                  "user"
                }
              }
            },
            ["required"] = {
              "type",
              "id"
            },
            ["type"] = "object"
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "entity",
          "owner",
          "expectedVersion",
          "reasonCode",
          "idempotencyKey"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.owner.set",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["changed"] = {
            ["const"] = true
          },
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["owner"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["id"] = {
                ["maxLength"] = 128,
                ["minLength"] = 1,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["type"] = {
                ["enum"] = {
                  "character",
                  "group",
                  "resource",
                  "system",
                  "user"
                }
              }
            },
            ["required"] = {
              "type",
              "id"
            },
            ["type"] = "object"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity",
          "owner",
          "version",
          "changed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 20,
        ["refillPerSecond"] = 5
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.query",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "BINDING_NOT_FOUND"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["binding"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["namespace"] = {
                ["maxLength"] = 128,
                ["minLength"] = 3,
                ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                ["type"] = "string"
              },
              ["ref"] = {
                ["maxLength"] = 128,
                ["minLength"] = 1,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              }
            },
            ["required"] = {
              "namespace",
              "ref"
            },
            ["type"] = "object"
          }
        },
        ["required"] = {
          "binding"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.query.by_binding",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["binding"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["namespace"] = {
                ["maxLength"] = 128,
                ["minLength"] = 3,
                ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                ["type"] = "string"
              },
              ["ref"] = {
                ["maxLength"] = 128,
                ["minLength"] = 1,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              }
            },
            ["required"] = {
              "namespace",
              "ref"
            },
            ["type"] = "object"
          },
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["binding"] = {
                ["additionalProperties"] = false,
                ["properties"] = {
                  ["namespace"] = {
                    ["maxLength"] = 128,
                    ["minLength"] = 3,
                    ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                    ["type"] = "string"
                  },
                  ["ref"] = {
                    ["maxLength"] = 128,
                    ["minLength"] = 1,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  }
                },
                ["required"] = {
                  "namespace",
                  "ref"
                },
                ["type"] = "object"
              },
              ["bucket"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["entityType"] = {
                ["enum"] = {
                  "vehicle",
                  "ped",
                  "object"
                }
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["materialized"] = {
                ["type"] = "boolean"
              },
              ["model"] = {
                ["maximum"] = 4294967295,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["netId"] = {
                ["maximum"] = 65535,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["networkOwner"] = {
                ["maximum"] = 65535,
                ["minimum"] = -1,
                ["type"] = "integer"
              },
              ["owner"] = {
                ["additionalProperties"] = false,
                ["properties"] = {
                  ["id"] = {
                    ["maxLength"] = 128,
                    ["minLength"] = 1,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  },
                  ["type"] = {
                    ["enum"] = {
                      "character",
                      "group",
                      "resource",
                      "system",
                      "user"
                    }
                  }
                },
                ["required"] = {
                  "type",
                  "id"
                },
                ["type"] = "object"
              },
              ["persistent"] = {
                ["type"] = "boolean"
              },
              ["resourceOwner"] = {
                ["maxLength"] = 64,
                ["minLength"] = 7,
                ["pattern"] = "^synex_[a-z0-9_]+$",
                ["type"] = "string"
              },
              ["status"] = {
                ["enum"] = {
                  "DEFINED",
                  "SPAWNING",
                  "ACTIVE",
                  "ORPHANED",
                  "RECOVERING",
                  "DORMANT",
                  "DELETING",
                  "DELETED",
                  "FAILED"
                }
              }
            },
            ["required"] = {
              "entityId",
              "generation",
              "entityType",
              "model",
              "bucket",
              "persistent",
              "materialized",
              "owner",
              "resourceOwner",
              "status"
            },
            ["type"] = "object"
          }
        },
        ["required"] = {
          "binding",
          "entity"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 60,
        ["refillPerSecond"] = 20
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.query",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "BUCKET_NOT_FOUND",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "STALE_BUCKET"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["bucket"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["generation"] = {
                ["oneOf"] = {
                  {
                    ["const"] = 0
                  },
                  {
                    ["maxLength"] = 64,
                    ["minLength"] = 8,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  }
                }
              }
            },
            ["required"] = {
              "bucket",
              "generation"
            },
            ["type"] = "object"
          },
          ["cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["filters"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["archetype"] = {
                ["maxLength"] = 128,
                ["minLength"] = 3,
                ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                ["type"] = "string"
              },
              ["entityTypes"] = {
                ["items"] = {
                  ["enum"] = {
                    "vehicle",
                    "ped",
                    "object"
                  }
                },
                ["maxItems"] = 3,
                ["type"] = "array",
                ["uniqueItems"] = true
              },
              ["materialized"] = {
                ["type"] = "boolean"
              },
              ["persistent"] = {
                ["type"] = "boolean"
              },
              ["tags"] = {
                ["items"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 3,
                  ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                  ["type"] = "string"
                },
                ["maxItems"] = 16,
                ["type"] = "array",
                ["uniqueItems"] = true
              }
            },
            ["type"] = "object"
          },
          ["limit"] = {
            ["maximum"] = 64,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "bucket",
          "limit"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.query.by_bucket",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["binding"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["namespace"] = {
                      ["maxLength"] = 128,
                      ["minLength"] = 3,
                      ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                      ["type"] = "string"
                    },
                    ["ref"] = {
                      ["maxLength"] = 128,
                      ["minLength"] = 1,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    }
                  },
                  ["required"] = {
                    "namespace",
                    "ref"
                  },
                  ["type"] = "object"
                },
                ["bucket"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["entityId"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["entityType"] = {
                  ["enum"] = {
                    "vehicle",
                    "ped",
                    "object"
                  }
                },
                ["generation"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["materialized"] = {
                  ["type"] = "boolean"
                },
                ["model"] = {
                  ["maximum"] = 4294967295,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["netId"] = {
                  ["maximum"] = 65535,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["networkOwner"] = {
                  ["maximum"] = 65535,
                  ["minimum"] = -1,
                  ["type"] = "integer"
                },
                ["owner"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["id"] = {
                      ["maxLength"] = 128,
                      ["minLength"] = 1,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["type"] = {
                      ["enum"] = {
                        "character",
                        "group",
                        "resource",
                        "system",
                        "user"
                      }
                    }
                  },
                  ["required"] = {
                    "type",
                    "id"
                  },
                  ["type"] = "object"
                },
                ["persistent"] = {
                  ["type"] = "boolean"
                },
                ["resourceOwner"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 7,
                  ["pattern"] = "^synex_[a-z0-9_]+$",
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "DEFINED",
                    "SPAWNING",
                    "ACTIVE",
                    "ORPHANED",
                    "RECOVERING",
                    "DORMANT",
                    "DELETING",
                    "DELETED",
                    "FAILED"
                  }
                }
              },
              ["required"] = {
                "entityId",
                "generation",
                "entityType",
                "model",
                "bucket",
                "persistent",
                "materialized",
                "owner",
                "resourceOwner",
                "status"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 64,
            ["type"] = "array"
          },
          ["nextCursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 60,
        ["refillPerSecond"] = 20
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.query",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["netId"] = {
            ["maximum"] = 65535,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "netId"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.query.by_net_id",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["binding"] = {
                ["additionalProperties"] = false,
                ["properties"] = {
                  ["namespace"] = {
                    ["maxLength"] = 128,
                    ["minLength"] = 3,
                    ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                    ["type"] = "string"
                  },
                  ["ref"] = {
                    ["maxLength"] = 128,
                    ["minLength"] = 1,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  }
                },
                ["required"] = {
                  "namespace",
                  "ref"
                },
                ["type"] = "object"
              },
              ["bucket"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["entityType"] = {
                ["enum"] = {
                  "vehicle",
                  "ped",
                  "object"
                }
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["materialized"] = {
                ["type"] = "boolean"
              },
              ["model"] = {
                ["maximum"] = 4294967295,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["netId"] = {
                ["maximum"] = 65535,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["networkOwner"] = {
                ["maximum"] = 65535,
                ["minimum"] = -1,
                ["type"] = "integer"
              },
              ["owner"] = {
                ["additionalProperties"] = false,
                ["properties"] = {
                  ["id"] = {
                    ["maxLength"] = 128,
                    ["minLength"] = 1,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  },
                  ["type"] = {
                    ["enum"] = {
                      "character",
                      "group",
                      "resource",
                      "system",
                      "user"
                    }
                  }
                },
                ["required"] = {
                  "type",
                  "id"
                },
                ["type"] = "object"
              },
              ["persistent"] = {
                ["type"] = "boolean"
              },
              ["resourceOwner"] = {
                ["maxLength"] = 64,
                ["minLength"] = 7,
                ["pattern"] = "^synex_[a-z0-9_]+$",
                ["type"] = "string"
              },
              ["status"] = {
                ["enum"] = {
                  "DEFINED",
                  "SPAWNING",
                  "ACTIVE",
                  "ORPHANED",
                  "RECOVERING",
                  "DORMANT",
                  "DELETING",
                  "DELETED",
                  "FAILED"
                }
              }
            },
            ["required"] = {
              "entityId",
              "generation",
              "entityType",
              "model",
              "bucket",
              "persistent",
              "materialized",
              "owner",
              "resourceOwner",
              "status"
            },
            ["type"] = "object"
          }
        },
        ["required"] = {
          "entity"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 80,
        ["refillPerSecond"] = 25
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.query",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["filters"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["archetype"] = {
                ["maxLength"] = 128,
                ["minLength"] = 3,
                ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                ["type"] = "string"
              },
              ["entityTypes"] = {
                ["items"] = {
                  ["enum"] = {
                    "vehicle",
                    "ped",
                    "object"
                  }
                },
                ["maxItems"] = 3,
                ["type"] = "array",
                ["uniqueItems"] = true
              },
              ["materialized"] = {
                ["type"] = "boolean"
              },
              ["persistent"] = {
                ["type"] = "boolean"
              },
              ["tags"] = {
                ["items"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 3,
                  ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                  ["type"] = "string"
                },
                ["maxItems"] = 16,
                ["type"] = "array",
                ["uniqueItems"] = true
              }
            },
            ["type"] = "object"
          },
          ["limit"] = {
            ["maximum"] = 64,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["owner"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["id"] = {
                ["maxLength"] = 128,
                ["minLength"] = 1,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["type"] = {
                ["enum"] = {
                  "character",
                  "group",
                  "resource",
                  "system",
                  "user"
                }
              }
            },
            ["required"] = {
              "type",
              "id"
            },
            ["type"] = "object"
          }
        },
        ["required"] = {
          "owner",
          "limit"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.query.by_owner",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["binding"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["namespace"] = {
                      ["maxLength"] = 128,
                      ["minLength"] = 3,
                      ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                      ["type"] = "string"
                    },
                    ["ref"] = {
                      ["maxLength"] = 128,
                      ["minLength"] = 1,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    }
                  },
                  ["required"] = {
                    "namespace",
                    "ref"
                  },
                  ["type"] = "object"
                },
                ["bucket"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["entityId"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["entityType"] = {
                  ["enum"] = {
                    "vehicle",
                    "ped",
                    "object"
                  }
                },
                ["generation"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["materialized"] = {
                  ["type"] = "boolean"
                },
                ["model"] = {
                  ["maximum"] = 4294967295,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["netId"] = {
                  ["maximum"] = 65535,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["networkOwner"] = {
                  ["maximum"] = 65535,
                  ["minimum"] = -1,
                  ["type"] = "integer"
                },
                ["owner"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["id"] = {
                      ["maxLength"] = 128,
                      ["minLength"] = 1,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["type"] = {
                      ["enum"] = {
                        "character",
                        "group",
                        "resource",
                        "system",
                        "user"
                      }
                    }
                  },
                  ["required"] = {
                    "type",
                    "id"
                  },
                  ["type"] = "object"
                },
                ["persistent"] = {
                  ["type"] = "boolean"
                },
                ["resourceOwner"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 7,
                  ["pattern"] = "^synex_[a-z0-9_]+$",
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "DEFINED",
                    "SPAWNING",
                    "ACTIVE",
                    "ORPHANED",
                    "RECOVERING",
                    "DORMANT",
                    "DELETING",
                    "DELETED",
                    "FAILED"
                  }
                }
              },
              ["required"] = {
                "entityId",
                "generation",
                "entityType",
                "model",
                "bucket",
                "persistent",
                "materialized",
                "owner",
                "resourceOwner",
                "status"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 64,
            ["type"] = "array"
          },
          ["nextCursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 60,
        ["refillPerSecond"] = 20
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.query",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["filters"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["archetype"] = {
                ["maxLength"] = 128,
                ["minLength"] = 3,
                ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                ["type"] = "string"
              },
              ["entityTypes"] = {
                ["items"] = {
                  ["enum"] = {
                    "vehicle",
                    "ped",
                    "object"
                  }
                },
                ["maxItems"] = 3,
                ["type"] = "array",
                ["uniqueItems"] = true
              },
              ["materialized"] = {
                ["type"] = "boolean"
              },
              ["persistent"] = {
                ["type"] = "boolean"
              },
              ["tags"] = {
                ["items"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 3,
                  ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                  ["type"] = "string"
                },
                ["maxItems"] = 16,
                ["type"] = "array",
                ["uniqueItems"] = true
              }
            },
            ["type"] = "object"
          },
          ["limit"] = {
            ["maximum"] = 64,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 7,
            ["pattern"] = "^synex_[a-z0-9_]+$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "resource",
          "limit"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.query.by_resource",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["binding"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["namespace"] = {
                      ["maxLength"] = 128,
                      ["minLength"] = 3,
                      ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                      ["type"] = "string"
                    },
                    ["ref"] = {
                      ["maxLength"] = 128,
                      ["minLength"] = 1,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    }
                  },
                  ["required"] = {
                    "namespace",
                    "ref"
                  },
                  ["type"] = "object"
                },
                ["bucket"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["entityId"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["entityType"] = {
                  ["enum"] = {
                    "vehicle",
                    "ped",
                    "object"
                  }
                },
                ["generation"] = {
                  ["maximum"] = 9007199254740991,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["materialized"] = {
                  ["type"] = "boolean"
                },
                ["model"] = {
                  ["maximum"] = 4294967295,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["netId"] = {
                  ["maximum"] = 65535,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["networkOwner"] = {
                  ["maximum"] = 65535,
                  ["minimum"] = -1,
                  ["type"] = "integer"
                },
                ["owner"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["id"] = {
                      ["maxLength"] = 128,
                      ["minLength"] = 1,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["type"] = {
                      ["enum"] = {
                        "character",
                        "group",
                        "resource",
                        "system",
                        "user"
                      }
                    }
                  },
                  ["required"] = {
                    "type",
                    "id"
                  },
                  ["type"] = "object"
                },
                ["persistent"] = {
                  ["type"] = "boolean"
                },
                ["resourceOwner"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 7,
                  ["pattern"] = "^synex_[a-z0-9_]+$",
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "DEFINED",
                    "SPAWNING",
                    "ACTIVE",
                    "ORPHANED",
                    "RECOVERING",
                    "DORMANT",
                    "DELETING",
                    "DELETED",
                    "FAILED"
                  }
                }
              },
              ["required"] = {
                "entityId",
                "generation",
                "entityType",
                "model",
                "bucket",
                "persistent",
                "materialized",
                "owner",
                "resourceOwner",
                "status"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 64,
            ["type"] = "array"
          },
          ["nextCursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 60,
        ["refillPerSecond"] = 20
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.query",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "BUCKET_NOT_FOUND",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "STALE_BUCKET"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["bucket"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["generation"] = {
                ["oneOf"] = {
                  {
                    ["const"] = 0
                  },
                  {
                    ["maxLength"] = 64,
                    ["minLength"] = 8,
                    ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                    ["type"] = "string"
                  }
                }
              }
            },
            ["required"] = {
              "bucket",
              "generation"
            },
            ["type"] = "object"
          },
          ["filters"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["archetype"] = {
                ["maxLength"] = 128,
                ["minLength"] = 3,
                ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                ["type"] = "string"
              },
              ["entityTypes"] = {
                ["items"] = {
                  ["enum"] = {
                    "vehicle",
                    "ped",
                    "object"
                  }
                },
                ["maxItems"] = 3,
                ["type"] = "array",
                ["uniqueItems"] = true
              },
              ["materialized"] = {
                ["type"] = "boolean"
              },
              ["persistent"] = {
                ["type"] = "boolean"
              },
              ["tags"] = {
                ["items"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 3,
                  ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                  ["type"] = "string"
                },
                ["maxItems"] = 16,
                ["type"] = "array",
                ["uniqueItems"] = true
              }
            },
            ["type"] = "object"
          },
          ["limit"] = {
            ["maximum"] = 64,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["position"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["x"] = {
                ["maximum"] = 20000,
                ["minimum"] = -20000,
                ["type"] = "number"
              },
              ["y"] = {
                ["maximum"] = 20000,
                ["minimum"] = -20000,
                ["type"] = "number"
              },
              ["z"] = {
                ["maximum"] = 20000,
                ["minimum"] = -20000,
                ["type"] = "number"
              }
            },
            ["required"] = {
              "x",
              "y",
              "z"
            },
            ["type"] = "object"
          },
          ["radius"] = {
            ["exclusiveMinimum"] = 0,
            ["maximum"] = 1000,
            ["type"] = "number"
          }
        },
        ["required"] = {
          "position",
          "radius",
          "limit"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.query.nearby",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["distance"] = {
                  ["maximum"] = 1000,
                  ["minimum"] = 0,
                  ["type"] = "number"
                },
                ["entity"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["binding"] = {
                      ["additionalProperties"] = false,
                      ["properties"] = {
                        ["namespace"] = {
                          ["maxLength"] = 128,
                          ["minLength"] = 3,
                          ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                          ["type"] = "string"
                        },
                        ["ref"] = {
                          ["maxLength"] = 128,
                          ["minLength"] = 1,
                          ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                          ["type"] = "string"
                        }
                      },
                      ["required"] = {
                        "namespace",
                        "ref"
                      },
                      ["type"] = "object"
                    },
                    ["bucket"] = {
                      ["maximum"] = 2147483647,
                      ["minimum"] = 0,
                      ["type"] = "integer"
                    },
                    ["entityId"] = {
                      ["maxLength"] = 64,
                      ["minLength"] = 8,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["entityType"] = {
                      ["enum"] = {
                        "vehicle",
                        "ped",
                        "object"
                      }
                    },
                    ["generation"] = {
                      ["maximum"] = 9007199254740991,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    },
                    ["materialized"] = {
                      ["type"] = "boolean"
                    },
                    ["model"] = {
                      ["maximum"] = 4294967295,
                      ["minimum"] = 0,
                      ["type"] = "integer"
                    },
                    ["netId"] = {
                      ["maximum"] = 65535,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    },
                    ["networkOwner"] = {
                      ["maximum"] = 65535,
                      ["minimum"] = -1,
                      ["type"] = "integer"
                    },
                    ["owner"] = {
                      ["additionalProperties"] = false,
                      ["properties"] = {
                        ["id"] = {
                          ["maxLength"] = 128,
                          ["minLength"] = 1,
                          ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                          ["type"] = "string"
                        },
                        ["type"] = {
                          ["enum"] = {
                            "character",
                            "group",
                            "resource",
                            "system",
                            "user"
                          }
                        }
                      },
                      ["required"] = {
                        "type",
                        "id"
                      },
                      ["type"] = "object"
                    },
                    ["persistent"] = {
                      ["type"] = "boolean"
                    },
                    ["resourceOwner"] = {
                      ["maxLength"] = 64,
                      ["minLength"] = 7,
                      ["pattern"] = "^synex_[a-z0-9_]+$",
                      ["type"] = "string"
                    },
                    ["status"] = {
                      ["enum"] = {
                        "DEFINED",
                        "SPAWNING",
                        "ACTIVE",
                        "ORPHANED",
                        "RECOVERING",
                        "DORMANT",
                        "DELETING",
                        "DELETED",
                        "FAILED"
                      }
                    }
                  },
                  ["required"] = {
                    "entityId",
                    "generation",
                    "entityType",
                    "model",
                    "bucket",
                    "persistent",
                    "materialized",
                    "owner",
                    "resourceOwner",
                    "status"
                  },
                  ["type"] = "object"
                }
              },
              ["required"] = {
                "entity",
                "distance"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 64,
            ["type"] = "array"
          },
          ["nextCursor"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 40,
        ["refillPerSecond"] = 12
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.read",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["persistentKey"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "persistentKey"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.resolve_persistent",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["entityId"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["entityType"] = {
            ["enum"] = {
              "vehicle",
              "ped",
              "object"
            }
          },
          ["generation"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["model"] = {
            ["maximum"] = 4294967295,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["netId"] = {
            ["maximum"] = 65535,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["networkOwner"] = {
            ["maximum"] = 65535,
            ["minimum"] = -1,
            ["type"] = "integer"
          },
          ["persistent"] = {
            ["const"] = true
          }
        },
        ["required"] = {
          "entityId",
          "generation",
          "netId",
          "entityType",
          "model",
          "bucket",
          "persistent"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 60,
        ["refillPerSecond"] = 20
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.spawn",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "ARCHETYPE_NOT_FOUND",
        "ARCHETYPE_SCHEMA_INVALID",
        "AUTHORITY_LEASE_CONFLICT",
        "BINDING_CONFLICT",
        "BUCKET_NOT_FOUND",
        "CONCURRENT_MODIFICATION",
        "CONFLICT",
        "ENTITY_ALREADY_MATERIALIZED",
        "ENTITY_QUOTA_EXCEEDED",
        "FORBIDDEN",
        "FOREIGN_BUCKET",
        "FOREIGN_RESOURCE_OWNER",
        "HOOK_REJECTED",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "INVALID_ENTITY_TYPE",
        "INVALID_LOGICAL_OWNER",
        "INVALID_MODEL",
        "INVALID_POSITION",
        "RATE_LIMITED",
        "SPAWN_FAILED",
        "SPAWN_RATE_LIMITED",
        "SPAWN_TIMEOUT",
        "STALE_BUCKET",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE"
      },
      ["idempotent"] = false,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["archetype"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["namespace"] = {
                ["maxLength"] = 128,
                ["minLength"] = 3,
                ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                ["type"] = "string"
              },
              ["version"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "namespace",
              "version"
            },
            ["type"] = "object"
          },
          ["binding"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["namespace"] = {
                ["maxLength"] = 128,
                ["minLength"] = 3,
                ["pattern"] = "^[a-z][a-z0-9_.-]+$",
                ["type"] = "string"
              },
              ["ref"] = {
                ["maxLength"] = 128,
                ["minLength"] = 1,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              }
            },
            ["required"] = {
              "namespace",
              "ref"
            },
            ["type"] = "object"
          },
          ["bucket"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["bucketGeneration"] = {
            ["oneOf"] = {
              {
                ["const"] = 0
              },
              {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              }
            }
          },
          ["doorFlag"] = {
            ["type"] = "boolean"
          },
          ["entityType"] = {
            ["enum"] = {
              "vehicle",
              "ped",
              "object"
            }
          },
          ["heading"] = {
            ["maximum"] = 360,
            ["minimum"] = -360,
            ["type"] = "number"
          },
          ["idempotencyKey"] = {
            ["maxLength"] = 36,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["model"] = {
            ["maximum"] = 4294967295,
            ["minimum"] = -2147483648,
            ["type"] = "integer"
          },
          ["owner"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["id"] = {
                ["maxLength"] = 128,
                ["minLength"] = 1,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["type"] = {
                ["enum"] = {
                  "character",
                  "group",
                  "resource",
                  "system",
                  "user"
                }
              }
            },
            ["required"] = {
              "type",
              "id"
            },
            ["type"] = "object"
          },
          ["pedType"] = {
            ["maximum"] = 29,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["persistencePolicy"] = {
            ["enum"] = {
              "temporary",
              "persistent",
              "session",
              "owner_lifetime"
            }
          },
          ["persistent"] = {
            ["type"] = "boolean"
          },
          ["persistentKey"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["position"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["x"] = {
                ["maximum"] = 20000,
                ["minimum"] = -20000,
                ["type"] = "number"
              },
              ["y"] = {
                ["maximum"] = 20000,
                ["minimum"] = -20000,
                ["type"] = "number"
              },
              ["z"] = {
                ["maximum"] = 20000,
                ["minimum"] = -20000,
                ["type"] = "number"
              }
            },
            ["required"] = {
              "x",
              "y",
              "z"
            },
            ["type"] = "object"
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["recoveryPolicy"] = {
            ["enum"] = {
              "none",
              "manual",
              "on_demand",
              "automatic"
            }
          },
          ["tags"] = {
            ["items"] = {
              ["maxLength"] = 64,
              ["minLength"] = 3,
              ["pattern"] = "^[a-z][a-z0-9_.-]+$",
              ["type"] = "string"
            },
            ["maxItems"] = 16,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["timeoutMs"] = {
            ["maximum"] = 10000,
            ["minimum"] = 250,
            ["type"] = "integer"
          },
          ["vehicleType"] = {
            ["enum"] = {
              "automobile",
              "bike",
              "boat",
              "heli",
              "plane",
              "submarine",
              "trailer"
            }
          }
        },
        ["required"] = {
          "position",
          "owner"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.spawn",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["bucket"] = {
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["entityId"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          },
          ["entityType"] = {
            ["enum"] = {
              "vehicle",
              "ped",
              "object"
            }
          },
          ["generation"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["model"] = {
            ["maximum"] = 4294967295,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["netId"] = {
            ["maximum"] = 65535,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["networkOwner"] = {
            ["maximum"] = 65535,
            ["minimum"] = -1,
            ["type"] = "integer"
          },
          ["persistent"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "entityId",
          "generation",
          "netId",
          "entityType",
          "model",
          "bucket",
          "persistent"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 12,
        ["refillPerSecond"] = 3
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.state.read",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "STATE_NOT_FOUND",
        "STATE_SCHEMA_NOT_FOUND"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.:-]+$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "entity",
          "key"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.state.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.:-]+$",
            ["type"] = "string"
          },
          ["schemaVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["valueJson"] = {
            ["maxLength"] = 8192,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity",
          "key",
          "schemaVersion",
          "valueJson",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 80,
        ["refillPerSecond"] = 25
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.state.schema.register",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "SCHEMA_VERSION_CONFLICT",
        "STATE_SCHEMA_INVALID"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["authority"] = {
            ["enum"] = {
              "server",
              "client_observed"
            }
          },
          ["constraintsJson"] = {
            ["maxLength"] = 16384,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.:-]+$",
            ["type"] = "string"
          },
          ["maximumBytes"] = {
            ["maximum"] = 8192,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["replication"] = {
            ["enum"] = {
              "none",
              "scoped"
            }
          },
          ["schemaVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["valueType"] = {
            ["enum"] = {
              "boolean",
              "integer",
              "number",
              "string",
              "json"
            }
          }
        },
        ["required"] = {
          "key",
          "schemaVersion",
          "valueType",
          "authority",
          "replication",
          "maximumBytes",
          "constraintsJson",
          "reasonCode"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.state.schema.register",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.:-]+$",
            ["type"] = "string"
          },
          ["ownerResource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 7,
            ["pattern"] = "^synex_[a-z0-9_]+$",
            ["type"] = "string"
          },
          ["registered"] = {
            ["const"] = true
          },
          ["schemaVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "key",
          "schemaVersion",
          "ownerResource",
          "registered"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 8,
        ["refillPerSecond"] = 1
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.state.write",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "AUTHORITY_LEASE_CONFLICT",
        "CONCURRENT_MODIFICATION",
        "ENTITY_NOT_FOUND",
        "ENTITY_QUOTA_EXCEEDED",
        "STATE_AUTHORITY_DENIED",
        "STATE_SCHEMA_MISMATCH",
        "STATE_SCHEMA_NOT_FOUND"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["expectedVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["idempotencyKey"] = {
            ["maxLength"] = 36,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.:-]+$",
            ["type"] = "string"
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["schemaVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["valueJson"] = {
            ["maxLength"] = 8192,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "entity",
          "key",
          "schemaVersion",
          "valueJson",
          "expectedVersion",
          "reasonCode",
          "idempotencyKey"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.state.set",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_.:-]+$",
            ["type"] = "string"
          },
          ["schemaVersion"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["stored"] = {
            ["const"] = true
          },
          ["version"] = {
            ["maximum"] = 9007199254740991,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity",
          "key",
          "schemaVersion",
          "version",
          "stored"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 40,
        ["refillPerSecond"] = 12
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.tags.write",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "AUTHORITY_LEASE_CONFLICT",
        "CONCURRENT_MODIFICATION",
        "ENTITY_NOT_FOUND",
        "ENTITY_QUOTA_EXCEEDED",
        "TAG_OWNERSHIP_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["idempotencyKey"] = {
            ["maxLength"] = 36,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["tags"] = {
            ["items"] = {
              ["maxLength"] = 64,
              ["minLength"] = 3,
              ["pattern"] = "^[a-z][a-z0-9_.-]+$",
              ["type"] = "string"
            },
            ["maxItems"] = 32,
            ["type"] = "array",
            ["uniqueItems"] = true
          }
        },
        ["required"] = {
          "entity",
          "tags",
          "reasonCode",
          "idempotencyKey"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.tags.add",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["changed"] = {
            ["type"] = "boolean"
          },
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["tags"] = {
            ["items"] = {
              ["maxLength"] = 64,
              ["minLength"] = 3,
              ["pattern"] = "^[a-z][a-z0-9_.-]+$",
              ["type"] = "string"
            },
            ["maxItems"] = 32,
            ["type"] = "array",
            ["uniqueItems"] = true
          }
        },
        ["required"] = {
          "entity",
          "tags",
          "changed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 30,
        ["refillPerSecond"] = 10
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.entities.tags.write",
      ["domain"] = "synex.entities",
      ["errors"] = {
        "CONFLICT",
        "FORBIDDEN",
        "INTERNAL_ERROR",
        "INVALID_ARGUMENT",
        "NOT_FOUND",
        "RATE_LIMITED",
        "STALE_ENTITY",
        "STALE_RESOURCE",
        "UNAVAILABLE",
        "AUTHORITY_LEASE_CONFLICT",
        "CONCURRENT_MODIFICATION",
        "ENTITY_NOT_FOUND",
        "TAG_OWNERSHIP_DENIED"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["idempotencyKey"] = {
            ["maxLength"] = 36,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reasonCode"] = {
            ["maxLength"] = 128,
            ["minLength"] = 3,
            ["pattern"] = "^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["tags"] = {
            ["items"] = {
              ["maxLength"] = 64,
              ["minLength"] = 3,
              ["pattern"] = "^[a-z][a-z0-9_.-]+$",
              ["type"] = "string"
            },
            ["maxItems"] = 32,
            ["type"] = "array",
            ["uniqueItems"] = true
          }
        },
        ["required"] = {
          "entity",
          "tags",
          "reasonCode",
          "idempotencyKey"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.entities.tags.remove",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["changed"] = {
            ["type"] = "boolean"
          },
          ["entity"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["entityId"] = {
                ["maxLength"] = 64,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              ["generation"] = {
                ["maximum"] = 9007199254740991,
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "entityId",
              "generation"
            },
            ["type"] = "object"
          },
          ["tags"] = {
            ["items"] = {
              ["maxLength"] = 64,
              ["minLength"] = 3,
              ["pattern"] = "^[a-z][a-z0-9_.-]+$",
              ["type"] = "string"
            },
            ["maxItems"] = 32,
            ["type"] = "array",
            ["uniqueItems"] = true
          }
        },
        ["required"] = {
          "entity",
          "tags",
          "changed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_entities",
      ["rateLimit"] = {
        ["capacity"] = 30,
        ["refillPerSecond"] = 10
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = nil,
      ["domain"] = "synex.example",
      ["errors"] = {
        "INVALID_ARGUMENT",
        "NOT_READY",
        "PROVIDER_UNAVAILABLE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["message"] = {
            ["maxLength"] = 128,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "message"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.example.echo",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["message"] = {
            ["maxLength"] = 128,
            ["type"] = "string"
          },
          ["provider"] = {
            ["const"] = "synex_example"
          }
        },
        ["required"] = {
          "message",
          "provider"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_example",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.applications.review",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["application_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["decision"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "application_id",
          "expected_version",
          "decision",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.applications.review",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.applications",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "RATE_LIMITED",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["data"] = {
            ["type"] = "object"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["schema_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "schema_version",
          "data"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.applications.submit",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["rateLimit"] = {
        ["capacity"] = 8,
        ["refillPerSecond"] = 1
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.applications",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "RATE_LIMITED",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["application_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "application_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.applications.withdraw",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["rateLimit"] = {
        ["capacity"] = 8,
        ["refillPerSecond"] = 1
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.archive",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.archive",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.assignments.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["assignment_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "assignment_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.assignments.cancel",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.assignments.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["assignment_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "assignment_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.assignments.complete",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.assignments.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["ends_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["metadata"] = {
            ["type"] = "object"
          },
          ["name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["parent_assignment_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["starts_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "name",
          "type"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.assignments.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.assignments.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "ASSIGNMENT_NOT_FOUND",
        "MEMBERSHIP_NOT_ACTIVE",
        "INSUFFICIENT_PERMISSION",
        "READ_MODEL_TOO_LARGE",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["assignment_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "actor_character_id",
          "assignment_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.assignments.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["assignment_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["ends_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["member_count"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["member_limit"] = {
            ["maximum"] = 65535,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["metadata"] = {
            ["type"] = "object"
          },
          ["name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["parent_assignment_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["starts_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "completed",
              "cancelled",
              "expired"
            },
            ["type"] = "string"
          },
          ["type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "assignment_id",
          "group_id",
          "name",
          "type",
          "status",
          "member_count",
          "starts_at",
          "version",
          "metadata"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.assignments.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["assignment_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["role"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "assignment_id",
          "membership_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.assignments.join",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.assignments.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["assignment_member_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "assignment_member_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.assignments.leave",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.assignments.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "MEMBERSHIP_NOT_ACTIVE",
        "INSUFFICIENT_PERMISSION",
        "READ_MODEL_TOO_LARGE",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["cursor"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 40,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "completed",
              "cancelled",
              "expired"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "actor_character_id",
          "group_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.assignments.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["assignment_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["ends_at"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 19,
                  ["type"] = "string"
                },
                ["group_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["member_count"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 0,
                  ["type"] = "integer"
                },
                ["member_limit"] = {
                  ["maximum"] = 65535,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["name"] = {
                  ["maxLength"] = 96,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["parent_assignment_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["starts_at"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 19,
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "active",
                    "completed",
                    "cancelled",
                    "expired"
                  },
                  ["type"] = "string"
                },
                ["type"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 2,
                  ["pattern"] = "^[a-z][a-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["version"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "assignment_id",
                "group_id",
                "name",
                "type",
                "status",
                "member_count",
                "starts_at",
                "version"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 40,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.attributes.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "ATTRIBUTE_NOT_FOUND",
        "INSUFFICIENT_PERMISSION",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["namespace"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "actor_character_id",
          "membership_id",
          "namespace",
          "key"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.attributes.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["attribute_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["namespace"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["type"] = {
            ["enum"] = {
              "string",
              "integer",
              "decimal",
              "boolean",
              "datetime",
              "json"
            },
            ["type"] = "string"
          },
          ["value"] = {},
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["visibility"] = {
            ["enum"] = {
              "public",
              "members",
              "management",
              "staff",
              "hidden",
              "server_only",
              "private"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "attribute_id",
          "membership_id",
          "group_id",
          "namespace",
          "key",
          "type",
          "visibility",
          "value",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.attributes.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["capability"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["pattern"] = "^[a-z][a-z0-9._*-]*$",
            ["type"] = "string"
          },
          ["default"] = {},
          ["group_type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["namespace"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["required"] = {
            ["type"] = "boolean"
          },
          ["schema_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["type"] = {
            ["enum"] = {
              "string",
              "integer",
              "decimal",
              "boolean",
              "datetime",
              "json"
            },
            ["type"] = "string"
          },
          ["validation"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["enum"] = {
                ["items"] = {},
                ["maxItems"] = 32,
                ["minItems"] = 1,
                ["type"] = "array"
              },
              ["max_length"] = {
                ["maximum"] = 512,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["maximum"] = {
                ["type"] = "number"
              },
              ["min_length"] = {
                ["maximum"] = 512,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["minimum"] = {
                ["type"] = "number"
              },
              ["required"] = {
                ["type"] = "boolean"
              }
            },
            ["type"] = "object"
          },
          ["visibility"] = {
            ["enum"] = {
              "public",
              "members",
              "management",
              "staff",
              "hidden",
              "server_only",
              "private"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "namespace",
          "key",
          "type",
          "visibility",
          "schema_version"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.attributes.register_schema",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.attributes.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["namespace"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["value"] = {}
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "membership_id",
          "namespace",
          "key",
          "value"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.attributes.set",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["capability"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["pattern"] = "^[a-z][a-z0-9._*-]*$",
            ["type"] = "string"
          },
          ["character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["scope"] = {
            ["enum"] = {
              "group",
              "subtree"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "character_id",
          "group_id",
          "capability"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.capabilities.check",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["capability"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["pattern"] = "^[a-z][a-z0-9._*-]*$",
            ["type"] = "string"
          },
          ["character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["decision"] = {
            ["enum"] = {
              "ALLOW",
              "DENY"
            },
            ["type"] = "string"
          },
          ["delegable"] = {
            ["type"] = "boolean"
          },
          ["evaluation"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 128,
            ["type"] = "array"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["scope"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "decision",
          "reason",
          "character_id",
          "group_id",
          "capability",
          "scope",
          "delegable",
          "trace_id",
          "evaluation"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["capability"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["pattern"] = "^[a-z][a-z0-9._*-]*$",
            ["type"] = "string"
          },
          ["character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["scope"] = {
            ["enum"] = {
              "group",
              "subtree"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "character_id",
          "group_id",
          "capability"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.capabilities.explain",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["capability"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["pattern"] = "^[a-z][a-z0-9._*-]*$",
            ["type"] = "string"
          },
          ["character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["decision"] = {
            ["enum"] = {
              "ALLOW",
              "DENY"
            },
            ["type"] = "string"
          },
          ["delegable"] = {
            ["type"] = "boolean"
          },
          ["evaluation"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 128,
            ["type"] = "array"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["scope"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "decision",
          "reason",
          "character_id",
          "group_id",
          "capability",
          "scope",
          "delegable",
          "trace_id",
          "evaluation"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.capabilities.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["capability"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["pattern"] = "^[a-z][a-z0-9._*-]*$",
            ["type"] = "string"
          },
          ["delegable"] = {
            ["type"] = "boolean"
          },
          ["effect"] = {
            ["enum"] = {
              "allow",
              "deny"
            },
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["scope"] = {
            ["enum"] = {
              "group",
              "subtree"
            },
            ["type"] = "string"
          },
          ["source_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["source_type"] = {
            ["enum"] = {
              "group",
              "grade",
              "role",
              "membership"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "source_type",
          "source_id",
          "capability",
          "effect"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.capabilities.set",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "GRADE_NOT_FOUND",
        "READ_MODEL_TOO_LARGE",
        "DATABASE_RESULT_INVALID",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["grade_key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["group_key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["group_type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "actor_character_id",
          "group_type",
          "group_key",
          "grade_key"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.compatibility.resolve_target",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["duty_session_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["duty_state"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["duty_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["grade_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_status"] = {
            ["enum"] = {
              "DRAFT",
              "INVITED",
              "APPLICANT",
              "UNDER_REVIEW",
              "APPROVED",
              "PROBATION",
              "ACTIVE",
              "SUSPENDED",
              "LEAVE",
              "INACTIVE",
              "TERMINATED",
              "BANNED",
              "LEFT",
              "ARCHIVED"
            },
            ["type"] = "string"
          },
          ["membership_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["primary_state"] = {
            ["enum"] = {
              "unassigned",
              "selected",
              "different"
            },
            ["type"] = "string"
          },
          ["primary_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "group_id",
          "grade_id"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.compatibility.set_primary_grade",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "INSUFFICIENT_PERMISSION",
        "TARGET_GRADE_TOO_HIGH",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "READ_MODEL_TOO_LARGE",
        "DATABASE_RESULT_INVALID",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_primary_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["expected_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["grade_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "membership_id",
          "grade_id",
          "expected_version",
          "group_type",
          "expected_primary_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.compatibility.set_primary_grade",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["grade_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["primary_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["primary_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "membership_id",
          "membership_version",
          "grade_id",
          "primary_id",
          "primary_version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "READ_MODEL_TOO_LARGE",
        "DATABASE_RESULT_INVALID",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["cursor"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 8,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "actor_character_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.compatibility.snapshot",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["duty"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["assignment_id"] = {
                      ["maxLength"] = 48,
                      ["minLength"] = 8,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["counts_as_on_duty"] = {
                      ["type"] = "boolean"
                    },
                    ["duty_session_id"] = {
                      ["maxLength"] = 48,
                      ["minLength"] = 8,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["state"] = {
                      ["maxLength"] = 32,
                      ["minLength"] = 2,
                      ["pattern"] = "^[a-z][a-z0-9_-]*$",
                      ["type"] = "string"
                    },
                    ["version"] = {
                      ["maximum"] = 2147483647,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  },
                  ["required"] = {
                    "duty_session_id",
                    "state",
                    "counts_as_on_duty",
                    "version"
                  },
                  ["type"] = "object"
                },
                ["grade"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["grade_id"] = {
                      ["maxLength"] = 48,
                      ["minLength"] = 8,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["key"] = {
                      ["maxLength"] = 64,
                      ["minLength"] = 2,
                      ["pattern"] = "^[a-z][a-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["name"] = {
                      ["maxLength"] = 96,
                      ["minLength"] = 1,
                      ["type"] = "string"
                    },
                    ["rank"] = {
                      ["maximum"] = 32767,
                      ["minimum"] = -32768,
                      ["type"] = "integer"
                    }
                  },
                  ["required"] = {
                    "grade_id",
                    "key",
                    "name",
                    "rank"
                  },
                  ["type"] = "object"
                },
                ["group"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["group_id"] = {
                      ["maxLength"] = 48,
                      ["minLength"] = 8,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["key"] = {
                      ["maxLength"] = 64,
                      ["minLength"] = 2,
                      ["pattern"] = "^[a-z][a-z0-9_-]*$",
                      ["type"] = "string"
                    },
                    ["label"] = {
                      ["maxLength"] = 96,
                      ["minLength"] = 1,
                      ["type"] = "string"
                    },
                    ["name"] = {
                      ["maxLength"] = 96,
                      ["minLength"] = 1,
                      ["type"] = "string"
                    },
                    ["type"] = {
                      ["maxLength"] = 64,
                      ["minLength"] = 2,
                      ["pattern"] = "^[a-z][a-z0-9_.:%-]*$",
                      ["type"] = "string"
                    }
                  },
                  ["required"] = {
                    "group_id",
                    "key",
                    "type",
                    "name",
                    "label"
                  },
                  ["type"] = "object"
                },
                ["group_version"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["is_primary"] = {
                  ["type"] = "boolean"
                },
                ["membership_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["membership_profile_version"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["membership_version"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["primary_version"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["roles"] = {
                  ["items"] = {
                    ["additionalProperties"] = false,
                    ["properties"] = {
                      ["key"] = {
                        ["maxLength"] = 64,
                        ["minLength"] = 2,
                        ["pattern"] = "^[a-z][a-z0-9_.:%-]*$",
                        ["type"] = "string"
                      },
                      ["name"] = {
                        ["maxLength"] = 96,
                        ["minLength"] = 1,
                        ["type"] = "string"
                      },
                      ["role_id"] = {
                        ["maxLength"] = 48,
                        ["minLength"] = 8,
                        ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                        ["type"] = "string"
                      },
                      ["valid_until"] = {
                        ["maxLength"] = 32,
                        ["minLength"] = 19,
                        ["type"] = "string"
                      }
                    },
                    ["required"] = {
                      "role_id",
                      "key",
                      "name"
                    },
                    ["type"] = "object"
                  },
                  ["maxItems"] = 8,
                  ["type"] = "array"
                },
                ["roles_truncated"] = {
                  ["type"] = "boolean"
                },
                ["status"] = {
                  ["enum"] = {
                    "DRAFT",
                    "INVITED",
                    "APPLICANT",
                    "UNDER_REVIEW",
                    "APPROVED",
                    "PROBATION",
                    "ACTIVE",
                    "SUSPENDED",
                    "LEAVE",
                    "INACTIVE"
                  },
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "membership_id",
                "membership_version",
                "membership_profile_version",
                "group_version",
                "group",
                "status",
                "is_primary",
                "roles",
                "roles_truncated"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 8,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.create",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["description"] = {
            ["maxLength"] = 1024,
            ["type"] = "string"
          },
          ["dynamic"] = {
            ["type"] = "boolean"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["label"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["metadata"] = {
            ["type"] = "object"
          },
          ["name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["parent_group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["slug"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "draft",
              "active",
              "DRAFT",
              "ACTIVE"
            },
            ["type"] = "string"
          },
          ["type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["visibility"] = {
            ["enum"] = {
              "public",
              "internal",
              "private",
              "hidden"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "type",
          "slug",
          "name",
          "label"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.creation_requests.decide",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "CREATION_REQUEST_NOT_FOUND",
        "CREATION_REQUEST_EXPIRED",
        "CREATION_REQUEST_TERMINAL",
        "CREATOR_CANNOT_DECIDE",
        "APPROVAL_ALREADY_DECIDED",
        "INSUFFICIENT_PERMISSION",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["creation_request_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "creation_request_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.creation_requests.approve",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["approval_count"] = {
            ["maximum"] = 32,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["creation_request_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["decision_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["required_approvals"] = {
            ["maximum"] = 32,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["status"] = {
            ["enum"] = {
              "pending",
              "approved"
            },
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 2,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "creation_request_id",
          "decision_id",
          "status",
          "approval_count",
          "required_approvals",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.creation_requests.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "CREATION_REQUEST_NOT_FOUND",
        "INSUFFICIENT_PERMISSION",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["creation_request_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "actor_character_id",
          "creation_request_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.creation_requests.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["approval_count"] = {
            ["maximum"] = 32,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["creation_request_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["decisions"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["character_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["created_at"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 19,
                  ["type"] = "string"
                },
                ["decision"] = {
                  ["enum"] = {
                    "approved",
                    "rejected"
                  },
                  ["type"] = "string"
                },
                ["decision_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "decision_id",
                "character_id",
                "decision",
                "created_at"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 32,
            ["type"] = "array"
          },
          ["expires_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["failure_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 2,
            ["pattern"] = "^[A-Z][A-Z0-9_]+$",
            ["type"] = "string"
          },
          ["group_type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["requested_by_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["required_approvals"] = {
            ["maximum"] = 32,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["slug"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "pending",
              "approved",
              "executed",
              "rejected",
              "expired"
            },
            ["type"] = "string"
          },
          ["target_group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "creation_request_id",
          "requested_by_character_id",
          "group_type",
          "slug",
          "status",
          "required_approvals",
          "approval_count",
          "expires_at",
          "version",
          "decisions"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.creation_requests.decide",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "CREATION_REQUEST_NOT_FOUND",
        "CREATION_REQUEST_EXPIRED",
        "CREATION_REQUEST_TERMINAL",
        "CREATOR_CANNOT_DECIDE",
        "APPROVAL_ALREADY_DECIDED",
        "INSUFFICIENT_PERMISSION",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["creation_request_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "creation_request_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.creation_requests.reject",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["approval_count"] = {
            ["maximum"] = 31,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["creation_request_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["decision_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["required_approvals"] = {
            ["maximum"] = 32,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["status"] = {
            ["enum"] = {
              "rejected"
            },
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 2,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "creation_request_id",
          "decision_id",
          "status",
          "approval_count",
          "required_approvals",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.definitions.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["definitions"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 16,
            ["type"] = "array"
          },
          ["dry_run"] = {
            ["type"] = "boolean"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["owner_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["schema_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "schema_version",
          "definitions",
          "dry_run"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.definitions.sync",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 100,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.delegations.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["capability"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["pattern"] = "^[a-z][a-z0-9._*-]*$",
            ["type"] = "string"
          },
          ["grantee_membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["scope"] = {
            ["enum"] = {
              "group",
              "subtree"
            },
            ["type"] = "string"
          },
          ["valid_from"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["valid_until"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "grantee_membership_id",
          "capability",
          "valid_until",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.delegations.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.delegations.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["delegation_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "delegation_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.delegations.revoke",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.delete",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE",
        "GROUP_NOT_ARCHIVED",
        "GROUP_DELETION_IN_PROGRESS",
        "INSUFFICIENT_PERMISSION",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.delete",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["deletion_request_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["failure_code"] = {
            ["maxLength"] = 96,
            ["minLength"] = 2,
            ["pattern"] = "^[A-Z][A-Z0-9_]+$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_status"] = {
            ["enum"] = {
              "archived",
              "dissolving",
              "deleted"
            },
            ["type"] = "string"
          },
          ["group_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["plan_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[a-z0-9_]+$",
            ["type"] = "string"
          },
          ["plan_state"] = {
            ["enum"] = {
              "pending",
              "executing",
              "completed",
              "blocked",
              "failed"
            },
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["state"] = {
            ["enum"] = {
              "planning",
              "blocked",
              "dissolving",
              "deleted",
              "failed"
            },
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "deletion_request_id",
          "group_id",
          "state",
          "group_status",
          "group_version",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.directory.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["cursor"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 100,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "actor_character_id",
          "group_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.directory.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 100,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {},
        ["required"] = {},
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.doctor",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cache"] = {
            ["type"] = "object"
          },
          ["checks"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 32,
            ["type"] = "array"
          },
          ["registries"] = {
            ["type"] = "object"
          },
          ["runtimeIndex"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["characters"] = {
                ["maximum"] = 8192,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["clears"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["dutySessions"] = {
                ["maximum"] = 262144,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["hits"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["invalidations"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["loads"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["maximumCharacters"] = {
                ["maximum"] = 8192,
                ["minimum"] = 16,
                ["type"] = "integer"
              },
              ["maximumMemberships"] = {
                ["maximum"] = 262144,
                ["minimum"] = 64,
                ["type"] = "integer"
              },
              ["maximumMembershipsPerCharacter"] = {
                ["maximum"] = 4096,
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["memberships"] = {
                ["maximum"] = 262144,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["misses"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["onDutyGroups"] = {
                ["maximum"] = 262144,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["onlineGroups"] = {
                ["maximum"] = 262144,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["rebuilds"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["refreshFailures"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["refreshes"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["unloads"] = {
                ["maximum"] = 2147483647,
                ["minimum"] = 0,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "characters",
              "memberships",
              "dutySessions",
              "onlineGroups",
              "onDutyGroups",
              "maximumCharacters",
              "maximumMemberships",
              "maximumMembershipsPerCharacter",
              "hits",
              "misses",
              "loads",
              "unloads",
              "rebuilds",
              "refreshes",
              "refreshFailures",
              "invalidations",
              "clears"
            },
            ["type"] = "object"
          },
          ["status"] = {
            ["enum"] = {
              "PASS",
              "WARN",
              "FAIL"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "status",
          "checks",
          "cache",
          "registries",
          "runtimeIndex"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.duty.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "MEMBERSHIP_NOT_ACTIVE",
        "INSUFFICIENT_PERMISSION",
        "READ_MODEL_TOO_LARGE",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["cursor"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 40,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "open",
              "closed"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "actor_character_id",
          "group_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.duty.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["assignment_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["counts_as_on_duty"] = {
                  ["type"] = "boolean"
                },
                ["duty_session_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["ended_at"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 19,
                  ["type"] = "string"
                },
                ["group_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["membership_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["started_at"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 19,
                  ["type"] = "string"
                },
                ["state"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 2,
                  ["pattern"] = "^[a-z][a-z0-9_-]*$",
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "open",
                    "closed"
                  },
                  ["type"] = "string"
                },
                ["version"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "duty_session_id",
                "membership_id",
                "group_id",
                "state",
                "status",
                "counts_as_on_duty",
                "started_at",
                "version"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 40,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.duty",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "RATE_LIMITED",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["assignment_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["metadata"] = {
            ["type"] = "object"
          },
          ["state"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "membership_id",
          "state"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.duty.start",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["rateLimit"] = {
        ["capacity"] = 30,
        ["refillPerSecond"] = 10
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.duty",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "RATE_LIMITED",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["duty_session_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "duty_session_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.duty.stop",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["rateLimit"] = {
        ["capacity"] = 30,
        ["refillPerSecond"] = 10
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.duty",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "RATE_LIMITED",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["assignment_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["duty_session_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["metadata"] = {
            ["type"] = "object"
          },
          ["state"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "duty_session_id",
          "expected_version",
          "state",
          "assignment_id",
          "metadata"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.duty.update",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["rateLimit"] = {
        ["capacity"] = 30,
        ["refillPerSecond"] = 10
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.types.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE",
        "TYPE_OWNER_CONFLICT",
        "INVALID_TRANSITION",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["counts_as_on_duty"] = {
            ["type"] = "boolean"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["label"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["schema_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["state"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "state",
          "schema_version",
          "label",
          "counts_as_on_duty"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.duty_states.register",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "group_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["created_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["description"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 1024,
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["dynamic"] = {
            ["type"] = "boolean"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["label"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["parent_group_id"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["slug"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["status"] = {
            ["type"] = "string"
          },
          ["type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["updated_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["visibility"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "group_id",
          "type",
          "slug",
          "name",
          "label",
          "status",
          "visibility",
          "dynamic",
          "version",
          "created_at",
          "updated_at"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.grades.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["capacity"] = {
            ["maximum"] = 100000,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["label"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["rank"] = {
            ["maximum"] = 32767,
            ["minimum"] = -32768,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "key",
          "label",
          "rank"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.grades.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.grades.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["capacity"] = {
            ["maximum"] = 100000,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["grade_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["label"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["rank"] = {
            ["maximum"] = 32767,
            ["minimum"] = -32768,
            ["type"] = "integer"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "disabled"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "grade_id",
          "expected_version"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.grades.update",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.history.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["cursor"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 100,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "actor_character_id",
          "group_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.history.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 100,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cursor"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 100,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["parent_group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "draft",
              "active",
              "pending",
              "suspended",
              "archived",
              "dissolving",
              "deleted"
            },
            ["type"] = "string"
          },
          ["type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {},
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 100,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.members.accept",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "RATE_LIMITED",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["invitation_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "invitation_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.accept",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["rateLimit"] = {
        ["capacity"] = 12,
        ["refillPerSecond"] = 3
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.members.accept",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "RATE_LIMITED",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["invitation_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "invitation_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.decline",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["rateLimit"] = {
        ["capacity"] = 12,
        ["refillPerSecond"] = 3
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.members.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "membership_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["grade_id"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["joined_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["left_at"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 32,
                ["minLength"] = 19,
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reports_to_public_id"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["status"] = {
            ["type"] = "string"
          },
          ["version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["visibility"] = {
            ["type"] = "string"
          }
        },
        ["required"] = {
          "membership_id",
          "group_id",
          "character_id",
          "status",
          "visibility",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.members.invite",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expires_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["grade_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["role_ids"] = {
            ["items"] = {
              ["maxLength"] = 48,
              ["minLength"] = 8,
              ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
              ["type"] = "string"
            },
            ["maxItems"] = 16,
            ["type"] = "array",
            ["uniqueItems"] = true
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "character_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.invite",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.members.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["cursor"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 100,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["status"] = {
            ["enum"] = {
              "DRAFT",
              "INVITED",
              "APPLICANT",
              "UNDER_REVIEW",
              "APPROVED",
              "PROBATION",
              "ACTIVE",
              "SUSPENDED",
              "LEAVE",
              "INACTIVE",
              "TERMINATED",
              "BANNED",
              "LEFT",
              "ARCHIVED"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "group_id",
          "actor_character_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 100,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.members.invite",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["invitation_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "invitation_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.revoke_invite",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.grades.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["grade_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "membership_id",
          "grade_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.set_grade",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.members.primary",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "membership_id",
          "group_type"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.set_primary",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.members.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_NOT_ACTIVE",
        "INSUFFICIENT_PERMISSION",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "DATABASE_RESULT_INVALID",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["visibility"] = {
            ["enum"] = {
              "public",
              "members",
              "management",
              "hidden",
              "server_only"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "membership_id",
          "visibility",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.set_visibility",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["enum"] = {
              "membership"
            },
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["enum"] = {
              "public",
              "members",
              "management",
              "hidden",
              "server_only"
            },
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.members.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "DRAFT",
              "INVITED",
              "APPLICANT",
              "UNDER_REVIEW",
              "APPROVED",
              "PROBATION",
              "ACTIVE",
              "SUSPENDED",
              "LEAVE",
              "INACTIVE",
              "TERMINATED",
              "BANNED",
              "LEFT",
              "ARCHIVED"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "membership_id",
          "expected_version",
          "status"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.transition",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.policies.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_TRANSITION",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["from_status"] = {
            ["enum"] = {
              "DRAFT",
              "INVITED",
              "APPLICANT",
              "UNDER_REVIEW",
              "APPROVED",
              "PROBATION",
              "ACTIVE",
              "SUSPENDED",
              "LEAVE",
              "INACTIVE",
              "TERMINATED",
              "BANNED",
              "LEFT",
              "ARCHIVED"
            },
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["to_status"] = {
            ["enum"] = {
              "DRAFT",
              "INVITED",
              "APPLICANT",
              "UNDER_REVIEW",
              "APPROVED",
              "PROBATION",
              "ACTIVE",
              "SUSPENDED",
              "LEAVE",
              "INACTIVE",
              "TERMINATED",
              "BANNED",
              "LEFT",
              "ARCHIVED"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "actor_character_id",
          "group_id",
          "from_status",
          "to_status"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.transition_policy.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["allowed"] = {
            ["type"] = "boolean"
          },
          ["approval_required"] = {
            ["type"] = "boolean"
          },
          ["configured"] = {
            ["type"] = "boolean"
          },
          ["from_status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["policy_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason_required"] = {
            ["type"] = "boolean"
          },
          ["required_capability"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["pattern"] = "^[a-z][a-z0-9._-]*$",
            ["type"] = "string"
          },
          ["to_status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "configured",
          "group_id",
          "from_status",
          "to_status",
          "allowed",
          "required_capability",
          "approval_required",
          "reason_required"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.policies.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_TRANSITION",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["allowed"] = {
            ["type"] = "boolean"
          },
          ["approval_required"] = {
            ["type"] = "boolean"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["from_status"] = {
            ["enum"] = {
              "DRAFT",
              "INVITED",
              "APPLICANT",
              "UNDER_REVIEW",
              "APPROVED",
              "PROBATION",
              "ACTIVE",
              "SUSPENDED",
              "LEAVE",
              "INACTIVE",
              "TERMINATED",
              "BANNED",
              "LEFT",
              "ARCHIVED"
            },
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reason_required"] = {
            ["type"] = "boolean"
          },
          ["required_capability"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["pattern"] = "^[a-z][a-z0-9._-]*$",
            ["type"] = "string"
          },
          ["to_status"] = {
            ["enum"] = {
              "DRAFT",
              "INVITED",
              "APPLICANT",
              "UNDER_REVIEW",
              "APPROVED",
              "PROBATION",
              "ACTIVE",
              "SUSPENDED",
              "LEAVE",
              "INACTIVE",
              "TERMINATED",
              "BANNED",
              "LEFT",
              "ARCHIVED"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "from_status",
          "to_status",
          "allowed",
          "required_capability",
          "approval_required",
          "reason_required"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.members.transition_policy.set",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.policies.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["action"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["definition"] = {
            ["type"] = "object"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "action",
          "definition"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.policies.set",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["action"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["parameters"] = {
            ["type"] = "object"
          },
          ["target_membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "actor_character_id",
          "group_id",
          "action"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.policies.simulate",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["capability"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["pattern"] = "^[a-z][a-z0-9._*-]*$",
            ["type"] = "string"
          },
          ["character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["decision"] = {
            ["enum"] = {
              "ALLOW",
              "DENY"
            },
            ["type"] = "string"
          },
          ["delegable"] = {
            ["type"] = "boolean"
          },
          ["evaluation"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 128,
            ["type"] = "array"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["scope"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["trace_id"] = {
            ["maxLength"] = 64,
            ["minLength"] = 8,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "decision",
          "reason",
          "character_id",
          "group_id",
          "capability",
          "scope",
          "delegable",
          "trace_id",
          "evaluation"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.approvals.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["proposal_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "proposal_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.proposals.approve",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.approvals.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["action"] = {
            ["maxLength"] = 96,
            ["minLength"] = 3,
            ["type"] = "string"
          },
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expires_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["payload"] = {
            ["type"] = "object"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["required_approvals"] = {
            ["maximum"] = 32,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "action",
          "payload",
          "required_approvals",
          "expires_at"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.proposals.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.approvals.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["proposal_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "proposal_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.proposals.reject",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.registries.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.registries.begin",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["generation"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["owner_epoch"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["owner_resource"] = {
            ["maxLength"] = 64,
            ["minLength"] = 3,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.-]*$",
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["enum"] = {
              "synchronized"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "owner_resource",
          "owner_epoch",
          "generation",
          "status",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.types.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE",
        "TYPE_OWNER_CONFLICT",
        "INVALID_TRANSITION",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "DATABASE_ERROR"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["direction"] = {
            ["enum"] = {
              "directed",
              "symmetric"
            },
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["label"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["schema_version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "type",
          "schema_version",
          "label",
          "direction"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.relation_types.register",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.relationships.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["metadata"] = {
            ["type"] = "object"
          },
          ["relation_type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["source_group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["target_group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["valid_from"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["valid_until"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "source_group_id",
          "target_group_id",
          "relation_type"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.relationships.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.relationships.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "RELATIONSHIP_NOT_FOUND",
        "MEMBERSHIP_NOT_ACTIVE",
        "INSUFFICIENT_PERMISSION",
        "READ_MODEL_TOO_LARGE",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["relationship_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "actor_character_id",
          "group_id",
          "relationship_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.relationships.get",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["created_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["direction"] = {
            ["enum"] = {
              "directed",
              "symmetric"
            },
            ["type"] = "string"
          },
          ["ended_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["metadata"] = {
            ["type"] = "object"
          },
          ["relation_type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["relationship_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["source_group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "suspended",
              "ended"
            },
            ["type"] = "string"
          },
          ["target_group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["updated_at"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["valid_from"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["valid_until"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "relationship_id",
          "source_group_id",
          "target_group_id",
          "relation_type",
          "direction",
          "status",
          "valid_from",
          "metadata",
          "version",
          "created_at",
          "updated_at"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.relationships.read",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "MEMBERSHIP_NOT_ACTIVE",
        "INSUFFICIENT_PERMISSION",
        "READ_MODEL_TOO_LARGE",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["cursor"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["direction"] = {
            ["enum"] = {
              "any",
              "outgoing",
              "incoming"
            },
            ["type"] = "string"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 40,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["relation_type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "pending",
              "active",
              "suspended",
              "ended"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "actor_character_id",
          "group_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.relationships.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["created_at"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 19,
                  ["type"] = "string"
                },
                ["direction"] = {
                  ["enum"] = {
                    "directed",
                    "symmetric"
                  },
                  ["type"] = "string"
                },
                ["ended_at"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 19,
                  ["type"] = "string"
                },
                ["relation_type"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 2,
                  ["pattern"] = "^[a-z][a-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["relationship_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["source_group_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["status"] = {
                  ["enum"] = {
                    "active",
                    "pending",
                    "suspended",
                    "ended"
                  },
                  ["type"] = "string"
                },
                ["target_group_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["updated_at"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 19,
                  ["type"] = "string"
                },
                ["valid_from"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 19,
                  ["type"] = "string"
                },
                ["valid_until"] = {
                  ["maxLength"] = 32,
                  ["minLength"] = 19,
                  ["type"] = "string"
                },
                ["version"] = {
                  ["maximum"] = 2147483647,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "relationship_id",
                "source_group_id",
                "target_group_id",
                "relation_type",
                "direction",
                "status",
                "valid_from",
                "version",
                "created_at",
                "updated_at"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 40,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.relationships.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["relationship_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "suspended",
              "ended"
            },
            ["type"] = "string"
          },
          ["valid_until"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "relationship_id",
          "expected_version",
          "status"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.relationships.update",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.reporting.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reports_to_membership_id"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            },
            ["description"] = "Public membership ID of the manager. Omit or pass null to remove the reporting edge."
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "membership_id",
          "reason",
          "expected_version"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.reporting.set",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.roles.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["role_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["valid_from"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          },
          ["valid_until"] = {
            ["maxLength"] = 32,
            ["minLength"] = 19,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "membership_id",
          "role_id"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.roles.assign",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.roles.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["assignable"] = {
            ["type"] = "boolean"
          },
          ["capacity"] = {
            ["maximum"] = 100000,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["description"] = {
            ["maxLength"] = 1024,
            ["type"] = "string"
          },
          ["exclusive"] = {
            ["type"] = "boolean"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["key"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["label"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "key",
          "label"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.roles.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.roles.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["membership_role_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "membership_role_id",
          "expected_version",
          "reason"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.roles.remove",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.roles.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["assignable"] = {
            ["type"] = "boolean"
          },
          ["description"] = {
            ["maxLength"] = 1024,
            ["type"] = "string"
          },
          ["exclusive"] = {
            ["type"] = "boolean"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["label"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["role_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "disabled",
              "retired"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "role_id",
          "expected_version"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.roles.update",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "SESSION_REQUIRED",
        "INVALID_SESSION_STATE",
        "RATE_LIMITED",
        "CHARACTER_NOT_FOUND",
        "READ_MODEL_TOO_LARGE",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "PARENT_GROUP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_DEPTH_EXCEEDED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE"
      },
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["cursor"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["limit"] = {
            ["maximum"] = 8,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {},
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.self.snapshot",
      ["network"] = "client-to-server",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["items"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["duty"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["assignment_id"] = {
                      ["maxLength"] = 48,
                      ["minLength"] = 8,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["counts_as_on_duty"] = {
                      ["type"] = "boolean"
                    },
                    ["duty_session_id"] = {
                      ["maxLength"] = 48,
                      ["minLength"] = 8,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["state"] = {
                      ["maxLength"] = 32,
                      ["minLength"] = 2,
                      ["pattern"] = "^[a-z][a-z0-9_-]*$",
                      ["type"] = "string"
                    },
                    ["version"] = {
                      ["maximum"] = 2147483647,
                      ["minimum"] = 1,
                      ["type"] = "integer"
                    }
                  },
                  ["required"] = {
                    "duty_session_id",
                    "state",
                    "counts_as_on_duty",
                    "version"
                  },
                  ["type"] = "object"
                },
                ["grade"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["grade_id"] = {
                      ["maxLength"] = 48,
                      ["minLength"] = 8,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["key"] = {
                      ["maxLength"] = 64,
                      ["minLength"] = 2,
                      ["pattern"] = "^[a-z][a-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["name"] = {
                      ["maxLength"] = 96,
                      ["minLength"] = 1,
                      ["type"] = "string"
                    },
                    ["rank"] = {
                      ["maximum"] = 32767,
                      ["minimum"] = -32768,
                      ["type"] = "integer"
                    }
                  },
                  ["required"] = {
                    "grade_id",
                    "key",
                    "name",
                    "rank"
                  },
                  ["type"] = "object"
                },
                ["group"] = {
                  ["additionalProperties"] = false,
                  ["properties"] = {
                    ["group_id"] = {
                      ["maxLength"] = 48,
                      ["minLength"] = 8,
                      ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                      ["type"] = "string"
                    },
                    ["name"] = {
                      ["maxLength"] = 96,
                      ["minLength"] = 1,
                      ["type"] = "string"
                    },
                    ["type"] = {
                      ["maxLength"] = 64,
                      ["minLength"] = 2,
                      ["pattern"] = "^[a-z][a-z0-9_.:%-]*$",
                      ["type"] = "string"
                    }
                  },
                  ["required"] = {
                    "group_id",
                    "type",
                    "name"
                  },
                  ["type"] = "object"
                },
                ["membership_id"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 8,
                  ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                  ["type"] = "string"
                },
                ["roles"] = {
                  ["items"] = {
                    ["additionalProperties"] = false,
                    ["properties"] = {
                      ["key"] = {
                        ["maxLength"] = 64,
                        ["minLength"] = 2,
                        ["pattern"] = "^[a-z][a-z0-9_.:%-]*$",
                        ["type"] = "string"
                      },
                      ["name"] = {
                        ["maxLength"] = 96,
                        ["minLength"] = 1,
                        ["type"] = "string"
                      },
                      ["role_id"] = {
                        ["maxLength"] = 48,
                        ["minLength"] = 8,
                        ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                        ["type"] = "string"
                      },
                      ["valid_until"] = {
                        ["maxLength"] = 32,
                        ["minLength"] = 19,
                        ["type"] = "string"
                      }
                    },
                    ["required"] = {
                      "role_id",
                      "key",
                      "name"
                    },
                    ["type"] = "object"
                  },
                  ["maxItems"] = 8,
                  ["type"] = "array"
                },
                ["roles_truncated"] = {
                  ["type"] = "boolean"
                },
                ["status"] = {
                  ["enum"] = {
                    "DRAFT",
                    "INVITED",
                    "APPLICANT",
                    "UNDER_REVIEW",
                    "APPROVED",
                    "PROBATION",
                    "ACTIVE",
                    "SUSPENDED",
                    "LEAVE",
                    "INACTIVE"
                  },
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "membership_id",
                "group",
                "status",
                "roles",
                "roles_truncated"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 8,
            ["type"] = "array"
          },
          ["next_cursor"] = {
            ["anyOf"] = {
              {
                ["maxLength"] = 48,
                ["minLength"] = 8,
                ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
                ["type"] = "string"
              },
              {
                ["type"] = "null"
              }
            }
          },
          ["truncated"] = {
            ["type"] = "boolean"
          }
        },
        ["required"] = {
          "items",
          "truncated"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["rateLimit"] = {
        ["capacity"] = 4,
        ["refillPerSecond"] = 1
      },
      ["sessionStates"] = {
        "ACTIVE"
      },
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.types.manage",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["allowed_duty_states"] = {
            ["items"] = {
              ["maxLength"] = 32,
              ["minLength"] = 2,
              ["type"] = "string"
            },
            ["maxItems"] = 16,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["allowed_membership_states"] = {
            ["items"] = {
              ["maxLength"] = 32,
              ["minLength"] = 2,
              ["type"] = "string"
            },
            ["maxItems"] = 16,
            ["type"] = "array",
            ["uniqueItems"] = true
          },
          ["approval_permission"] = {
            ["maxLength"] = 96,
            ["minLength"] = 30,
            ["pattern"] = "^synex\\.groups\\.create\\.approve\\.[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["create_permission"] = {
            ["maxLength"] = 96,
            ["minLength"] = 22,
            ["pattern"] = "^synex\\.groups\\.create\\.[a-z][a-z0-9_.-]+$",
            ["type"] = "string"
          },
          ["default_grades"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["capacity"] = {
                  ["maximum"] = 100000,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["key"] = {
                  ["maxLength"] = 48,
                  ["minLength"] = 2,
                  ["pattern"] = "^[a-z][a-z0-9_]*$",
                  ["type"] = "string"
                },
                ["label"] = {
                  ["maxLength"] = 96,
                  ["minLength"] = 1,
                  ["type"] = "string"
                },
                ["rank"] = {
                  ["maximum"] = 32766,
                  ["minimum"] = -32768,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "key",
                "label",
                "rank"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 32,
            ["type"] = "array"
          },
          ["default_roles"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["assignable"] = {
                  ["type"] = "boolean"
                },
                ["capacity"] = {
                  ["maximum"] = 100000,
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["description"] = {
                  ["maxLength"] = 1024,
                  ["type"] = "string"
                },
                ["exclusive"] = {
                  ["type"] = "boolean"
                },
                ["key"] = {
                  ["maxLength"] = 64,
                  ["minLength"] = 2,
                  ["pattern"] = "^[a-z][a-z0-9_]*$",
                  ["type"] = "string"
                },
                ["label"] = {
                  ["maxLength"] = 96,
                  ["minLength"] = 1,
                  ["type"] = "string"
                }
              },
              ["required"] = {
                "key",
                "label"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 32,
            ["type"] = "array"
          },
          ["dynamic_creation"] = {
            ["type"] = "boolean"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["label"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["max_active_members"] = {
            ["maximum"] = 100000,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["max_members"] = {
            ["maximum"] = 100000,
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["metadata"] = {
            ["type"] = "object"
          },
          ["required_approvals"] = {
            ["maximum"] = 32,
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["schema_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["type"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "type",
          "schema_version",
          "label"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.types.register",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.groups.update",
      ["domain"] = "synex.groups",
      ["errors"] = {
        "VALIDATION_FAILED",
        "CHARACTER_NOT_FOUND",
        "GROUP_NOT_FOUND",
        "GROUP_INACTIVE",
        "MEMBERSHIP_NOT_FOUND",
        "MEMBERSHIP_ALREADY_EXISTS",
        "MEMBERSHIP_NOT_ACTIVE",
        "GRADE_NOT_FOUND",
        "ROLE_NOT_FOUND",
        "RELATIONSHIP_INVALID",
        "HIERARCHY_CYCLE",
        "REPORTING_CYCLE",
        "INSUFFICIENT_PERMISSION",
        "INVALID_SCOPE",
        "INVALID_TRANSITION",
        "TARGET_GRADE_TOO_HIGH",
        "ROLE_EXCLUSIVE_CONFLICT",
        "MEMBER_LIMIT_REACHED",
        "GRADE_CAPACITY_REACHED",
        "APPROVAL_REQUIRED",
        "CONCURRENT_MODIFICATION",
        "IDEMPOTENCY_CONFLICT",
        "OPERATION_IN_PROGRESS",
        "HOOK_REJECTED",
        "DATABASE_ERROR",
        "GROUP_TYPE_NOT_FOUND",
        "GROUP_TYPE_INACTIVE",
        "GROUP_TYPE_STATIC",
        "STATIC_DEFINITION_REQUIRED",
        "GROUP_EXISTS",
        "GROUP_HAS_ACTIVE_CHILDREN",
        "GROUP_HAS_ACTIVE_MEMBERS",
        "GROUP_HAS_ACTIVE_RELATIONSHIPS",
        "GROUP_HAS_ACTIVE_WORKFLOWS",
        "TYPE_OWNER_CONFLICT",
        "PARENT_GROUP_NOT_FOUND",
        "PARENT_GROUP_INACTIVE",
        "RELATIONSHIPS_DISABLED",
        "RELATIONSHIP_TYPE_NOT_FOUND",
        "RELATIONSHIP_TYPE_INACTIVE",
        "RELATIONSHIP_EXISTS",
        "RELATIONSHIP_CYCLE",
        "RELATIONSHIP_GRAPH_TOO_DEEP",
        "RELATIONSHIP_NOT_FOUND",
        "HIERARCHY_DISABLED",
        "HIERARCHY_INVALID",
        "HIERARCHY_DEPTH_EXCEEDED",
        "GRADE_EXISTS",
        "GRADE_IN_USE",
        "ROLE_EXISTS",
        "ROLE_IN_USE",
        "CAPABILITY_SOURCE_INACTIVE",
        "READ_MODEL_TOO_LARGE"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["actor_character_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["description"] = {
            ["maxLength"] = 1024,
            ["type"] = "string"
          },
          ["expected_version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["idempotency_key"] = {
            ["maxLength"] = 128,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["label"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["name"] = {
            ["maxLength"] = 96,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["parent_group_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["reason"] = {
            ["maxLength"] = 256,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["slug"] = {
            ["maxLength"] = 64,
            ["minLength"] = 2,
            ["pattern"] = "^[a-z][a-z0-9_-]*$",
            ["type"] = "string"
          },
          ["status"] = {
            ["enum"] = {
              "active",
              "suspended",
              "ACTIVE",
              "SUSPENDED"
            },
            ["type"] = "string"
          },
          ["visibility"] = {
            ["enum"] = {
              "public",
              "internal",
              "private",
              "hidden"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "idempotency_key",
          "actor_character_id",
          "group_id",
          "expected_version"
        },
        ["type"] = "object"
      },
      ["kind"] = "rpc",
      ["name"] = "synex.groups.update",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["entity_id"] = {
            ["maxLength"] = 48,
            ["minLength"] = 8,
            ["pattern"] = "^[A-Za-z0-9][A-Za-z0-9_.:%-]*$",
            ["type"] = "string"
          },
          ["entity_type"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["replayed"] = {
            ["type"] = "boolean"
          },
          ["status"] = {
            ["maxLength"] = 32,
            ["minLength"] = 2,
            ["type"] = "string"
          },
          ["version"] = {
            ["maximum"] = 2147483647,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "entity_id",
          "entity_type",
          "status",
          "version",
          "replayed"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_groups",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.characters.create",
      ["domain"] = "synex.core",
      ["errors"] = {
        "CAPABILITY_DENIED",
        "CHARACTER_SLOT_UNAVAILABLE",
        "DATABASE_ERROR",
        "INVALID_CHARACTER_NAME",
        "INVALID_SESSION_STATE",
        "SESSION_NOT_FOUND",
        "SESSION_PERSISTENCE_PENDING"
      },
      ["idempotent"] = false,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["dateOfBirth"] = {
            ["maxLength"] = 10,
            ["minLength"] = 10,
            ["type"] = "string"
          },
          ["firstName"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["lastName"] = {
            ["maxLength"] = 64,
            ["minLength"] = 1,
            ["type"] = "string"
          },
          ["sessionId"] = {
            ["maxLength"] = 36,
            ["type"] = "string"
          },
          ["slot"] = {
            ["maximum"] = 64,
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "sessionId",
          "slot",
          "firstName",
          "lastName"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.identity.characters.create",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["dateOfBirth"] = {
            ["maxLength"] = 10,
            ["type"] = "string"
          },
          ["firstName"] = {
            ["maxLength"] = 64,
            ["type"] = "string"
          },
          ["id"] = {
            ["maxLength"] = 36,
            ["type"] = "string"
          },
          ["lastName"] = {
            ["maxLength"] = 64,
            ["type"] = "string"
          },
          ["metadata"] = {
            ["type"] = "object"
          },
          ["slot"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          },
          ["status"] = {
            ["maxLength"] = 16,
            ["type"] = "string"
          },
          ["userId"] = {
            ["maxLength"] = 36,
            ["type"] = "string"
          },
          ["version"] = {
            ["minimum"] = 1,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "id",
          "userId",
          "slot",
          "status",
          "firstName",
          "lastName",
          "metadata",
          "version"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_core",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.characters.delete",
      ["domain"] = "synex.core",
      ["errors"] = {
        "CAPABILITY_DENIED",
        "CHARACTER_DELETE_BLOCKED",
        "CHARACTER_DELETE_PREFLIGHT_FAILED",
        "CHARACTER_NOT_FOUND",
        "DATABASE_ERROR",
        "INVALID_SESSION_STATE",
        "SESSION_NOT_FOUND",
        "SESSION_PERSISTENCE_PENDING"
      },
      ["idempotent"] = false,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["characterId"] = {
            ["maxLength"] = 36,
            ["type"] = "string"
          },
          ["sessionId"] = {
            ["maxLength"] = 36,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "sessionId",
          "characterId"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.identity.characters.delete",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["characterId"] = {
            ["maxLength"] = 36,
            ["type"] = "string"
          },
          ["planId"] = {
            ["maxLength"] = 36,
            ["type"] = "string"
          },
          ["state"] = {
            ["enum"] = {
              "completed",
              "reconciling"
            },
            ["type"] = "string"
          }
        },
        ["required"] = {
          "planId",
          "characterId",
          "state"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_core",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.identity.read",
      ["domain"] = "synex.core",
      ["errors"] = {
        "CAPABILITY_DENIED",
        "DATABASE_ERROR",
        "SESSION_NOT_FOUND"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["sessionId"] = {
            ["maxLength"] = 36,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "sessionId"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.identity.characters.list",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["characters"] = {
            ["items"] = {
              ["additionalProperties"] = false,
              ["properties"] = {
                ["dateOfBirth"] = {
                  ["maxLength"] = 10,
                  ["type"] = "string"
                },
                ["firstName"] = {
                  ["maxLength"] = 64,
                  ["type"] = "string"
                },
                ["id"] = {
                  ["maxLength"] = 36,
                  ["type"] = "string"
                },
                ["lastName"] = {
                  ["maxLength"] = 64,
                  ["type"] = "string"
                },
                ["metadata"] = {
                  ["type"] = "object"
                },
                ["slot"] = {
                  ["minimum"] = 1,
                  ["type"] = "integer"
                },
                ["status"] = {
                  ["maxLength"] = 16,
                  ["type"] = "string"
                },
                ["userId"] = {
                  ["maxLength"] = 36,
                  ["type"] = "string"
                },
                ["version"] = {
                  ["minimum"] = 1,
                  ["type"] = "integer"
                }
              },
              ["required"] = {
                "id",
                "userId",
                "slot",
                "status",
                "firstName",
                "lastName",
                "metadata",
                "version"
              },
              ["type"] = "object"
            },
            ["maxItems"] = 64,
            ["type"] = "array"
          }
        },
        ["required"] = {
          "characters"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_core",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.characters.select",
      ["domain"] = "synex.core",
      ["errors"] = {
        "CAPABILITY_DENIED",
        "CHARACTER_ALREADY_ACTIVE",
        "CHARACTER_LOAD_FAILED",
        "CHARACTER_NOT_FOUND",
        "INVALID_SESSION_STATE",
        "SESSION_NOT_FOUND",
        "SESSION_PERSISTENCE_PENDING"
      },
      ["idempotent"] = false,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["characterId"] = {
            ["maxLength"] = 36,
            ["type"] = "string"
          },
          ["sessionId"] = {
            ["maxLength"] = 36,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "sessionId",
          "characterId"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.identity.characters.select",
      ["network"] = "none",
      ["output"] = {
        ["properties"] = {
          ["character"] = {
            ["type"] = "object"
          },
          ["session"] = {
            ["type"] = "object"
          }
        },
        ["required"] = {
          "session",
          "character"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_core",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.identity.read",
      ["domain"] = "synex.core",
      ["errors"] = {
        "CAPABILITY_DENIED",
        "NOT_READY"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["source"] = {
            ["minimum"] = 0,
            ["type"] = "integer"
          }
        },
        ["required"] = {
          "source"
        },
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.identity.session.by_source",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["found"] = {
            ["type"] = "boolean"
          },
          ["session"] = {
            ["additionalProperties"] = false,
            ["properties"] = {
              ["characterId"] = {
                ["maxLength"] = 36,
                ["type"] = "string"
              },
              ["id"] = {
                ["maxLength"] = 36,
                ["type"] = "string"
              },
              ["source"] = {
                ["minimum"] = 0,
                ["type"] = "integer"
              },
              ["sourceGeneration"] = {
                ["minimum"] = 1,
                ["type"] = "integer"
              },
              ["state"] = {
                ["maxLength"] = 32,
                ["type"] = "string"
              },
              ["userId"] = {
                ["maxLength"] = 36,
                ["type"] = "string"
              },
              ["version"] = {
                ["minimum"] = 1,
                ["type"] = "integer"
              }
            },
            ["required"] = {
              "id",
              "userId",
              "state",
              "source",
              "sourceGeneration",
              "version"
            },
            ["type"] = "object"
          }
        },
        ["required"] = {
          "found"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_core",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.runtime.read",
      ["domain"] = "synex.core",
      ["errors"] = {
        "CAPABILITY_DENIED",
        "NOT_READY"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {},
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.runtime.status",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["operational"] = {
            ["type"] = "boolean"
          },
          ["reasons"] = {
            ["type"] = "object"
          },
          ["recentTransitions"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 64,
            ["type"] = "array"
          },
          ["revision"] = {
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["state"] = {
            ["maxLength"] = 32,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "state",
          "revision",
          "operational",
          "reasons",
          "recentTransitions"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_core",
      ["stability"] = "experimental",
      ["version"] = "1.0.0"
    },
    {
      ["capability"] = "synex.runtime.read",
      ["domain"] = "synex.core",
      ["errors"] = {
        "CAPABILITY_DENIED",
        "NOT_READY"
      },
      ["idempotent"] = true,
      ["input"] = {
        ["additionalProperties"] = false,
        ["properties"] = {},
        ["type"] = "object"
      },
      ["kind"] = "service",
      ["name"] = "synex.runtime.status",
      ["network"] = "none",
      ["output"] = {
        ["additionalProperties"] = false,
        ["properties"] = {
          ["operational"] = {
            ["type"] = "boolean"
          },
          ["playerAdmission"] = {
            ["type"] = "boolean"
          },
          ["reasons"] = {
            ["type"] = "object"
          },
          ["recentTransitions"] = {
            ["items"] = {
              ["type"] = "object"
            },
            ["maxItems"] = 64,
            ["type"] = "array"
          },
          ["revision"] = {
            ["minimum"] = 0,
            ["type"] = "integer"
          },
          ["state"] = {
            ["maxLength"] = 32,
            ["type"] = "string"
          }
        },
        ["required"] = {
          "state",
          "revision",
          "operational",
          "playerAdmission",
          "reasons",
          "recentTransitions"
        },
        ["type"] = "object"
      },
      ["provider"] = "synex_core",
      ["stability"] = "experimental",
      ["version"] = "2.0.0"
    }
  },
  ["schema"] = 1,
  ["sourceHash"] = "b9ccdd473cdee6e47ce04d7615afe12f1d3f9ce0a103108f79cba44274f4183c"
}
