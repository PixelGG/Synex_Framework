# Compatibility boundary

`synex_interact` registers a bounded `PARTIAL` interaction-normalization adapter with `synex_bridge` when Bridge is available. It accepts a closed subset of `ox_target`, `qb-target` and `qtarget`-shaped selectors/options and projects declarative compatibility metadata. It does **not** install legacy exports, zones, callbacks or a certified drop-in target mapping.

## Enforced adapter properties

The checked-in normalizer:

- preserves the real consumer resource through Bridge;
- accepts only bounded model/entity/world selectors and at most the visible-intent limit;
- treats groups, items and legacy visibility data as observed-only hints;
- permits an action only through a consumer-owned typed adapter;
- rejects arbitrary `onSelect`, event callbacks and foreign adapters;
- reports its surface as `PARTIAL` with explicit unsupported constructs.

Legacy target visibility and `canInteract` callbacks are UX filters only. A legacy server event cannot bypass the typed adapter/lease boundary, and Bridge is not granted superuser authority.

An executable legacy mapping would still need a reviewed Bridge profile/catalog, lifecycle cleanup and live acceptance while retaining Interact lease/policy validation. Until that exists, integrations with `ox_target`, `qb-target` and `qtarget` remain **normalization-only / not certified**. Do not advertise drop-in compatibility.
