# Quality profiles

Quality profiles trade visual cost for material richness. They do not change
available features, focus behavior, labels, validation, or data semantics.

| Profile | Material policy | Motion policy |
| --- | --- | --- |
| `LOW` | Opaque surfaces, no backdrop blur, restrained shadows. | Essential state transitions only. |
| `BALANCED` | Limited translucency and depth with conservative effects. | Short interaction transitions. |
| `HIGH` | Controlled blur/depth for selected overlays. | Full designed transitions without idle excess. |
| `ULTRA` | Highest approved material fidelity for sparse priority surfaces. | Same semantic motion, with carefully richer finish. |

`reducedTransparency` overrides profile material richness and forces readable
opaque fallbacks. `reducedMotion` suppresses nonessential animation regardless of
profile. `highContrast` strengthens semantic separation independently.

## Runtime contract

The profile is a validated preference. Consumers read the active root attributes
and tokens; they should not implement parallel quality systems or guess device
capability from screen size. Automatic GPU profiling is not part of the current
contract.

## Acceptance gate

The table describes intended behavior, not measured performance. Visual parity,
gameplay readability, CEF fallback behavior, and GPU/paint cost for all profiles
are **NOT YET VERIFIED** in a real client.
