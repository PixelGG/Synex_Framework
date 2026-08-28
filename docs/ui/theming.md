# Theming

Synex UI themes through CSS custom properties and root data attributes. A theme
changes presentation without replacing component behavior.

## Supported axes

- design tokens: primitive, semantic, and component layers;
- material choice;
- quality profile;
- UI scale;
- density;
- reduced motion;
- reduced transparency;
- high contrast.

The current shipped visual identity is dark. A light theme is not part of the
current runtime contract and must not be implied by a generic `theme` prop.

## Consumer overrides

Scope overrides to the domain application root and prefer semantic/component
tokens:

```css
.identity-app {
  --sx-color-accent: var(--identity-accent, var(--sx-p-cyan-400));
  --sx-button-hover: var(--identity-accent-hover, var(--sx-p-cyan-500));
}
```

Do not modify package source in a consumer or copy a component stylesheet. Do
not override structural safety rules for `html`, `body`, `#root`, focus layers,
motion reduction, or minimum interaction targets.

## Brand consistency

Domain accents may distinguish a workflow, but they retain Synex geometry,
typography, focus language, spacing rhythm, semantic status colors, and input
behavior. Themes must not redefine warning as success, make disabled controls
look active, or remove focus visibility.

## Runtime preferences

Cosmetic preferences are versioned and stored client-locally. They are validated
on load and updates; invalid values fall back to defaults. They are not account
state and do not require SQL. A schema change needs explicit migration or reset
behavior.
