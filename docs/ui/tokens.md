# Design tokens

Synex UI uses three token layers. Components consume component or semantic
tokens, not raw color and spacing values.

```text
primitive values -> semantic roles -> component contracts
```

## Primitive layer

Primitive tokens define the raw palette, spacing steps, type scale, radii,
border widths, shadows, durations, easing curves, and layer values. They are
implementation values without product meaning.

Examples of primitive categories include graphite and signal color scales,
spacing steps, type sizes and weights, geometry, opacity, blur, shadow, and
motion durations.

Opacity is a finite scale rather than a collection of component literals:

```text
--sx-p-opacity-0
--sx-p-opacity-1
--sx-p-opacity-58
--sx-p-opacity-65
--sx-p-opacity-70
--sx-p-opacity-72
--sx-p-opacity-80
--sx-p-opacity-100
```

Components consume semantic or component aliases such as
`--sx-opacity-disabled`, `--sx-button-disabled-opacity`, and
`--sx-list-disabled-opacity`; consumers should not copy the numeric values.

The public motion speeds are `instant`, `fast`, `normal`, and `slow`. Their
current tuned values are exposed through `motionDurationMilliseconds` for
non-CSS coordination and through these CSS variables for presentation:

```text
--sx-motion-duration-instant
--sx-motion-duration-fast
--sx-motion-duration-normal
--sx-motion-duration-slow
```

## Semantic layer

Semantic tokens assign intent: canvas, surface, text, border, focus, accent,
positive, warning, danger, disabled, selection, and overlay roles. Theme and
accessibility profiles override this layer so component source does not branch
on raw colors.

Motion follows the same rule. Consumers select `--sx-motion-enter`,
`--sx-motion-exit`, `--sx-motion-focus`, `--sx-motion-selection`,
`--sx-motion-confirmation`, `--sx-motion-loading`, `--sx-motion-drag`,
`--sx-motion-error`, or `--sx-motion-success` rather than choosing arbitrary
durations and curves. TypeScript consumers can use the matching `motionTokens`
map or `motionTransition()` helper.

Typography variants are `display`, `heading-1`, `heading-2`, `heading-3`,
`body`, `body-small`, `caption`, `label`, `numeric`, `code`, and `monospace`.
The `Typography` component binds these roles to the `.sx-type-*` classes while
allowing the caller to retain the correct native HTML element.

## Component layer

Component tokens describe local contracts such as button height, field border,
dialog width, menu row padding, table cell spacing, or focus rail color. This
layer may be overridden deliberately by a consumer theme while continuing to
reference semantic roles.

## Runtime axes

Token output responds to independent attributes on the UI root:

- quality: `LOW`, `BALANCED`, `HIGH`, `ULTRA`;
- scale: `85`, `100`, `115`, `125` percent;
- density: `compact` or `comfortable`;
- reduced motion;
- reduced transparency;
- high contrast.

These axes alter presentation, not semantics. A lower quality profile must not
remove labels, validation, focus visibility, hierarchy, or required actions.
Reduced motion also overrides the shared duration variables, so consumers of
the semantic motion API inherit the preference without component-specific
branches.

## Consumer guidance

Import the package stylesheet once at the application entry point:

```ts
import "@synex/ui/styles.css";
```

Place the application under one `.sx-root` element so the scoped base
typography, control inheritance, focus treatment, and scrollbar rules apply.
The package does not install an unscoped global reset.

Then use package components or documented `--sx-*` variables. Avoid copying raw
values into a domain stylesheet. Prefer a narrowly scoped semantic/component
override on the consuming application root.

```css
.garage-app {
  --sx-color-accent: var(--garage-accent, var(--sx-p-cyan-400));
  --sx-container-width: 70rem;
}
```

Do not override focus, minimum-target, closed-state, z-layer, or reduced-motion
contracts solely for visual preference.
