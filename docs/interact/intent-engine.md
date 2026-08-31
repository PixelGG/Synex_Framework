# Intent Engine

The Intent Engine selects the most relevant visible action from the current observed candidates. Selection improves UX; it is not authorization.

## Scoring inputs

The checked-in engine combines normalized, documented terms:

- declared base priority and specificity;
- gaze alignment, distance, slot alignment and exact-ray evidence;
- continuity and bounded recent-history bonuses;
- movement, unknown-condition and ambiguity penalties.

Candidates are rejected early when the actor is dead/ragdolled, the target is known occluded, the slot radius is exceeded, or a visibility condition is false. An unknown declarative observation is penalized rather than treated as a server permission grant. A missing, pending, saturated, timed-out, failed, or malformed custom evaluator is fail-closed and rejects that candidate as `CONDITION_UNKNOWN` until a valid cached result exists.

## Client-safe decision inspection

The caller-bound client diagnostics expose aggregate decision counts, not rejected candidate records. Rejection codes cover `TOO_FAR`, `OCCLUDED`, `WRONG_ACTOR_STATE`, `TARGET_STATE`, `SLOT_BUSY`, `SLOT_DISABLED`, `SLOT_MISMATCH`, `CONDITION_FALSE` and fail-closed custom `CONDITION_UNKNOWN`. `CONDITION_UNKNOWN` remains an advisory only for a declarative condition whose observed value cannot be compared. `AMBIGUOUS` is an advisory when the two highest viable primary scores remain within the configured switch threshold.

Diagnostic items contain only stable codes and bounded counts. They do not include candidate, player, entity, lease or session IDs, target payloads, or coordinates. The diagnostic intent ranking retains namespaced intent keys and score terms so a developer can explain arbitration without receiving an authority object.

## Determinism and hysteresis

Ties resolve by score, specificity, base priority, intent key and candidate ID. The current intent remains sticky until a challenger exceeds the switch threshold and survives the minimum dwell. This prevents prompts from rapidly oscillating when nearby candidates have similar scores.

The engine exposes one primary intent and at most five alternatives, matching the six-intent presentation bound. `INTERACT_MORE` opens the Action Bloom for those already relevant alternatives; it does not enter a target mode or enumerate the world.

## Conditions

Declarative visibility conditions support `eq`, `ne`, `lt`, `lte`, `gt`, `gte`, `truthy`, `falsy` and `contains` over a closed, depth-bounded observed environment. Custom visibility evaluator references are compiler-checked against the bundle owner's namespace and resolved only through that owner's client registry. They execute asynchronously against copied observed context, produce a boolean UX hint, and never satisfy a server dependency or authorization check.

The server evaluator registry has a different role: Smart Object/slot availability policies and Action Graph evaluator conditions depend on a server-registered callback and fail closed when it is unavailable. Keeping the registries context-separated avoids treating a client predicate as server evidence and avoids requiring an unused server duplicate for visibility-only conditions.

Execution policy is resolved from the canonical server bundle and rechecked for lease issuance and activation. Never place an entitlement only in `visibilityConditions`.

## Deterministic fixture replay

`SynexInteractIntent.replay(frames, options)` replays at most 64 monotonic, bounded context fixtures through a fresh isolated Intent Engine. It returns intent keys, scores and the same aggregate decision inspection, while omitting candidate/target IDs and coordinates. Replay never mutates the live engine, requests a lease, invokes a contract or executes an Action Graph. It exists for headless regression fixtures and local diagnostics only; recorded client context is not authority evidence.
