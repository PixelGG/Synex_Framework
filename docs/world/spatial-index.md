# Spatial index

The runtime index is a bounded hierarchical spatial hash. It avoids scanning the complete registry for each hot position query.

## Layout

- fine grid: 32-unit cells;
- coarse grid: 256-unit cells;
- maximum indexed cells per object: 256;
- maximum bounded global fallback objects: 128.

An object is first assigned to fine cells covering its compiled bounds. Large coverage falls back to coarse cells. Objects still covering too many coarse cells enter the bounded global set. Exhausting the global set fails activation with `SPATIAL_INDEX_DEGRADED` rather than silently creating an unbounded fallback.

## Query pipeline

```text
server position / radius
  -> relevant fine and coarse cells
  -> deduplicated candidate keys plus bounded global set
  -> optional kind/tag/map-availability filter
  -> exact geometry or bounds-distance test
  -> deterministic bounded results
```

`queryAt` performs exact containment. `queryNearby` uses distance to compiled bounds and accepts radii from 0 through 1000. The index caps a candidate set at 4,096 and a normal result set at 256.

Authoritative `WorldContext` resolution uses a stricter 128-match overlap bound. Reaching that bound returns `QUERY_LIMIT_EXCEEDED` instead of constructing a partial location/room/zone context from truncated results.

Runtime filters currently support one `kind`, an all-required tag list and `availableOnly`. Query metadata reports candidate count and truncation.

## Diagnostics

The index tracks entry count, fine/coarse cell count, global entries, query count, average/maximum candidates and a bounded list of hottest cells. These values are operational diagnostics, not a production capacity claim.

The offline `world locate` and `world overlaps` commands inspect repository definitions, not the live runtime index. `overlaps` is an axis-aligned broad-phase report and explicitly requires runtime confirmation.
