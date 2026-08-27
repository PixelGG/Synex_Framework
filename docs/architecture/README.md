# Synex architecture

Synex separates a small runtime kernel from downstream foundation and gameplay resources. The kernel owns lifecycle, identity, contracts, capability policy, persistent RBAC and connection-access records, communication primitives, persistence ports, the effective retention policy and audit archive mirror, and diagnostics.

The accepted Production-Beta boundary contains one frozen `synex_core` tree only. `synex_groups` is the Experimental Alpha Organizations Engine, `synex_accounts` is the server-only Experimental Alpha Financial Engine, and `synex_entities` is the server-only Development / Experimental Alpha Entity Authority Engine. The optional read-only `synex_control` operations surface is also Development / Experimental Alpha: automated provider/transport/NUI gates exist, but real FXServer provider lifecycle and CEF/client acceptance remain open. Bridges, libraries, SDK integrations, examples, gameplay resources, and other downstream entries remain rework snapshots or scaffolds. None is supported by the Core decision.

The authoritative architecture references are:

- [Runtime model](runtime.md)
- [Security model](security.md)
- [Contract and API model](contracts.md)
- [Read-only Control architecture](../control/architecture.md)
- [Architecture decisions](decisions/README.md)

The runtime is designed for Cfx.re's resource model. It does not claim to sandbox arbitrary server code, make client input trustworthy, or turn a network ID into durable identity. Protected facade calls cross a caller/capability gateway; domain RPC additionally crosses its generated contract boundary.

## Dependency direction

```mermaid
flowchart TD
    CFX[Cfx.re runtime] --> CORE[synex_core]
    DB[(MariaDB 11.8.8)] --> OX[oxmysql 2.14.1]
    OX --> CORE
    CONTRACTS[Canonical JSON contracts] --> GENERATED[Generated runtime descriptors]
    GENERATED --> CORE
    GENERATED -. experimental .-> SDK[SDK rework snapshots]
    CORE -. experimental API and DataPort .-> GROUPS[synex_groups Experimental Alpha]
    CORE -. server-only experimental API .-> ACCOUNTS[synex_accounts Experimental Alpha]
    OX --> ACCOUNTS
    CORE -. server-only experimental API and DataPort .-> ENTITIES[synex_entities Experimental Alpha]
    OX --> ENTITIES
    CFX -. OneSync runtime .-> ENTITIES
    GROUPS -. read-only provider registration .-> CORE
    ACCOUNTS -. read-only provider registration .-> CORE
    ENTITIES -. read-only provider registration .-> CORE
    BRIDGE[synex_bridge Experimental Alpha] -. compatibility provider registration .-> CORE
    CORE -. bounded provider read API .-> CONTROL[synex_control Experimental Alpha]
    CONTROL -. self-health provider registration .-> CORE
    CORE -. experimental API .-> REWORK[Other non-Core snapshots]
    OX -. legacy snapshot persistence .-> REWORK
```

Solid arrows show the accepted Core profile's runtime requirements or generated-input flow. Dotted arrows show experimental relationships outside certification. Groups has only one direct runtime dependency, `synex_core`; Core's caller-bound DataPort validates its SQL against Groups-owned tables declared in the manifest. Its server-authoritative API has 70 server-only contracts plus one bounded, active-session-derived `self.snapshot` client projection. Extension registries use a mandatory begin-per-owner-epoch synchronization session so stale registrations, hydration, and stop cleanup cannot cross a resource restart. Entities declares `synex_core`, `oxmysql`, and OneSync as required runtime dependencies. Groups, Accounts, Entities and the optional Bridge compatibility adapter register their own bounded read-only diagnostic providers with the Core registry; Control reads that registry and contributes only its own process-health provider. Neither implementation nor repository checks replace the domains' or Control's open live acceptance gates. Other snapshots still require rework and may retain older direct-adapter boundaries. No downstream resource receives mutable Core registries or implementation objects, and cross-domain behavior uses experimental contracts or versioned services.
