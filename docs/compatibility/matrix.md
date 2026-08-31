# Compatibility matrix

> [!WARNING]
> This file is generated from the checked-in bridge catalog. A surface status is bounded to its named provider, mode, version evidence, and tests; it is not deployment certification.

Catalog aggregate: **PARTIAL**. No compatibility profile may be treated as certified without exact tested-version evidence.

| Provider | Provider version | Target framework API range | Surface | Scope | Type | Status | Legacy version | Native mapping | Adapter operation → native capabilities | Catalog operation → native capabilities | Modes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ESX | `0.1.0` | unreviewed | `esx.client.callback_invocation` | client | callback | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.client.notification` | client | method | **PARTIAL** | — | `synex.notify.compatibility@1` | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.client.notification_events` | client | event | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| ESX | `0.1.0` | unreviewed | `esx.client.player_data` | client | object | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.server.callback_registration` | server | callback | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.server.identifier_player_lookup` | server | method | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.server.permission_admin` | server | method | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| ESX | `0.1.0` | unreviewed | `esx.server.player_enumeration` | server | method | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.server.player_lookup` | server | method | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.server.shared_object` | server | object | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.shared.account_update_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.shared.job_update_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.shared.lifecycle_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.xplayer.accounts_read` | server | method | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.xplayer.custom_accounts` | server | method | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.xplayer.duty_mutation` | server | method | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| ESX | `0.1.0` | unreviewed | `esx.xplayer.inventory` | server | method | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| ESX | `0.1.0` | unreviewed | `esx.xplayer.job_mutation` | server | method | **PARTIAL** | — | `synex.groups.compatibility.set_primary_grade@1` | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.xplayer.job_read` | server | method | **PARTIAL** | — | — | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.xplayer.metadata_mutation` | server | method | **PARTIAL** | — | `synex_bridge.compatibility_metadata@1` | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.xplayer.money_mutation` | server | method | **PARTIAL** | — | `synex.accounts.transfer_v2/mint_v2/burn_v2@2` | — | — | compat, silent |
| ESX | `0.1.0` | unreviewed | `esx.xplayer.permission_group` | server | method | **PARTIAL** | — | `synex.permissions.check@1` | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.client.callback_invocation` | client | callback | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.client.notification` | client | method | **PARTIAL** | — | `synex.notify.compatibility@1` | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.client.notification_event` | client | event | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QB | `0.1.0` | unreviewed | `qb.client.player_data` | client | object | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.player.duty_mutation` | server | method | **PARTIAL** | — | `synex.groups.duty@1` | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.player.group_mutation` | server | method | **PARTIAL** | — | `synex.groups.compatibility.set_primary_grade@1` | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.player.metadata_mutation` | server | method | **PARTIAL** | — | `synex_bridge.compatibility_metadata@1` | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.player.money_mutation` | server | method | **PARTIAL** | — | `synex.accounts.transfer_v2/mint_v2/burn_v2@2` | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.server.callback_registration` | server | callback | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.server.core_object` | server | object | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.server.core_object_filtering` | server | object | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.server.identifier_player_lookup` | server | method | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.server.permission_admin` | server | method | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QB | `0.1.0` | unreviewed | `qb.server.permission_view` | server | method | **PARTIAL** | — | `synex.permissions.check@1` | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.server.player_enumeration` | server | method | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.server.player_lookup` | server | method | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.shared.duty_update_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.shared.gang_update_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.shared.gangs_registry` | shared | object | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QB | `0.1.0` | unreviewed | `qb.shared.items_registry` | shared | object | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QB | `0.1.0` | unreviewed | `qb.shared.job_update_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.shared.jobs_registry` | shared | object | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QB | `0.1.0` | unreviewed | `qb.shared.lifecycle_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.shared.money_update_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| QB | `0.1.0` | unreviewed | `qb.shared.vehicles_registry` | shared | object | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QBX | `0.1.0` | unreviewed | `qbx.client.notification` | client | export | **PARTIAL** | — | `synex.notify.compatibility@1` | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.client.notification_event` | client | event | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QBX | `0.1.0` | unreviewed | `qbx.client.player_data` | client | export | **PARTIAL** | — | — | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.compat.qb_core_object` | shared | object | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QBX | `0.1.0` | unreviewed | `qbx.player.metadata_mutation` | server | export | **PARTIAL** | — | `synex_bridge.compatibility_metadata@1` | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.callback_registration` | server | callback | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QBX | `0.1.0` | unreviewed | `qbx.server.duty_mutation` | server | method | **PARTIAL** | — | `synex.groups.duty@1` | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.gangs_registry` | server | export | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QBX | `0.1.0` | unreviewed | `qbx.server.group_mutation` | server | method | **PARTIAL** | — | `synex.groups.compatibility.set_primary_grade@1` | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.groups_read` | server | export | **PARTIAL** | — | — | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.identifier_player_lookup` | server | export | **PARTIAL** | — | — | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.jobs_registry` | server | export | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QBX | `0.1.0` | unreviewed | `qbx.server.metadata_read` | server | export | **PARTIAL** | — | `synex_bridge.compatibility_metadata@1` | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.money_mutation` | server | export | **PARTIAL** | — | `synex.accounts.transfer_v2/mint_v2/burn_v2@2` | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.money_read` | server | export | **PARTIAL** | — | — | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.offline_player_lookup` | server | export | **PARTIAL** | — | — | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.permission_admin` | server | export | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QBX | `0.1.0` | unreviewed | `qbx.server.player_lookup` | server | export | **PARTIAL** | — | — | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.primary_group_mutation` | server | export | **PARTIAL** | — | `synex.groups.compatibility.set_primary_grade@1` | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.server.routing_bucket_management` | server | export | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QBX | `0.1.0` | unreviewed | `qbx.server.vehicles_registry` | server | export | **UNSUPPORTED** | — | — | — | — | compat, silent, strict |
| QBX | `0.1.0` | unreviewed | `qbx.shared.duty_update_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.shared.group_update_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.shared.lifecycle_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |
| QBX | `0.1.0` | unreviewed | `qbx.shared.money_update_events` | shared | event | **PARTIAL** | — | — | — | — | compat, silent |

## Central account aliases

Providers declare supported alias names only. Currency, account key, role, and minor-unit scale are authoritative central mapping values; duplicate provider-scoped targets fail closed.

| Provider | Legacy alias | Currency | Account key | Role | Minor unit | Status |
| --- | --- | --- | --- | --- | --- | --- |
| ESX | `bank` | `usd` | `bank` | asset | 0 | **PARTIAL** |
| ESX | `cash` | `usd` | `cash` | asset | 0 | **PARTIAL** |
| QB | `bank` | `usd` | `bank` | asset | 0 | **PARTIAL** |
| QB | `cash` | `usd` | `cash` | asset | 0 | **PARTIAL** |
| QBX | `bank` | `usd` | `bank` | asset | 0 | **PARTIAL** |
| QBX | `cash` | `usd` | `cash` | asset | 0 | **PARTIAL** |

Status model:

- **CERTIFIED** — exact profile and tested-version evidence satisfy every required surface; never inferred by scanning.
- **COMPATIBLE** — the bounded cataloged behavior is compatible, without deployment certification.
- **PARTIAL** — only the named subset or semantics exist.
- **UNSUPPORTED** — the surface is rejected or intentionally absent.
- **UNKNOWN** — evidence is absent or insufficient.

The authoritative artifacts are under [`libraries/synex_bridge/compatibility`](../../libraries/synex_bridge/compatibility/). Regenerate this table with:

```text
node --experimental-strip-types tools/codegen/generate-compatibility-matrix.ts
```
