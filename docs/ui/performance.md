# Performance

The runtime is event-driven and bounded. Visual richness must degrade before
interaction quality does.

## Closed budget

With no open surface and no active external lease, the React surface tree is
unmounted. The runtime root remains empty, transparent, and pointer-free;
controller polling is inactive; and no decorative animation or periodic UI
timer runs. The frame retains no focus. A separate resource-owned NUI may keep
bounded input arbitration active only while it holds the active arbiter lease.
Native focus is released when no valid lease remains. A fully idle NUI that
still paints or polls is a regression.

## Open-state rules

- Send a bounded synchronization snapshot after readiness, then targeted
  updates instead of per-frame messages.
- Batch list data and avoid one message per row.
- Keep effects symmetric under React Strict Mode.
- Remove global listeners, observers, timeouts, and animation frames on cleanup.
- Virtualize only measured large collections; do not virtualize small lists by
  default.
- Avoid overlapping backdrop filters and continuously animated blur.
- Disable decorative motion for reduced motion and simplify materials for lower
  quality profiles.
- Do not put large base64 media or remote assets into messages.

## Measurement scenarios

Measure the exact production build in these states:

1. closed idle;
2. one open idle surface;
3. keyboard/mouse/controller interaction;
4. worst realistic bounded form, menu, list, grid, and table;
5. repeated open/close cycles;
6. owner stop and runtime restart;
7. LOW through ULTRA, reduced transparency, and reduced motion.

Use `resmon` for resource context, CEF DevTools for browser CPU/memory/rendering,
the Cfx profiler for Lua work, and the React profiler when rerenders are
suspected. Establish scenario-specific budgets from representative hardware;
do not publish invented FPS or resource-time claims.

## Acceptance gate

Browser build size and visual tests are not gameplay performance evidence. CPU,
memory, paint, GPU filter cost, listener growth, and closed-idle behavior in the
actual FiveM/CEF runtime are **NOT YET VERIFIED**.
