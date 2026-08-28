# Components

All public components are exported from `@synex/ui`. Import the stylesheet once
at the application entry point; components do not own FiveM focus or domain
state.

```tsx
import "@synex/ui/styles.css";
import { Button, Stack, Surface } from "@synex/ui";
```

## Catalog

| Family | Components |
| --- | --- |
| Typography | `Typography` with semantic display, heading, body, label, numeric, code, and monospace variants |
| Foundation | `Surface`, `Stack`, `Inline`, `Grid`, `Container`, `Divider`, `ScrollArea`, `Spacer`, `AspectBox` |
| Actions | `Button`, `IconButton`, `SplitButton`, `ActionRow` |
| Forms | `Input`, `TextArea`, `NumberInput`, `SearchInput`, `PasswordInput`, `Checkbox`, `Radio`, `Switch`, `Slider`, `Field`, `FieldGroup`, `ValidationMessage` |
| Selection | `Select`, `Combobox`, `SearchSelect`, `MultiSelect`, `SegmentedControl` |
| Navigation | `Tabs`, `Breadcrumb`, `Pagination`, `Stepper`, `SideNav` |
| Overlays | `Dialog`, `AlertDialog`, `Popover`, `Drawer`, `Sheet`, `Modal` |
| Menus | `Menu`, `ContextMenu`, `Dropdown`, `Submenu`, `ActionMenu` |
| Feedback | `Spinner`, `Skeleton`, `ProgressBar`, `ProgressRing`, `LoadingOverlay`, `EmptyState`, visual `Toast` |
| Data display | `Table`, `DataList`, `KeyValueList`, `Badge`, `StatusBadge`, `Stat`, `Metric`, `Avatar`, `ListItem` |
| Utilities | `Tooltip`, `KeyHint`, `Shortcut`, `Icon`, `SynexIcon`, `VisuallyHidden` |
| Advanced | `CommandPalette`, `SearchList`, `VirtualList`, `VirtualGrid`, `Tree`, `DataGrid` primitives, drag/reorder primitives, chart tokens |

The library intentionally provides chart styling tokens rather than a charting
runtime. `Toast` is a visual primitive; it is not a global notification bus.

## Typography, formatting, and motion

`Typography` owns the shared reading hierarchy while preserving native HTML.
Its `variant` controls presentation and its optional `as` prop selects the
semantic element. Heading variants default to their matching heading levels;
numeric, code, and monospace variants use the locally bundled mono family with
tabular numbers.

```tsx
<Typography variant="heading-2">Account activity</Typography>
<Typography as="output" variant="numeric">{formattedBalance}</Typography>
```

Formatting helpers require an explicit locale. Currency additionally requires
an ISO currency code, and date/time helpers require an explicit time zone so a
FiveM client does not silently inherit workstation-dependent output.

```ts
const balance = formatCurrency(1250, {
  locale: "en-GB",
  currency: "GBP",
});

const timestamp = formatTime(updatedAt, {
  locale: "en-GB",
  timeZone: "UTC",
  hour: "2-digit",
  minute: "2-digit",
});
```

`formatPercent` treats the input as a fractional ratio (`0.25` becomes `25%`).
These helpers only present already-authorized values; they contain no economic,
permission, or other domain rules.

Use `motionTokens` or `motionTransition` for enter, exit, focus, selection,
confirmation, loading, drag, error, and success feedback. The semantic intent
selects a central instant/fast/normal/slow duration and easing contract. Domain
apps must not duplicate raw millisecond values.

```ts
const transition = motionTransition("enter", ["opacity", "transform"]);
```

Reduced-motion preferences collapse the non-instant duration tokens globally.
Motion should explain state and primarily animate opacity or transform; it must
not become idle decoration.

## Shared state model

Interactive components consistently expose normal, hover, active/pressed,
focus-visible, disabled, and—where meaningful—selected, invalid, loading,
expanded, and empty states. Controlled and uncontrolled props must not be mixed
for the same value during a component lifetime.

Visual state never replaces semantics: use `disabled`, `aria-invalid`,
`aria-selected`, `aria-checked`, `aria-expanded`, and the component's documented
callbacks rather than styling a generic element to look interactive.

## Foundation family

**Purpose.** Establish layout, reading measure, material hierarchy, scrolling,
and aspect constraints without turning structural containers into interactive
controls.

**Variants.** `Surface` supports the material variants documented in
[Materials](materials.md), elevations `0` through `4`, inset, and interactive
styling. Layout primitives accept explicit gaps/alignment; `Grid` accepts fixed
columns or a minimum column width; `Container` ranges from `sm` to `full`.

**States.** Foundation primitives are normally stateless. `interactive` changes
visual affordance only and does not add click or keyboard semantics.

**Keyboard.** Layout containers do not enter the tab order. `ScrollArea` must
remain reachable through its focusable descendants; add a labeled focusable
viewport only when the content itself requires keyboard scrolling.

**Gamepad.** Layout primitives receive no controller intent. Descendant controls
own navigation.

**Accessibility.** Preserve document structure and pass appropriate native
attributes. Decorative dividers stay hidden from assistive technology; semantic
separators must opt out of decorative behavior.

**Example.**

```tsx
<Container size="lg">
  <Surface material="elevated" elevation={2}>
    <Stack gap="var(--sx-space-5)">
      <header>Connection policy</header>
      <Divider />
      <Inline gap="var(--sx-space-3)" wrap>{actions}</Inline>
    </Stack>
  </Surface>
</Container>
```

**Anti-patterns.** Do not add `role="button"` to `Surface`; do not nest many
glass panes; do not use `Spacer` to compensate for a broken layout; do not force
a desktop pixel width; do not put the only scrollable content outside the safe
area.

## Action family

**Purpose.** Trigger immediate, named operations and organize primary/secondary
action hierarchy.

**Variants.** `Button` supports `primary`, `secondary`, `quiet`, `outline`, and
`danger`; `sm`, `md`, and `lg`; optional tone, leading/trailing content, loading,
and full width. `IconButton` requires a text `label`. `SplitButton` separates a
default action from related choices. `ActionRow` aligns action groups.

**States.** Normal, hover, active, focus-visible, disabled, loading, and menu-open
are visually distinct. Loading disables activation and exposes busy state.

**Keyboard.** Native buttons activate with Enter/Space. The split-menu trigger
exposes expanded state; its menu follows menu navigation.

**Gamepad.** Confirm activates the focused action; directional intent moves
between actions through the surrounding focus model. A destructive action must
not become the default solely for controller convenience.

**Accessibility.** Use a specific verb phrase. Icon-only actions require the
`label` prop. Loading text must remain available to assistive technology. Do not
encode danger using color alone.

**Example.**

```tsx
<ActionRow align="end" reverseOnNarrow>
  <Button variant="quiet" onClick={onCancel}>Cancel</Button>
  <Button loading={saving} onClick={onSave}>Save changes</Button>
</ActionRow>
```

**Anti-patterns.** Do not use a clickable `div`; do not show two competing
primary actions; do not use `IconButton` without a label; do not auto-retry a
domain mutation merely because a loading request timed out.

## Form family

**Purpose.** Collect structured user input while keeping labels, descriptions,
requirements, validation, and disabled state connected.

**Variants.** Text, textarea, number, search, password, checkbox, radio, switch,
and range controls are available. `Field` links one control to copy and
validation; `FieldGroup` provides a semantic fieldset/legend. Inputs support
native attributes in addition to package-specific size or value callbacks.

**States.** Empty, populated, hover, focus-visible, disabled, required, invalid,
and validation-message states are explicit. Password reveal is a named action;
checkbox supports mixed state; numeric and range controls enforce configured
bounds in the UI.

**Keyboard.** Native text editing is preserved. Tab moves between controls,
Space toggles checkbox/switch, radio groups use native behavior, and arrow keys
operate number/range controls. Do not intercept typing with global shortcuts.

**Gamepad.** Directional intent can adjust bounded choices and sliders; confirm
activates switches or enters text-edit mode. A keyboard path remains available
for all text fields.

**Accessibility.** Put controls inside `Field`/`FieldGroup`, supply a meaningful
label, and show specific validation text. `aria-invalid` and descriptive IDs are
connected by the components. Placeholder text is never the only label.

**Example.**

```tsx
<Field
  label="Display name"
  description="Shown to other players."
  validation={error}
  required
>
  <Input value={name} maxLength={48} onChange={(event) => setName(event.currentTarget.value)} />
</Field>
```

**Anti-patterns.** Do not put authorization or price validation only in React;
do not accept unbounded strings; do not clear server errors before a user can
read them; do not use a switch for a destructive one-time action.

## Selection family

**Purpose.** Choose one or more values from a known, bounded option set.

**Variants.** Native `Select` is the simplest single choice. `Combobox` and
`SearchSelect` filter labeled options. `MultiSelect` returns multiple values.
`SegmentedControl` presents a small mutually exclusive set.

**States.** Closed/open, query, active option, selected, disabled option, empty
results, and invalid selection are distinct. Controlled and uncontrolled values
are supported.

**Keyboard.** Combobox/search controls use Up/Down for the active option, Enter
to choose, and Escape to close. Multi-select opens a named checkbox dialog,
moves focus to its filter, and returns focus to the trigger on Escape. Segments
use roving focus and arrow navigation. Native select behavior is preserved.

**Gamepad.** Directional intents mirror option navigation and confirm commits
the active option. Back closes the list without committing a new value.

**Accessibility.** Single-selection search controls expose listbox, option,
expanded, and active-descendant semantics. Multi-select intentionally uses a
named non-modal dialog containing a checkbox group; it does not place
interactive checkboxes inside listbox options. Segments expose radio-group
state. Labels and descriptions remain visible, and disabled options are
skipped.

**Example.**

```tsx
<SegmentedControl
  label="Interface density"
  options={[
    { value: "compact", label: "Compact" },
    { value: "comfortable", label: "Comfortable" },
  ]}
  value={density}
  onValueChange={setDensity}
/>
```

**Anti-patterns.** Do not use a segmented control for many options; do not load
unbounded remote results directly into a menu; do not use display labels as
persistent identifiers; do not make selection imply a protected mutation.

## Navigation family

**Purpose.** Move within one product context without pretending to be browser
URL routing.

**Variants.** `Tabs` switches panels, `Breadcrumb` shows hierarchy,
`Pagination` moves through bounded pages, `Stepper` communicates a finite flow,
and `SideNav` organizes larger local sections.

**States.** Current, completed, available, disabled, expanded, and collapsed
states are exposed where relevant. A current destination is not styled as a
second unrelated action.

**Keyboard.** Tabs use roving focus and arrow/Home/End behavior. Native links or
buttons remain activatable with Enter/Space. Navigation order follows visual and
document order.

**Gamepad.** Directional intent moves within a navigation composite; previous/
next tab intents switch tab groups. Confirm activates the focused destination.

**Accessibility.** Provide labels for navigation regions and connect tabs to
their panels. Use current/selected semantics rather than color alone. A stepper
must not imply completed server work before authoritative confirmation.

**Example.**

```tsx
<Tabs
  label="Settings sections"
  items={[
    { value: "interface", label: "Interface", content: <InterfaceSettings /> },
    { value: "input", label: "Input", content: <InputSettings /> },
  ]}
/>
```

**Anti-patterns.** Do not use tabs as a substitute for sequential validation;
do not create a breadcrumb from arbitrary URLs; do not hide the active state;
do not place hundreds of destinations in `SideNav` without hierarchy/search.

## Overlay family

**Purpose.** Temporarily elevate focused content while preserving a predictable
close and focus-restoration path.

**Variants.** `Dialog` is the general modal/non-modal surface; `AlertDialog`
requires a decision; `Popover` anchors compact contextual content; `Drawer` and
`Sheet` enter from an edge; `Modal` aliases the dialog contract. Dialog sizes
range from `sm` to `fullscreen`.

**States.** Closed/open, entering/exiting, modal/non-modal, backdrop, pending,
error, and dismissible/non-dismissible states are explicit. Closed content is
unmounted.

**Keyboard.** Modal focus is trapped. Escape requests close when permitted.
Focus returns to the prior valid element. Tab never escapes to hidden gameplay
UI behind a modal.

**Gamepad.** Back follows the same close hierarchy as Escape; directional focus
stays inside the active modal; confirm activates the focused action.

**Accessibility.** Dialog title is required; description should explain impact.
Modal semantics and label/description relationships are provided. Alert dialogs
need clear, non-ambiguous actions and safe initial focus.

**Example.**

```tsx
<Dialog
  open={open}
  onOpenChange={setOpen}
  title="Discard changes?"
  description="Your local edits will be lost."
  footer={<ActionRow><Button variant="danger" onClick={discard}>Discard</Button></ActionRow>}
>
  Review the changed values before continuing.
</Dialog>
```

**Anti-patterns.** Do not hide React without releasing the runtime lease; do not
stack unrelated modals; do not use fullscreen presentation for a short prompt;
do not make a destructive action the only escape from a failure.

## Menu family

**Purpose.** Present a compact bounded set of contextual actions or selection
items.

**Variants.** `Menu` supports action, checkbox, radio, separator, and submenu
items. `Dropdown` anchors a menu to a trigger; `ContextMenu` opens at a pointer
position; `ActionMenu` supplies a standard trigger; `Submenu` handles nested
items.

**States.** Closed/open, active, checked/selected, disabled, danger, and submenu-
open states are represented. Menu nesting is bounded by the runtime protocol.

**Keyboard.** Up/Down moves through enabled items, Enter/Space selects, Right
opens a submenu, and Left/Escape closes the current level. Roving focus keeps one
menu item in the tab sequence.

**Gamepad.** Directional and confirm/back intents mirror the keyboard hierarchy.
Context-only operations need a non-pointer entry path.

**Accessibility.** Correct menu roles, checked state, expanded state, and labels
are emitted. Hints are supplementary. Action labels must remain understandable
without icons.

**Example.**

```tsx
<ActionMenu
  label="Record actions"
  items={[
    { id: "copy", label: "Copy identifier", onSelect: copyIdentifier },
    { id: "remove", label: "Remove", danger: true, onSelect: requestRemoval },
  ]}
/>
```

**Anti-patterns.** Do not use a payload-provided callback/event name; do not put
forms or long prose in a menu; do not rely on right click alone; do not create
deep or unbounded submenu trees.

## Feedback family

**Purpose.** Communicate progress, loading, empty, success, warning, and failure
without blocking unrelated interaction.

**Variants.** Spinner/skeleton cover indeterminate loading; progress bar/ring
cover determinate or indeterminate work; `LoadingOverlay` applies local busy
state; `EmptyState` supplies explanation and recovery action; `Toast` supplies
visual presentation only.

**States.** Indeterminate, finite progress, delayed, empty, recoverable error,
disabled/pending action, and completion states are distinct.

**Keyboard.** Feedback itself does not steal focus. Recovery actions are native
buttons and join normal focus order. A loading overlay must not strand focus.

**Gamepad.** Status does not change the input route. Controller users can reach
the same retry/cancel actions.

**Accessibility.** Provide labels for progress and loading. Announce important
changes without repeatedly spamming a live region. Skeletons are decorative;
meaning remains in accessible status text.

**Example.**

```tsx
<ProgressBar value={completed} maximum={total} label="Import progress" />
```

**Anti-patterns.** Do not use `Toast` as a global event bus; do not show an
endless spinner without status or recovery; do not replace form validation with
a transient toast; do not announce every animation frame.

## Data-display family

**Purpose.** Present structured records, key/value facts, status, identity, and
metrics with consistent density and alignment.

**Variants.** `Table` handles semantic tabular content; `DataList` and
`KeyValueList` handle compact records; `Badge`/`StatusBadge` label state;
`Stat`/`Metric` show a focused value; `Avatar` has an initials fallback;
`ListItem` composes leading, main, metadata, and trailing content.

**States.** Loading belongs to feedback primitives; data components cover empty,
selected, sortable, active, status-tone, and missing-image/fallback states.

**Keyboard.** Sort buttons and actionable rows are keyboard operable. Static
cells, badges, and metrics do not enter the tab order.

**Gamepad.** Actionable row focus uses directional navigation at the application
or `DataGrid` layer. Confirm activates a focused row only when an activation
callback exists.

**Accessibility.** Tables use captions and header semantics. Status includes
readable text. Avatar images require meaningful alt text; decorative avatars use
an empty alt. Numbers retain units and context.

**Example.**

```tsx
<KeyValueList
  items={[
    { key: "owner", label: "Owner", value: ownerResource },
    { key: "epoch", label: "Epoch", value: ownerEpoch },
  ]}
/>
```

**Anti-patterns.** Do not use a table for two unrelated values; do not encode
status only with a dot color; do not put protected live data in a visual mock;
do not stretch metrics across ultrawide space without a reading constraint.

## Utility family

**Purpose.** Supply supplementary descriptions, input hints, local icons, and
screen-reader-only text.

**Variants.** Tooltip supports four placements and a delay. `Shortcut` composes
multiple `KeyHint` values. `Icon`/`SynexIcon` render a finite built-in icon-name
union with size, tone, and optional label. `VisuallyHidden` preserves semantic
copy without visual display.

**States.** Tooltips support delayed open, focus/hover visibility, disabled, and
closed-unmounted states. Icons are either labeled images or hidden decoration.

**Keyboard.** Tooltip content appears for focus as well as pointer hover. Key
hints are not active controls.

**Gamepad.** Adaptive hints can display controller notation, but they do not
define the operation or focus behavior.

**Accessibility.** Tooltips supplement visible labels; they never carry the
only required instruction. Icon-only buttons label the button, while decorative
icons remain `aria-hidden`.

**Example.**

```tsx
<Tooltip content="Refresh the current snapshot">
  <IconButton label="Refresh" icon={<Icon name="signal" />} onClick={refresh} />
</Tooltip>
```

**Anti-patterns.** Do not accept arbitrary SVG markup or URLs; do not put
interactive content inside a tooltip; do not use `VisuallyHidden` to conceal
required sighted-user instructions; do not use an icon without a text label when
its meaning is not already expressed.

## Advanced and large-data family

**Purpose.** Provide bounded foundations for search-heavy commands, trees,
large lists/grids, keyboard data grids, drag/reorder, and chart styling without
embedding a domain engine.

**Variants.** `CommandPalette` and `SearchList` filter bounded items;
`VirtualList`/`VirtualGrid` render fixed-size windows with overscan; `Tree`
supports selection/expansion; `DataGrid` provides composable and higher-level
grid primitives; drag hooks and `ReorderList` cover local drag/reorder;
`chartTokens` and `chartSeriesStyle` style a consumer-owned chart implementation.

**States.** Query, active result, empty, selected, expanded/collapsed, virtual
range, sort, drag, valid drop, and disabled states are explicit. Virtualization
does not remove a required accessible summary or empty state.

**Keyboard.** Command/search lists use Up/Down and Enter. Trees use Up/Down,
Left/Right, Home/End. Data grids use directional cell navigation and Enter/Space
for row activation. Reorder handles support `Alt+ArrowUp`/`Alt+ArrowDown`.

**Gamepad.** Directional/confirm/back/page intents map to the same logical
operations. Drag-only interactions require a reorder alternative; controller
users must not depend on pointer drag.

**Accessibility.** Supply labels, stable IDs/keys, correct row/column counts,
selected/expanded state, and live reorder announcements. Keep a finite DOM and
test assistive navigation before using virtualization for critical content.

**Example.**

```tsx
<VirtualList
  items={records}
  itemKey={(record) => record.id}
  itemSize={52}
  height={420}
  ariaLabel="Runtime records"
  renderItem={(record, context) => (
    <div style={context.style}>{record.label}</div>
  )}
/>
```

**Anti-patterns.** Do not virtualize small collections; do not assume fixed row
height with wrapping content; do not make drag the only reorder path; do not
mount a command palette globally without an owner/focus lifecycle; do not imply
that chart tokens provide a charting library.

## Runtime versus package components

Package components are local React building blocks. Opening a package `Dialog`
inside a domain NUI does not automatically acquire FiveM focus. The domain
resource must hold a valid `synex_ui` focus lease for that NUI.

Conversely, runtime `alert`, `confirm`, `input`, `form`, `select`, `menu`, and
`contextMenu` operations render generic descriptors inside the shared runtime.
They are convenience surfaces, not replacements for domain applications.

The runtime `select` descriptor uses flat options and can opt into multiple
selection, client-side search, and placeholder copy. Runtime menus are sectioned
and may nest options to three total levels. A context menu additionally requires
an `anchor` with normalized `x` and `y` values from `0` through `1`; the browser
clamps its rendered panel to the available viewport. These runtime descriptor
rules do not change the more general composition API of the build-time package.
