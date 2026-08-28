import { useMemo, useState, type ReactNode } from "react";
import {
  ActionMenu,
  ActionRow,
  AlertDialog,
  AspectBox,
  Avatar,
  Badge,
  Breadcrumb,
  Button,
  Checkbox,
  Combobox,
  CommandPalette,
  Container,
  ContextMenu,
  DataGrid,
  DataList,
  Dialog,
  Divider,
  Drawer,
  Dropdown,
  EmptyState,
  Field,
  FieldGroup,
  Grid,
  Icon,
  IconButton,
  Inline,
  Input,
  KeyHint,
  KeyValueList,
  ListItem,
  LoadingOverlay,
  Menu,
  Metric,
  Modal,
  MultiSelect,
  NumberInput,
  Pagination,
  PasswordInput,
  Popover,
  ProgressBar,
  ProgressRing,
  Radio,
  ReorderList,
  ScrollArea,
  SearchInput,
  SearchList,
  SearchSelect,
  SegmentedControl,
  Select,
  Sheet,
  Shortcut,
  SideNav,
  Skeleton,
  Slider,
  Spacer,
  Spinner,
  SplitButton,
  Stack,
  Stat,
  StatusBadge,
  Stepper,
  Surface,
  Switch,
  SynexIcon,
  Table,
  Tabs,
  TextArea,
  Toast,
  Tooltip,
  Tree,
  Typography,
  ValidationMessage,
  VirtualGrid,
  VirtualList,
  VisuallyHidden,
  chartSeriesStyle,
  chartTokens,
  formatCurrency,
  formatDate,
  formatNumber,
  formatPercent,
  formatTime,
  motionDurationMilliseconds,
  motionIntentSpeeds,
  motionTokens,
  type MenuItem,
  type ReorderItem,
  type SurfaceIntensity,
  type SurfaceMaterial,
  type SurfaceTone,
} from "@synex/ui";
import { designLabTransport, type MockScenario } from "./mockTransport";
import type { LabPreferences, LabSection } from "./DesignLab";

interface SpecimenSectionProps {
  section: LabSection;
  preferences: LabPreferences;
}

function FamilyHeader({ title, description }: { code: string; eyebrow: string; title: string; description: string }) {
  return (
    <header className="lab-family-header">
      <div>
        <h1>{title}</h1>
        <p>{description}</p>
      </div>
    </header>
  );
}

function Specimen({ title, note, children, wide = false, id }: { title: string; note?: string; children: ReactNode; wide?: boolean; id?: string }) {
  return (
    <section className="lab-specimen" data-wide={wide || undefined} data-testid={id}>
      <header className="lab-specimen__header">
        <h2>{title}</h2>
        {note ? <span>{note}</span> : null}
      </header>
      <div className="lab-specimen__body">{children}</div>
    </section>
  );
}

function Overview({ preferences }: { preferences: LabPreferences }) {
  const boundaries = [
    ["@synex/ui", "Compiled into each domain NUI", "Build time"],
    ["synex_ui", "Coordinates generic surfaces and focus", "Client runtime"],
    ["Domain server", "Owns authorization and persistent state", "Server authority"],
    ["Closed state", "Unmounted, transparent and pointer-free", "Required"],
  ] as const;

  return (
    <>
      <FamilyHeader
        code="00"
        eyebrow="REFERENCE SURFACE"
        title="Synex UI component proof"
        description="Inspect the shipped controls, rendering profiles and runtime boundaries before testing the same build inside FiveM CEF."
      />
      <section className="lab-overview" aria-label="Synex UI system overview">
        <header className="lab-overview__heading">
          <div>
            <h2>Current proof conditions</h2>
            <p>{preferences.quality.toLowerCase()} material quality, {preferences.density} density, {preferences.scale}% interface scale.</p>
          </div>
          <dl className="lab-overview__result">
            <div><dt>Browser</dt><dd>Ready</dd></div>
            <div><dt>FiveM CEF</dt><dd>Pending</dd></div>
          </dl>
        </header>

        <section className="lab-overview__scenario" aria-labelledby="overview-scenario-title">
          <header>
            <h2 id="overview-scenario-title">Owner-bound focus request</h2>
            <p>A representative interaction combining owner identity, input mode and an explicit action hierarchy.</p>
          </header>
          <div className="lab-overview__scenario-body">
            <div className="lab-overview__interaction">
              <Field label="Resource owner" description="Captured at the Cfx export boundary">
                <Input defaultValue="synex_inventory" />
              </Field>
              <SegmentedControl
                label="Input mode"
                defaultValue="keyboard"
                options={[
                  { value: "pointer", label: "Pointer" },
                  { value: "keyboard", label: "Keyboard" },
                  { value: "gamepad", label: "Gamepad" },
                ]}
              />
              <ActionRow>
                <Button>Acquire focus</Button>
                <Button variant="secondary">Inspect request</Button>
                <Button variant="quiet">Cancel</Button>
              </ActionRow>
            </div>
            <dl className="lab-overview__checks">
              <div><dt>Owner</dt><dd>Resource that requested the surface</dd></div>
              <div><dt>Close path</dt><dd>Returned to the client focus authority</dd></div>
              <div><dt>Server trust</dt><dd>No domain mutation is performed here</dd></div>
              <div><dt>Closed UI</dt><dd>No pixels, focus, pointer capture or polling</dd></div>
            </dl>
          </div>
        </section>

        <section className="lab-overview__boundaries" aria-labelledby="overview-boundaries-title">
          <header>
            <h2 id="overview-boundaries-title">Delivery boundaries</h2>
            <p>Each layer keeps one explicit responsibility.</p>
          </header>
          <div className="lab-overview__boundary-table">
            {boundaries.map(([label, detail, state]) => (
              <div className="lab-overview__boundary" key={label}>
                <strong>{label}</strong>
                <small>{detail}</small>
                <span>{state}</span>
              </div>
            ))}
          </div>
        </section>
      </section>
    </>
  );
}

const materials: ReadonlyArray<{ material: SurfaceMaterial; role: string; detail: string }> = [
  { material: "solid", role: "Form surface", detail: "Default opaque working plane" },
  { material: "translucent", role: "Context overlay", detail: "Preserves scene context with a solid fallback" },
  { material: "floating", role: "Menu or popover", detail: "Short-lived surface above application content" },
  { material: "immersive", role: "System attention", detail: "Reserved for explicit full-attention flows" },
];
const materialIntensities: readonly SurfaceIntensity[] = ["subtle", "soft", "medium", "strong"];
const materialTones: readonly SurfaceTone[] = ["neutral", "accent", "success", "warning", "danger"];
const semanticColorTokens = [
  ["Canvas", "--sx-color-canvas"],
  ["Surface", "--sx-color-surface"],
  ["Raised", "--sx-color-surface-raised"],
  ["Text", "--sx-color-text"],
  ["Muted text", "--sx-color-text-muted"],
  ["Border", "--sx-color-border-strong"],
  ["Focus / selection", "--sx-color-accent"],
  ["Positive", "--sx-color-positive"],
  ["Warning", "--sx-color-warning"],
  ["Danger", "--sx-color-danger"],
  ["Information", "--sx-color-info"],
] as const;
const foundationTokenGroups = [
  { key: "color", label: "Color", value: "--sx-color-*" },
  { key: "space", label: "Spacing", value: "--sx-space-1 … --sx-space-12" },
  { key: "radius", label: "Geometry", value: "--sx-p-radius-1 … --sx-p-radius-round" },
  { key: "type", label: "Typography", value: "--sx-p-type-* / --sx-font-*" },
  { key: "depth", label: "Depth", value: "--sx-shadow-1 … --sx-shadow-3" },
  { key: "motion", label: "Motion", value: "--sx-motion-*" },
  { key: "layer", label: "Layers", value: "--sx-layer-base … --sx-layer-system" },
  { key: "density", label: "Density", value: "data-sx-density" },
] as const;
const viewportTargets = [
  { key: "720p", label: "720p / 16:9", value: "1280 × 720" },
  { key: "1080p", label: "1080p / 16:9", value: "1920 × 1080" },
  { key: "1440p", label: "1440p / 16:9", value: "2560 × 1440" },
  { key: "4k", label: "4K / 16:9", value: "3840 × 2160" },
  { key: "21x9-2560", label: "Ultrawide / 21:9", value: "2560 × 1080" },
  { key: "21x9", label: "Ultrawide / 21:9", value: "3440 × 1440" },
  { key: "32x9", label: "Super ultrawide / 32:9", value: "5120 × 1440" },
] as const;

function FoundationSpecimens() {
  const sampleTimestamp = Date.UTC(2026, 7, 28, 14, 35, 20);
  const typographyRoles = [
    "display", "heading-1", "heading-2", "heading-3", "body", "body-small",
    "caption", "label", "numeric", "code", "monospace",
  ] as const;
  const motionIntents = Object.keys(motionTokens) as readonly (keyof typeof motionTokens)[];
  return (
    <>
      <FamilyHeader code="01" eyebrow="FOUNDATION" title="Foundations" description="Tokens, type, formatting, material fallbacks and viewport targets used by every Synex interface." />
      <div className="lab-specimen-grid">
        <Specimen title="Token map" note="semantic contracts, no component hardcodes" wide id="tokens">
          <KeyValueList items={foundationTokenGroups} />
        </Specimen>
        <Specimen title="Semantic color roles" note="accent is reserved for focus, selection and status" wide id="colors">
          <div className="lab-color-tokens">
            {semanticColorTokens.map(([label, variable]) => (
              <div className="lab-color-token" key={variable}>
                <span aria-hidden="true" style={{ background: `var(${variable})` }} />
                <strong>{label}</strong>
                <code>{variable}</code>
              </div>
            ))}
          </div>
        </Specimen>
        <Specimen title="Material roles" note="four representative uses; all transparent variants retain solid fallbacks" wide id="materials">
          <Grid minColumnWidth={240} gap={12}>
            {materials.map(({ material, role, detail }, index) => {
              const intensity = materialIntensities[index % materialIntensities.length]!;
              const tone = materialTones[index % materialTones.length]!;
              return <Surface key={material} variant={material} intensity={intensity} tone={tone} elevation={(index % 5) as 0 | 1 | 2 | 3 | 4} className="lab-material"><span>{material}</span><strong>{role}</strong><small>{detail}</small></Surface>;
            })}
          </Grid>
        </Specimen>
        <Specimen title="Transparency proof" note="the contrast field makes blur and opacity differences measurable" wide id="glass-intensity">
          <div className="lab-transparency-proof">
            <div className="lab-transparency-proof__field" aria-hidden="true"><span /><span /><span /><span /></div>
            <div className="lab-transparency-proof__samples">
              {materialIntensities.map((intensity) => (
                <Surface key={intensity} variant="glass" intensity={intensity} tone="neutral" className="lab-material">
                  <strong>{intensity}</strong>
                  <small>Glass enhancement; solid fallback remains required</small>
                </Surface>
              ))}
            </div>
          </div>
        </Specimen>
        <Specimen title="Typography roles" note="11 semantic roles" wide>
          <div className="lab-typography-specimen">
            {typographyRoles.map((variant) => (
              <div key={variant}>
                <code>{variant}</code>
                <Typography variant={variant}>Synex interface foundation</Typography>
              </div>
            ))}
          </div>
        </Specimen>
        <Specimen title="Deterministic formatting" note="explicit locale + time zone">
          <KeyValueList items={[
            { key: "number", label: "Number", value: formatNumber(12_345.67, { locale: "en-US", minimumFractionDigits: 2, maximumFractionDigits: 2 }) },
            { key: "currency", label: "Currency", value: formatCurrency(1_284.5, { locale: "de-DE", currency: "EUR", currencyDisplay: "code" }) },
            { key: "percent", label: "Percent", value: formatPercent(0.927, { locale: "en-US", maximumFractionDigits: 1 }) },
            { key: "date", label: "Date", value: formatDate(sampleTimestamp, { locale: "en-GB", timeZone: "UTC" }) },
            { key: "time", label: "Time", value: formatTime(sampleTimestamp, { locale: "en-GB", timeZone: "UTC", hour12: false }) },
          ]} />
        </Specimen>
        <Specimen title="Motion language" note="state-driven, not decorative">
          <div className="lab-motion-specimen">
            {motionIntents.map((intent) => (
              <div key={intent}>
                <span aria-hidden="true" />
                <strong>{intent}</strong>
                <code>{motionIntentSpeeds[intent]} / {motionDurationMilliseconds[motionIntentSpeeds[intent]]} ms</code>
              </div>
            ))}
          </div>
        </Specimen>
        <Specimen title="Stack · Inline · Spacer">
          <Stack gap={12}><Badge>STACK / 12</Badge><Divider /><Inline gap={8} wrap><Badge tone="accent">INLINE</Badge><Badge tone="info">WRAP</Badge><Spacer axis="horizontal" size={8} /><StatusBadge status="online" /></Inline></Stack>
        </Specimen>
        <Specimen title="Grid · Container">
          <Container size="sm" className="lab-container-demo"><Grid columns={3} gap={6}>{[1, 2, 3, 4, 5, 6].map((entry) => <span key={entry}>{entry}</span>)}</Grid></Container>
        </Specimen>
        <Specimen title="Scroll area">
          <ScrollArea className="lab-scroll-demo" aria-label="Scrollable protocol entries">{Array.from({ length: 12 }, (_, index) => <div key={index}><code>route.{String(index + 1).padStart(2, "0")}</code><span>owner-bound</span></div>)}</ScrollArea>
        </Specimen>
        <Specimen title="Aspect box · Divider">
          <AspectBox ratio={16 / 7} className="lab-aspect-demo"><span>16 / 7</span><Divider /><small>SAFE FRAME</small></AspectBox>
        </Specimen>
        <Specimen title="Screen-size matrix" note="browser regression targets; live CEF acceptance remains pending" wide id="screen-sizes">
          <KeyValueList items={viewportTargets} />
        </Specimen>
      </div>
    </>
  );
}

function ActionSpecimens() {
  const menu = <Menu items={[{ id: "inspect", label: "Inspect lease", onSelect: () => undefined }, { id: "release", label: "Release", danger: true, onSelect: () => undefined }]} />;
  return (
    <>
      <FamilyHeader code="02" eyebrow="ACTIONS" title="Actions" description="Button hierarchy, sizes, loading behavior and grouped decisions at gameplay viewing distance." />
      <div className="lab-specimen-grid">
        <Specimen title="Button hierarchy" wide>
          <Inline gap={10} wrap>{(["primary", "secondary", "quiet", "outline", "danger"] as const).map((variant) => <Button key={variant} variant={variant}>{variant}</Button>)}<Button loading>Committing</Button><Button disabled>Unavailable</Button></Inline>
        </Specimen>
        <Specimen title="Scale and icon actions">
          <Inline gap={8} align="center"><Button size="sm">Small</Button><Button size="md">Medium</Button><Button size="lg">Large</Button><IconButton label="Create" icon={<Icon name="plus" />} /><IconButton label="Signal" variant="outline" icon={<Icon name="signal" />} /></Inline>
        </Specimen>
        <Specimen title="Split action">
          <SplitButton menu={menu} menuLabel="Open lease actions" variant="secondary">Acquire lease</SplitButton>
        </Specimen>
        <Specimen title="Action row">
          <ActionRow align="between" reverseOnNarrow><Button variant="quiet">Cancel</Button><Inline gap={8}><Button variant="secondary">Save draft</Button><Button>Publish contract</Button></Inline></ActionRow>
        </Specimen>
      </div>
    </>
  );
}

function FormSpecimens() {
  const [search, setSearch] = useState("focus lease");
  return (
    <>
      <FamilyHeader code="03" eyebrow="FORMS" title="Form controls" description="Labels, descriptions, validation and input states shown with representative resource data." />
      <div className="lab-specimen-grid">
        <Specimen title="Text inputs" wide>
          <Grid minColumnWidth={320} gap={16}>
            <Field label="Resource owner" description="Captured at the Cfx export boundary." required><Input defaultValue="synex_inventory" /></Field>
            <Field label="Search leases"><SearchInput value={search} onChange={(event) => setSearch(event.currentTarget.value)} onClear={() => setSearch("")} /></Field>
            <Field label="Owner secret"><PasswordInput defaultValue="owner-epoch-token" /></Field>
            <Field label="Priority"><NumberInput defaultValue={40} minimum={0} maximum={100} /></Field>
          </Grid>
        </Specimen>
          <Specimen title="Long form and validation">
            <Field label="Reason" controlId="lab-reason" invalid>
              <TextArea defaultValue="UI request" aria-describedby="lab-reason-validation" />
            </Field>
            <ValidationMessage id="lab-reason-validation">Enter at least 12 characters so the request can be reviewed.</ValidationMessage>
          </Specimen>
        <Specimen title="Choice controls">
          <FieldGroup legend="Input policy" description="Choose how gameplay input behaves."><Checkbox label="Capture keyboard" defaultChecked /><Checkbox label="Capture pointer" /><Checkbox label="Keep adaptive hints" defaultChecked /><Radio name="priority" label="Normal priority" defaultChecked /><Radio name="priority" label="Critical priority" /></FieldGroup>
        </Specimen>
        <Specimen title="Switch and range">
          <Stack gap={18}><Switch label="Reduced motion" description="Removes non-essential transitions." /><Switch label="High contrast" defaultChecked /><Field label="UI scale"><Slider defaultValue={100} minimum={85} maximum={125} step={5} showValue formatValue={(value) => `${value}%`} /></Field></Stack>
        </Specimen>
      </div>
    </>
  );
}

const resourceOptions = [
  { value: "inventory", label: "Inventory", description: "Pointer-exclusive workspace", keywords: ["items"] },
  { value: "phone", label: "Phone", description: "Keyboard and pointer", keywords: ["communication"] },
  { value: "control", label: "Control", description: "Operational diagnostics", keywords: ["ops"] },
] as const;

function SelectionSpecimens() {
  return (
    <>
      <FamilyHeader code="04" eyebrow="SELECTION" title="Selection controls" description="Native, searchable, multi-value and segmented choices using one predictable value model." />
      <div className="lab-specimen-grid">
        <Specimen title="Select · Segmented control">
          <Stack gap={16}><Select aria-label="Select quality" options={resourceOptions} defaultValue="inventory" /><SegmentedControl label="Focus mode" options={[{ value: "passive", label: "Passive" }, { value: "keyboard", label: "Keyboard" }, { value: "exclusive", label: "Exclusive" }]} defaultValue="keyboard" /></Stack>
        </Specimen>
        <Specimen title="Combobox">
          <Combobox options={resourceOptions} defaultValue="phone" placeholder="Search resources" />
        </Specimen>
        <Specimen title="Search select">
          <SearchSelect options={resourceOptions} minimumQueryLength={1} placeholder="Type to filter" />
        </Specimen>
        <Specimen title="Multi-select">
          <MultiSelect options={resourceOptions} defaultValue={["inventory", "control"]} />
        </Specimen>
      </div>
    </>
  );
}

function NavigationSpecimens() {
  const [page, setPage] = useState(3);
  const [step, setStep] = useState("verify");
  return (
    <>
      <FamilyHeader code="05" eyebrow="NAVIGATION" title="Navigation" description="Tabs, breadcrumbs, pagination, steps and side navigation with keyboard-visible current state." />
      <div className="lab-specimen-grid">
        <Specimen title="Tabs" wide><Tabs label="Runtime view" items={[{ value: "leases", label: "Leases", badge: "03", content: <p>Three owner-bound focus leases are represented.</p> }, { value: "surfaces", label: "Surfaces", badge: "01", content: <p>One generic surface is awaiting a response.</p> }, { value: "input", label: "Input", content: <p>Keyboard is the current adaptive input mode.</p> }]} /></Specimen>
        <Specimen title="Breadcrumb"><Breadcrumb items={[{ label: "Synex" }, { label: "Libraries" }, { label: "UI" }]} /></Specimen>
        <Specimen title="Pagination"><Pagination page={page} pageCount={8} onPageChange={setPage} /></Specimen>
        <Specimen title="Stepper" wide><Stepper value={step} completed={["prepare"]} onValueChange={setStep} steps={[{ value: "prepare", label: "Prepare", description: "Compile bundle" }, { value: "verify", label: "Verify", description: "Run gates" }, { value: "ship", label: "Ship", description: "Live gate", optional: true }]} /></Specimen>
        <Specimen title="Side navigation"><SideNav activeId="focus" items={[{ id: "runtime", label: "Runtime", icon: <Icon name="signal" />, children: [{ id: "focus", label: "Focus leases", badge: "3" }, { id: "transport", label: "Transport" }] }, { id: "preferences", label: "Preferences", icon: <Icon name="command" /> }]} /></Specimen>
      </div>
    </>
  );
}

function OverlaySpecimens() {
  const [dialog, setDialog] = useState(false);
  const [alert, setAlert] = useState(false);
  const [drawer, setDrawer] = useState(false);
  const [sheet, setSheet] = useState(false);
  const [modal, setModal] = useState(false);
  return (
    <>
      <FamilyHeader code="06" eyebrow="OVERLAYS" title="Overlays" description="Dialogs, alerts, popovers, drawers and sheets with bounded focus and deterministic close behavior." />
      <div className="lab-specimen-grid">
        <Specimen title="Dialog · Alert dialog" wide><Inline gap={10} wrap><Button onClick={() => setDialog(true)}>Open dialog</Button><Button variant="danger" onClick={() => setAlert(true)}>Open destructive alert</Button><Button variant="secondary" onClick={() => setModal(true)}>Open modal alias</Button></Inline></Specimen>
        <Specimen title="Popover"><Popover trigger={<Button variant="outline">Inspect owner</Button>} content={<KeyValueList items={[{ key: "resource", label: "Resource", value: "synex_phone" }, { key: "epoch", label: "Epoch", value: "42" }]} />} /></Specimen>
        <Specimen title="Drawer · Sheet"><Inline gap={10} wrap><Button variant="secondary" onClick={() => setDrawer(true)}>Open drawer</Button><Button variant="secondary" onClick={() => setSheet(true)}>Open sheet</Button></Inline></Specimen>
      </div>
      <Dialog open={dialog} onOpenChange={setDialog} title="Acquire focus lease" description="The owner and priority are immutable after acquisition." footer={<ActionRow><Button variant="secondary" onClick={() => setDialog(false)}>Cancel</Button><Button onClick={() => setDialog(false)}>Acquire</Button></ActionRow>}><Field label="Lease reason"><Input defaultValue="Open shared selector" /></Field></Dialog>
      <AlertDialog open={alert} onOpenChange={setAlert} title="Release all owner surfaces?" description="Pending requests for this owner will be cancelled." confirmLabel="Release surfaces" destructive onConfirm={() => setAlert(false)}>This action is scoped to the captured resource owner.</AlertDialog>
      <Drawer open={drawer} onOpenChange={setDrawer} title="Focus stack" side="right"><DataList items={[{ id: "1", primary: "synex_inventory", secondary: "EXCLUSIVE / priority 80" }, { id: "2", primary: "synex_phone", secondary: "SUSPENDED / priority 40" }]} /></Drawer>
      <Sheet open={sheet} onOpenChange={setSheet} title="Adaptive input hints" edge="bottom"><Inline gap={12}><Shortcut keys={["D-Pad", "Navigate"]} /><Shortcut keys={["A", "Confirm"]} /><Shortcut keys={["B", "Back"]} /></Inline></Sheet>
      <Modal open={modal} onOpenChange={setModal} title="Modal compatibility"><p><code>Modal</code> is the modal form of the shared dialog primitive.</p></Modal>
    </>
  );
}

function MenuSpecimens() {
  const [checked, setChecked] = useState(true);
  const [mode, setMode] = useState("keyboard");
  const items: readonly MenuItem[] = [
    { id: "inspect", label: "Inspect owner", icon: <Icon name="search" />, hint: "I", onSelect: () => undefined },
    { id: "follow", type: "checkbox", label: "Follow active owner", checked, onCheckedChange: setChecked },
    { id: "pointer", type: "radio", label: "Pointer mode", value: "pointer", selectedValue: mode, onValueChange: setMode },
    { id: "keyboard", type: "radio", label: "Keyboard mode", value: "keyboard", selectedValue: mode, onValueChange: setMode },
    { id: "divider", type: "separator" },
    { id: "priority", type: "submenu", label: "Priority", items: [{ id: "normal", label: "Normal", onSelect: () => undefined }, { id: "critical", label: "Critical", danger: true, onSelect: () => undefined }] },
  ];
  return (
    <>
      <FamilyHeader code="07" eyebrow="MENUS" title="Menus" description="Command menus, dropdowns and context actions with checked state and bounded submenu depth." />
      <div className="lab-specimen-grid">
        <Specimen title="Menu" wide><div className="lab-menu-stage"><Menu items={items} label="Owner actions" /></div></Specimen>
        <Specimen title="Dropdown · Action menu"><Inline gap={10}><Dropdown trigger={<Button variant="secondary">Input mode</Button>} items={items} /><ActionMenu items={items} /></Inline></Specimen>
        <Specimen title="Context menu"><ContextMenu items={items}><div className="lab-context-target"><Icon name="command" /><strong>Right-click target</strong><small>Opens a bounded local menu</small></div></ContextMenu></Specimen>
      </div>
    </>
  );
}

function FeedbackSpecimens() {
  return (
    <>
      <FamilyHeader code="08" eyebrow="FEEDBACK" title="Feedback and progress" description="Loading, progress, empty and transient states with readable recovery information." />
      <div className="lab-specimen-grid">
        <Specimen title="Progress" wide><Grid minColumnWidth={240} gap={20}><Stack gap={14}><ProgressBar label="Bundle compilation" value={76} showValue /><ProgressBar label="Waiting for response" indeterminate tone="info" /></Stack><Inline gap={18} align="center"><ProgressRing label="Runtime health" value={92} size={76}>92</ProgressRing><Spinner size="lg" /><Spinner size="sm" /></Inline></Grid></Specimen>
        <Specimen title="Skeleton"><Stack gap={12}><Skeleton shape="text" lines={3} /><Inline gap={12}><Skeleton shape="circle" className="lab-skeleton-circle" /><Skeleton shape="rect" className="lab-skeleton-rect" /></Inline></Stack></Specimen>
        <Specimen title="Toast — visual primitive"><Stack gap={8}><Toast title="Lease acquired" description="Owner epoch 42 is active." tone="positive" onDismiss={() => undefined} /><Toast title="Focus busy" description="A higher-priority owner is active." tone="warning" /></Stack></Specimen>
        <Specimen title="Empty state"><EmptyState icon={<Icon name="signal" />} title="No pending surfaces" description="New generic requests will appear in this queue." primaryAction={{ label: "Refresh", onClick: () => undefined }} /></Specimen>
        <Specimen title="Loading overlay"><div className="lab-loading-stage"><span>Content remains structurally present.</span><LoadingOverlay visible label="Applying preferences" description="Local KVP write" /></div></Specimen>
      </div>
    </>
  );
}

interface LeaseRow { id: string; owner: string; mode: string; priority: number; state: string }
const leaseRows: readonly LeaseRow[] = [
  { id: "l-01", owner: "synex_inventory", mode: "EXCLUSIVE", priority: 80, state: "active" },
  { id: "l-02", owner: "synex_phone", mode: "POINTER", priority: 40, state: "suspended" },
  { id: "l-03", owner: "synex_control", mode: "KEYBOARD", priority: 20, state: "queued" },
];
const leaseColumns = [
  { id: "owner", header: "Owner", cell: (row: LeaseRow) => row.owner, sortable: true, width: "34%" },
  { id: "mode", header: "Mode", cell: (row: LeaseRow) => <Badge variant="outline">{row.mode}</Badge> },
  { id: "priority", header: "Priority", cell: (row: LeaseRow) => row.priority, align: "end" as const, sortable: true },
  { id: "state", header: "State", cell: (row: LeaseRow) => <StatusBadge status={row.state === "active" ? "online" : row.state === "queued" ? "idle" : "unknown"}>{row.state}</StatusBadge> },
];

function DataSpecimens() {
  const [sort, setSort] = useState<{ columnId: string; direction: "ascending" | "descending" }>({ columnId: "priority", direction: "descending" });
  return (
    <>
      <FamilyHeader code="09" eyebrow="DATA" title="Data display" description="Lists, tables, metrics and grids using owner-lease data across narrow and ultrawide surfaces." />
      <div className="lab-specimen-grid">
        <Specimen title="Metrics" wide><Grid minColumnWidth={180} gap={1} className="lab-metrics"><Stat label="Focus leases" value="03" detail="1 active" tone="accent" /><Metric label="Pending requests" value="12" progress={42} /><Stat label="Rejected payloads" value="07" detail="last 5 min" tone="warning" /><Metric label="Response budget" value="28" unit="ms" detail="p95" /></Grid></Specimen>
        <Specimen title="Table" wide><Table caption={<VisuallyHidden>Focus leases</VisuallyHidden>} columns={leaseColumns} rows={leaseRows} rowKey={(row) => row.id} sort={sort} onSortChange={setSort} selectedKeys={new Set(["l-01"])} /></Specimen>
        <Specimen title="Data list / List item"><DataList items={leaseRows.map((row) => ({ id: row.id, primary: row.owner, secondary: `${row.mode} / P${row.priority}`, leading: <Avatar name={row.owner} size="sm" status={row.state === "active" ? "online" : "idle"} />, trailing: <Badge>{row.state}</Badge> }))} /><ul className="lab-plain-list"><ListItem primary="Manual list item" secondary="Composable primitive" leading={<Icon name="signal" />} /></ul></Specimen>
        <Specimen title="Key-value / Badges"><Stack gap={14}><KeyValueList items={[{ key: "owner", label: "Owner", value: "synex_inventory", copyable: true }, { key: "epoch", label: "Epoch", value: "42" }, { key: "mode", label: "Mode", value: "EXCLUSIVE" }]} onCopyValue={() => undefined} /><Inline gap={8} wrap><Badge tone="accent">Accent</Badge><Badge tone="positive">Positive</Badge><Badge tone="warning">Warning</Badge><Badge tone="danger">Danger</Badge><StatusBadge status="online" pulse /></Inline></Stack></Specimen>
        <Specimen title="Data grid" wide><DataGrid label="Owner leases grid" columns={leaseColumns} rows={leaseRows} rowKey={(row) => row.id} sort={sort} onSortChange={setSort} /></Specimen>
      </div>
    </>
  );
}

function UtilitySpecimens() {
  const iconNames = ["check", "close", "chevron-down", "chevron-right", "arrow-left", "arrow-right", "search", "plus", "minus", "more", "copy", "eye", "eye-off", "info", "warning", "error", "success", "menu", "command", "signal"] as const;
  return (
    <>
      <FamilyHeader code="10" eyebrow="UTILITIES" title="Utilities" description="Icons, focus-only text, shortcuts and contextual help used across resource interfaces." />
      <div className="lab-specimen-grid">
        <Specimen title="Synex icon set" wide><Grid minColumnWidth={120} gap={8}>{iconNames.map((name) => <div className="lab-icon-cell" key={name}><SynexIcon name={name} /><code>{name}</code></div>)}</Grid></Specimen>
        <Specimen title="Tooltip"><Inline gap={18}><Tooltip content="Owner-bound request" placement="top"><Button variant="outline">Hover or focus</Button></Tooltip><Tooltip content="Critical signal" placement="right"><IconButton label="Runtime signal" icon={<Icon name="signal" />} /></Tooltip></Inline></Specimen>
        <Specimen title="Key hints · Shortcuts"><Stack gap={14}><Inline gap={8}><KeyHint>ESC</KeyHint><KeyHint>ENTER</KeyHint><KeyHint>D-PAD</KeyHint></Inline><Shortcut keys={["CTRL", "K"]} label="Control plus K" /></Stack></Specimen>
        <Specimen title="Visually hidden"><p>There is an additional screen-reader-only status after this sentence.<VisuallyHidden> Runtime transport is connected.</VisuallyHidden></p></Specimen>
      </div>
    </>
  );
}

function AdvancedSpecimens() {
  const [palette, setPalette] = useState(false);
  const [reorder, setReorder] = useState<readonly ReorderItem[]>([
    { id: "pointer", content: "Pointer intent" },
    { id: "keyboard", content: "Keyboard intent" },
    { id: "gamepad", content: "Gamepad intent" },
  ]);
  const virtualItems = useMemo(() => Array.from({ length: 500 }, (_, index) => ({ id: `route-${index}`, label: `Transport route ${String(index + 1).padStart(3, "0")}` })), []);
  const chartStyles = useMemo(() => chartTokens.categorical.map((_, index) => chartSeriesStyle(index)), []);
  return (
    <>
      <FamilyHeader code="11" eyebrow="ADVANCED" title="Advanced components" description="Search, tree, virtualization and reorder behavior without ownership of domain state." />
      <div className="lab-specimen-grid">
        <Specimen title="Command palette" wide><Button leading={<Icon name="command" />} onClick={() => setPalette(true)}>Open command palette</Button><CommandPalette open={palette} onOpenChange={setPalette} commands={[{ id: "acquire", label: "Acquire focus lease", description: "Open an EXCLUSIVE lease", group: "Runtime", shortcut: ["CTRL", "A"], onSelect: () => undefined }, { id: "release", label: "Release active lease", group: "Runtime", onSelect: () => undefined }, { id: "profile", label: "Switch quality profile", group: "Preferences", onSelect: () => undefined }]} /></Specimen>
        <Specimen title="Search list"><SearchList label="Search owners" items={leaseRows.map((row) => ({ id: row.id, label: row.owner, description: `${row.mode} / P${row.priority}` }))} onSelect={() => undefined} /></Specimen>
        <Specimen title="Tree"><Tree label="UI package tree" defaultExpandedIds={new Set(["root", "runtime"])} nodes={[{ id: "root", label: "synex_ui", children: [{ id: "components", label: "Build-time components" }, { id: "runtime", label: "Runtime", children: [{ id: "focus", label: "Focus manager" }, { id: "transport", label: "NUI transport" }] }] }]} /></Specimen>
        <Specimen title="Virtual list" wide><VirtualList items={virtualItems} itemKey={(item) => item.id} itemSize={42} height={252} ariaLabel="Five hundred virtual transport routes" renderItem={(item, context) => <div className="lab-virtual-row"><code>{String(context.index + 1).padStart(3, "0")}</code><span>{item.label}</span><Badge variant="outline">bounded</Badge></div>} /></Specimen>
        <Specimen title="Virtual grid" wide><VirtualGrid items={virtualItems.slice(0, 120)} itemKey={(item) => item.id} minimumColumnWidth={190} rowHeight={72} height={252} ariaLabel="Virtual owner grid" renderItem={(item, context) => <Surface material="elevated" className="lab-virtual-cell"><span>{context.row + 1}.{context.column + 1}</span><strong>{item.label}</strong></Surface>} /></Specimen>
        <Specimen title="Reorder · drag foundation"><ReorderList label="Input priority order" items={reorder} onReorder={setReorder} /></Specimen>
        <Specimen title="Chart tokens only"><div className="lab-chart-swatches">{chartStyles.map((style, index) => <div key={index}><span style={{ background: style.color }} /><code>series.{index + 1}</code></div>)}</div><p className="lab-note">No charting dependency is bundled. Consumers receive semantic palette and stroke tokens only.</p></Specimen>
      </div>
    </>
  );
}

function RuntimeSpecimens() {
  const [scenario, setScenario] = useState<MockScenario>("success");
  const [events, setEvents] = useState<readonly string[]>(["runtime.sync / READY"]);
  const execute = async () => {
    const result = await designLabTransport.request(scenario, { requestId: "lab-request", ownerEpoch: 42 });
    const line = result.ok ? `${scenario} / OK` : `${scenario} / ${result.error?.code ?? "UNKNOWN"}`;
    setEvents((current) => [line, ...current].slice(0, 8));
  };
  return (
    <>
      <FamilyHeader code="12" eyebrow="RUNTIME" title="Runtime contracts" description="Generic surfaces, focus arbitration and transport boundaries without domain state or server-side business logic." />
      <section className="lab-runtime-map">
        <div className="lab-runtime-map__lane"><span>01</span><strong>CALLER</strong><small>captured resource</small></div>
        <div className="lab-runtime-map__connector" aria-hidden="true" />
        <div className="lab-runtime-map__lane"><span>02</span><strong>CLIENT RUNTIME</strong><small>owner epoch + focus lease</small></div>
        <div className="lab-runtime-map__connector" aria-hidden="true" />
        <div className="lab-runtime-map__lane"><span>03</span><strong>NUI</strong><small>static callback routes</small></div>
        <div className="lab-runtime-map__connector" aria-hidden="true" />
        <div className="lab-runtime-map__lane"><span>04</span><strong>RESPONSE</strong><small>correlated + fenced</small></div>
      </section>
      <div className="lab-specimen-grid">
        <Specimen title="Transport scenario runner" wide>
          <Grid columns="minmax(220px, .7fr) minmax(320px, 1.3fr)" gap={18}>
            <Stack gap={12}><Select aria-label="Mock transport scenario" value={scenario} options={[{ value: "success", label: "Success" }, { value: "error", label: "Focus conflict" }, { value: "timeout", label: "Request timeout" }, { value: "malformed", label: "Malformed response" }, { value: "restart", label: "Owner restart" }]} onValueChange={setScenario} /><Button onClick={() => void execute()}>Run scenario</Button><small className="lab-note">Injected mock only. It does not count as FiveM/CEF acceptance.</small></Stack>
            <div className="lab-event-log" role="log" aria-label="Mock transport events">{events.map((event, index) => <div key={`${event}-${index}`}><span>{String(index + 1).padStart(2, "0")}</span><code>{event}</code></div>)}</div>
          </Grid>
        </Specimen>
        <Specimen title="Focus modes"><Stack gap={8}>{["PASSIVE", "KEYBOARD", "POINTER", "EXCLUSIVE"].map((mode, index) => <div className="lab-focus-mode" key={mode}><span>{String(index + 1).padStart(2, "0")}</span><strong>{mode}</strong><Badge variant="outline">P{index * 20 + 20}</Badge></div>)}</Stack></Specimen>
        <Specimen title="Protocol limits"><KeyValueList items={[{ key: "bytes", label: "Payload", value: "32 KiB" }, { key: "depth", label: "Depth", value: "8" }, { key: "entries", label: "Entries", value: "256" }, { key: "pending", label: "Pending", value: "64" }]} /></Specimen>
        <Specimen title="Health contract"><Stack gap={10}><StatusBadge status="online">READY</StatusBadge><StatusBadge status="warning">DEGRADED</StatusBadge><StatusBadge status="error">UNHEALTHY</StatusBadge><p className="lab-note">Counters expose protocol rejection, timeout, conflict, stale-owner and cleanup activity.</p></Stack></Specimen>
        <Specimen title="Closed-state invariant"><div className="lab-closed-state"><span className="lab-closed-state__zero">0</span><div><strong>VISIBLE PIXELS</strong><small>No mounted surface, pointer capture, focus or polling timer.</small></div></div></Specimen>
      </div>
    </>
  );
}

export function SpecimenSection({ section, preferences }: SpecimenSectionProps) {
  switch (section) {
    case "overview": return <Overview preferences={preferences} />;
    case "foundation": return <FoundationSpecimens />;
    case "actions": return <ActionSpecimens />;
    case "forms": return <FormSpecimens />;
    case "selection": return <SelectionSpecimens />;
    case "navigation": return <NavigationSpecimens />;
    case "overlays": return <OverlaySpecimens />;
    case "menus": return <MenuSpecimens />;
    case "feedback": return <FeedbackSpecimens />;
    case "data": return <DataSpecimens />;
    case "utilities": return <UtilitySpecimens />;
    case "advanced": return <AdvancedSpecimens />;
    case "runtime": return <RuntimeSpecimens />;
  }
}
