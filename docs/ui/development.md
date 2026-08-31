# Development and verification

The current UI package and runtime are **Experimental Alpha**. The automated
gates below protect this development boundary; they do not constitute a
live-support or production-maturity decision.

## Install and build

The repository uses the root npm lockfile and includes `@synex/ui` as a
workspace. Run repository-defined scripts from the repository root; package-only
work can use npm's workspace selector.

The package exposes separate builds:

- the library build emits ESM, declarations, and the shared stylesheet;
- the runtime build emits the local production NUI referenced by
  `fxmanifest.lua`;
- the playground build emits a browser-only Design Lab outside the FiveM
  resource package.

Do not edit generated `dist` or `web/dist` output by hand.

## Design Lab

The Design Lab uses an injected browser transport and deterministic scenarios.
It exists for component development, failure-state review, responsive layout,
and screenshot regression. It must never silently fall back to browser mocks in
the production NUI.

Required browser coverage includes closed, ready, loading, empty, success,
validation failure, runtime rejection, timeout, malformed response, long text,
large bounded data, owner restart, reduced motion, reduced transparency, high
contrast, and quality profiles. Representative viewports include 1080p, 1440p,
4K, 21:9, and 32:9.

The Notify fixture additionally covers all five tones, running/success/failed
progress, persistent and banner kinds, grouped/count forms, action hints, all
quality profiles and reduced-motion/transparency variants. Dedicated Signal
baselines are retained for mobile, 720p, 1080p, 1440p, 4K, 2560x1080,
3440x1440 and 5120x1440. They remain browser evidence, not a FiveM screenshot.

## Static review

Before live acceptance:

1. run type checking, tests, package builds, and visual regression defined by
   the repository;
2. verify the manifest references the built page and all local assets;
3. inspect production output for remote URLs, localhost paths, source maps,
   absolute `/assets` paths, and unsupported syntax;
4. verify runtime/browser bounds, message types, error codes, and static routes
   remain in parity;
5. verify `synex_control` still starts and operates without `synex_ui`;
6. run the repository security scan and the FiveM NUI resource checker.

## FiveM acceptance gate

Stop before claiming completion if no real client is available. The exact
production build must still pass:

- browser ready and initial synchronization;
- generic alert, confirm, input, form, select, menu, and context-menu flows;
- passive Notify show/update/dismiss/expire, queue promotion, action hints,
  exact active-surface ACK/retry, dismissing-surface exclusion, fail-closed
  F9/F10, quiet-context/reservation behavior, owner stop and UI-runtime
  reconciliation;
- accepted-but-`delivered = false` signal retention, later ready/full-sync
  recovery, no Notify sound, and critical-only once-per-content-generation
  fallback after immediate delivery failure or the 1,250 ms visibility-ACK gate;
- mouse, keyboard, controller, device switching, and adaptive hints;
- all close paths, owner stop, runtime stop/restart, browser reload, and
  reconnect;
- safe-zone behavior and 16:9, 21:9, 32:9, 1440p, and 4K checks;
- bright/dark/moving gameplay readability and glass fallbacks;
- malformed, oversized, duplicate, timed-out, cancelled, and stale messages;
- closed-idle, open-idle, interaction, large-data, and repeated-open performance;
- console/network errors, missing assets, focus leaks, listener growth, and
  retained browser work.

These real FiveM/CEF, safe-zone, glass-on-gameplay, controller/focus,
screen-reader/accessibility, and measured Resmon/performance checks are **NOT YET
VERIFIED**.
