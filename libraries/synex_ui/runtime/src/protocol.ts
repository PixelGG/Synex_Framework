export const UI_PROTOCOL_VERSION = 1 as const;

export const UI_LIMITS = Object.freeze({
  maxPayloadBytes: 32 * 1024,
  maxDepth: 8,
  maxEntries: 256,
  maxStringLength: 4_096,
  maxPendingRequests: 64,
  maxFields: 24,
  maxOptions: 96,
  maxSections: 16,
  maxMenuItems: 96,
  maxMenuDepth: 3,
  maxSignals: 8,
  maxVisibleSignals: 4,
  maxSignalActions: 2,
  maxSignalRevisionFences: 256,
  maxInteractionIntents: 6,
  maxInteractionDurationMs: 60 * 60 * 1000,
  maxInteractionRevisionFences: 64,
});

export const UI_ERROR_CODES = [
  'UI_NOT_READY',
  'UI_FOCUS_BUSY',
  'UI_FOCUS_DENIED',
  'UI_FOCUS_LEASE_INVALID',
  'UI_SIGNAL_DENIED',
  'UI_INTERACTION_DENIED',
  'UI_OWNER_STOPPED',
  'UI_OWNER_STALE',
  'UI_REQUEST_INVALID',
  'UI_REQUEST_TIMEOUT',
  'UI_REQUEST_CANCELLED',
  'UI_REQUEST_STALE',
  'UI_SURFACE_CONFLICT',
  'UI_PAYLOAD_TOO_LARGE',
  'UI_PROTOCOL_UNSUPPORTED',
] as const;

export type UiErrorCode = (typeof UI_ERROR_CODES)[number];
export type InputDevice = 'mouse' | 'keyboard' | 'gamepad';
export type NavigationIntent =
  | 'UP'
  | 'DOWN'
  | 'LEFT'
  | 'RIGHT'
  | 'CONFIRM'
  | 'BACK'
  | 'NEXT_TAB'
  | 'PREVIOUS_TAB'
  | 'PAGE_UP'
  | 'PAGE_DOWN';
export type QualityProfile = 'LOW' | 'BALANCED' | 'HIGH' | 'ULTRA';
export type Density = 'compact' | 'comfortable';
export type UiScale = 85 | 100 | 115 | 125;
export type SurfaceKind = 'alert' | 'confirm' | 'input' | 'form' | 'select' | 'menu' | 'contextMenu';
export type SurfaceTone = 'neutral' | 'accent' | 'info' | 'success' | 'warning' | 'danger';
export type SignalKind = 'toast' | 'progress' | 'persistent' | 'banner' | 'status';
export type SignalTone = 'neutral' | 'info' | 'success' | 'warning' | 'danger';
export type SignalSoundTone = SignalTone | 'critical';
export type SignalPriority = 'low' | 'normal' | 'high' | 'critical';
export type SignalPosition = 'top-right' | 'top-left' | 'bottom-right' | 'bottom-left' | 'top-center' | 'bottom-center';
export type SignalProgressState = 'PENDING' | 'RUNNING' | 'SUCCESS' | 'FAILED' | 'CANCELLED';
export type SignalProgressMode = 'determinate' | 'indeterminate';
export type SignalActionStyle = 'default' | 'primary' | 'danger';
export type InteractionMode = 'cue' | 'bloom' | 'progress';
export type InteractionProgressMode = 'determinate' | 'indeterminate' | 'timed';

export interface UiPreferences {
  schemaVersion: 1;
  quality: QualityProfile;
  scale: UiScale;
  density: Density;
  reducedMotion: boolean;
  reducedTransparency: boolean;
  highContrast: boolean;
  interactionAssist: boolean;
}

export interface ScreenMetrics {
  width: number;
  height: number;
  aspectRatio: number;
  safeLeft: number;
  safeRight: number;
  safeTop: number;
  safeBottom: number;
}

export interface SurfaceOption {
  id: string;
  label: string;
  description?: string;
  disabled?: boolean;
  danger?: boolean;
  icon?: string;
  shortcut?: string;
  metadata?: Record<string, unknown>;
  options?: SurfaceOption[];
}

export interface SurfaceSection {
  id: string;
  label?: string;
  items: SurfaceOption[];
}

export interface SurfaceField {
  id: string;
  type: 'text' | 'number' | 'textarea' | 'select' | 'multi-select' | 'checkbox' | 'radio' | 'switch' | 'slider';
  label: string;
  description?: string;
  placeholder?: string;
  required?: boolean;
  disabled?: boolean;
  min?: number;
  max?: number;
  step?: number;
  minLength?: number;
  maxLength?: number;
  options: SurfaceOption[];
  value?: string | number | boolean | string[];
}

export interface SurfaceDescriptor {
  requestId: string;
  instanceId: string;
  surfaceId: string;
  kind: SurfaceKind;
  title: string;
  description?: string;
  tone: SurfaceTone;
  dismissible: boolean;
  confirmLabel?: string;
  cancelLabel?: string;
  fields: SurfaceField[];
  options: SurfaceOption[];
  sections: SurfaceSection[];
  multiple?: boolean;
  searchable?: boolean;
  placeholder?: string;
  anchor?: { x: number; y: number };
  initialFocus?: string;
}

export interface RuntimeSurface extends SurfaceDescriptor {
  ownerResource: string;
  ownerEpoch: number;
  revision: number;
}

export interface SignalProgress {
  state: SignalProgressState;
  mode: SignalProgressMode;
  value?: number;
  maximum?: number;
}

export interface SignalActionHint {
  token: string;
  label: string;
  hint?: string;
  style?: SignalActionStyle;
}

export interface SignalDescriptor {
  signalId: string;
  revision: number;
  kind: SignalKind;
  tone: SignalTone;
  priority: SignalPriority;
  title: string;
  message?: string;
  iconKey?: (typeof UI_ICON_KEYS)[number];
  count?: number;
  progress?: SignalProgress;
  actions: SignalActionHint[];
  createdAt: number;
  expiresAt?: number;
  position: SignalPosition;
}

export interface RuntimeSignal extends SignalDescriptor {
  ownerResource: string;
  ownerEpoch: number;
}

export interface SignalSoundPayload {
  tone: SignalSoundTone;
  volume: number;
}

export interface SignalSoundMessagePayload extends SignalSoundPayload {
  browserBootId: string;
}

export interface InteractionProjection {
  visible: boolean;
  behindCamera: boolean;
  x: number;
  y: number;
}

export interface InteractionInputBinding {
  keyboard: string;
  gamepad: string;
  mouse?: string;
}

export interface InteractionInputHints {
  primary?: InteractionInputBinding;
  more?: InteractionInputBinding;
  cancel?: InteractionInputBinding;
}

export interface InteractionIntent {
  intentId: string;
  label: string;
  description?: string;
  iconKey?: (typeof UI_ICON_KEYS)[number];
  disabled?: boolean;
}

export type InteractionProgress =
  | { mode: 'determinate'; value: number; maximum: number }
  | { mode: 'indeterminate' }
  | { mode: 'timed'; elapsedMs: number; durationMs: number };

export interface InteractionDescriptor {
  interactionId: string;
  revision: number;
  mode: InteractionMode;
  label: string;
  targetLabel?: string;
  projection?: InteractionProjection;
  intents: InteractionIntent[];
  selectedIntentId?: string;
  moreCount?: number;
  pointer: boolean;
  input: InteractionInputHints;
  progress?: InteractionProgress;
  cancellable: boolean;
}

export interface RuntimeInteraction extends InteractionDescriptor {
  ownerResource: string;
  ownerEpoch: number;
}

export interface RuntimeSnapshot {
  browserBootId: string;
  ready: boolean;
  surfaces: RuntimeSurface[];
  signals: RuntimeSignal[];
  signalGeneration: number;
  signalRevisions: Record<string, number>;
  interaction: RuntimeInteraction | null;
  interactionGeneration: number;
  interactionRevisions: Record<string, number>;
  preferences: UiPreferences;
  screen: ScreenMetrics;
  inputDevice: InputDevice;
  health: 'READY' | 'DEGRADED' | 'UNHEALTHY';
}

export type GameMessageType =
  | 'runtime:sync'
  | 'runtime:shutdown'
  | 'surface:open'
  | 'surface:update'
  | 'surface:close'
  | 'signal:upsert'
  | 'signal:remove'
  | 'signal:sound'
  | 'interaction:upsert'
  | 'interaction:remove'
  | 'input:intent'
  | 'preferences:sync';

export interface GameEnvelope {
  protocolVersion: 1;
  messageId: string;
  type: GameMessageType;
  ownerResource: string;
  ownerEpoch: number;
  revision: number;
  payload: Record<string, unknown>;
}

export interface UiError {
  code: UiErrorCode | 'NUI_HTTP_ERROR' | 'NUI_RESPONSE_INVALID' | 'NUI_UNAVAILABLE';
  message?: string;
}

export type NuiResponse<T = unknown> =
  | { ok: true; data?: T }
  | { ok: false; error: UiError };

const allowedMessageTypes = new Set<GameMessageType>([
  'runtime:sync',
  'runtime:shutdown',
  'surface:open',
  'surface:update',
  'surface:close',
  'signal:upsert',
  'signal:remove',
  'signal:sound',
  'interaction:upsert',
  'interaction:remove',
  'input:intent',
  'preferences:sync',
]);

const surfaceKinds = new Set<SurfaceKind>(['alert', 'confirm', 'input', 'form', 'select', 'menu', 'contextMenu']);
const surfaceTones = new Set<SurfaceTone>(['neutral', 'accent', 'info', 'success', 'warning', 'danger']);
const signalKinds = new Set<SignalKind>(['toast', 'progress', 'persistent', 'banner', 'status']);
const signalTones = new Set<SignalTone>(['neutral', 'info', 'success', 'warning', 'danger']);
const signalSoundTones = new Set<SignalSoundTone>([
  'neutral', 'info', 'success', 'warning', 'danger', 'critical',
]);
const signalPriorities = new Set<SignalPriority>(['low', 'normal', 'high', 'critical']);
const signalPositions = new Set<SignalPosition>([
  'top-right', 'top-left', 'bottom-right', 'bottom-left', 'top-center', 'bottom-center',
]);
const signalProgressStates = new Set<SignalProgressState>(['PENDING', 'RUNNING', 'SUCCESS', 'FAILED', 'CANCELLED']);
const signalProgressModes = new Set<SignalProgressMode>(['determinate', 'indeterminate']);
const signalActionStyles = new Set<SignalActionStyle>(['default', 'primary', 'danger']);
const interactionModes = new Set<InteractionMode>(['cue', 'bloom', 'progress']);
const interactionProgressModes = new Set<InteractionProgressMode>(['determinate', 'indeterminate', 'timed']);
const unsafeSignalTextPattern = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
const forbiddenPayloadKeys = new Set(['html', 'svg', 'url', 'href', 'src', 'iframe', 'script']);
const safeIdPattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$/;
export const UI_ICON_KEYS = [
  'check', 'close', 'chevron-down', 'chevron-right', 'arrow-left', 'arrow-right', 'search',
  'plus', 'minus', 'more', 'copy', 'eye', 'eye-off', 'info', 'warning', 'error', 'success',
  'menu', 'command', 'signal',
] as const;
const iconKeys = new Set<string>(UI_ICON_KEYS);

export function isPlainRecord(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value) as object | null;
  return prototype === Object.prototype || prototype === null;
}

function encodedBytes(value: unknown): number {
  try {
    return new TextEncoder().encode(JSON.stringify(value)).byteLength;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

export function isBoundedPayload(value: unknown): boolean {
  if (encodedBytes(value) > UI_LIMITS.maxPayloadBytes) return false;
  let entries = 0;
  const seen = new Set<object>();

  const walk = (current: unknown, depth: number): boolean => {
    if (current === null || typeof current === 'boolean') return true;
    if (typeof current === 'number') return Number.isFinite(current);
    if (typeof current === 'string') return current.length <= UI_LIMITS.maxStringLength;
    if (depth > UI_LIMITS.maxDepth) return false;
    if (typeof current !== 'object' || seen.has(current)) return false;
    seen.add(current);

    if (Array.isArray(current)) {
      if (current.length > UI_LIMITS.maxEntries) return false;
      entries += current.length;
      if (entries > UI_LIMITS.maxEntries) return false;
      return current.every((item) => walk(item, depth + 1));
    }
    if (!isPlainRecord(current)) return false;
    const objectEntries = Object.entries(current);
    entries += objectEntries.length;
    if (entries > UI_LIMITS.maxEntries) return false;
    return objectEntries.every(([key, item]) =>
      key.length <= 64 && !forbiddenPayloadKeys.has(key.toLowerCase()) && walk(item, depth + 1),
    );
  };

  return walk(value, 0);
}

function readText(value: unknown, maximum: number): string | undefined {
  return typeof value === 'string' && value.length > 0 && value.length <= maximum ? value : undefined;
}

function readSignalText(value: unknown, maximum: number, allowEmpty = false): string | undefined {
  return typeof value === 'string' && value.length <= maximum && (allowEmpty || value.length > 0)
    && !unsafeSignalTextPattern.test(value) ? value : undefined;
}

function readId(value: unknown, maximum = 96): string | undefined {
  return typeof value === 'string' && value.length <= maximum && safeIdPattern.test(value) ? value : undefined;
}

function readFinite(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

interface OptionCounter { count: number; ids: Set<string> }

function parseOption(value: unknown, depth = 1, counter: OptionCounter = { count: 0, ids: new Set() }): SurfaceOption | null {
  if (depth > UI_LIMITS.maxMenuDepth || !isPlainRecord(value)) return null;
  if (Object.keys(value).some((key) => !['id', 'label', 'description', 'disabled', 'danger', 'icon', 'shortcut', 'metadata', 'options'].includes(key))) return null;
  counter.count += 1;
  if (counter.count > UI_LIMITS.maxMenuItems) return null;
  const id = readId(value.id, 64);
  const label = readText(value.label, 160);
  if (!id || !label) return null;
  if (counter.ids.has(id)) return null;
  counter.ids.add(id);
  if (value.description !== undefined && (typeof value.description !== 'string' || value.description.length > 512)) return null;
  if (value.disabled !== undefined && typeof value.disabled !== 'boolean') return null;
  if (value.danger !== undefined && typeof value.danger !== 'boolean') return null;
  if (value.icon !== undefined && (typeof value.icon !== 'string' || !iconKeys.has(value.icon))) return null;
  if (value.shortcut !== undefined && (typeof value.shortcut !== 'string' || value.shortcut.length === 0 || value.shortcut.length > 48)) return null;
  if (value.metadata !== undefined && (!isPlainRecord(value.metadata) || !isBoundedPayload(value.metadata))) return null;
  const option: SurfaceOption = { id, label };
  const description = readText(value.description, 512);
  const icon = readText(value.icon, 48);
  const shortcut = readText(value.shortcut, 48);
  if (description) option.description = description;
  if (icon && iconKeys.has(icon)) option.icon = icon;
  if (shortcut) option.shortcut = shortcut;
  if (isPlainRecord(value.metadata)) option.metadata = { ...value.metadata };
  if (value.disabled === true) option.disabled = true;
  if (value.danger === true) option.danger = true;
  if (Array.isArray(value.options)) {
    if (value.options.length < 1 || value.options.length > UI_LIMITS.maxOptions) return null;
    const nested = value.options.map((item) => parseOption(item, depth + 1, counter));
    if (nested.some((item) => item === null)) return null;
    option.options = nested as SurfaceOption[];
  }
  return option;
}

function parseOptions(value: unknown, depth = 1, counter: OptionCounter = { count: 0, ids: new Set() }): SurfaceOption[] | null {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > UI_LIMITS.maxOptions) return null;
  const options = value.map((item) => parseOption(item, depth, counter));
  if (options.some((item) => item === null)) return null;
  const parsed = options as SurfaceOption[];
  return new Set(parsed.map((option) => option.id)).size === parsed.length ? parsed : null;
}

function parseField(value: unknown): SurfaceField | null {
  if (!isPlainRecord(value)) return null;
  if (Object.keys(value).some((key) => ![
    'id', 'type', 'label', 'description', 'placeholder', 'required', 'disabled', 'min', 'max',
    'step', 'minLength', 'maxLength', 'options', 'value',
  ].includes(key))) return null;
  const id = readId(value.id, 64);
  const label = readText(value.label, 160);
  const fieldTypes = new Set<SurfaceField['type']>([
    'text', 'number', 'textarea', 'select', 'multi-select', 'checkbox', 'radio', 'switch', 'slider',
  ]);
  if (!id || !label || typeof value.type !== 'string' || !fieldTypes.has(value.type as SurfaceField['type'])) return null;
  if (value.description !== undefined && (typeof value.description !== 'string' || value.description.length > 512)) return null;
  if (value.placeholder !== undefined && (typeof value.placeholder !== 'string' || value.placeholder.length > 256)) return null;
  if (value.required !== undefined && typeof value.required !== 'boolean') return null;
  if (value.disabled !== undefined && typeof value.disabled !== 'boolean') return null;
  if (value.min !== undefined && readFinite(value.min) === undefined) return null;
  if (value.max !== undefined && readFinite(value.max) === undefined) return null;
  if (value.step !== undefined && (readFinite(value.step) === undefined || (value.step as number) <= 0)) return null;
  if (value.minLength !== undefined && (!Number.isInteger(value.minLength) || (value.minLength as number) < 0 || (value.minLength as number) > UI_LIMITS.maxStringLength)) return null;
  if (value.maxLength !== undefined && (!Number.isInteger(value.maxLength) || (value.maxLength as number) < 1 || (value.maxLength as number) > UI_LIMITS.maxStringLength)) return null;
  const requiresOptions = value.type === 'select' || value.type === 'multi-select' || value.type === 'radio';
  if (requiresOptions !== Array.isArray(value.options)) return null;
  const options = parseOptions(value.options);
  if (options === null || (requiresOptions && (options.length === 0 || options.some((option) => option.options !== undefined)))) return null;
  const field: SurfaceField = { id, label, type: value.type as SurfaceField['type'], options };
  const description = readText(value.description, 512);
  const placeholder = readText(value.placeholder, 256);
  if (description) field.description = description;
  if (placeholder) field.placeholder = placeholder;
  if (value.required === true) field.required = true;
  if (value.disabled === true) field.disabled = true;
  const min = readFinite(value.min);
  const max = readFinite(value.max);
  const step = readFinite(value.step);
  if (min !== undefined && max !== undefined && min > max) return null;
  if (min !== undefined) field.min = min;
  if (max !== undefined) field.max = max;
  if (step !== undefined && step > 0) field.step = step;
  if (Number.isInteger(value.minLength) && (value.minLength as number) >= 0 && (value.minLength as number) <= UI_LIMITS.maxStringLength) {
    field.minLength = value.minLength as number;
  }
  if (Number.isInteger(value.maxLength) && (value.maxLength as number) > 0 && (value.maxLength as number) <= UI_LIMITS.maxStringLength) {
    field.maxLength = value.maxLength as number;
  }
  if (field.minLength !== undefined && field.maxLength !== undefined && field.minLength > field.maxLength) return null;
  if (value.value !== undefined) {
    if (field.type === 'number' || field.type === 'slider') {
      const numeric = readFinite(value.value);
      if (numeric === undefined) return null;
      field.value = numeric;
    } else if (field.type === 'checkbox' || field.type === 'switch') {
      if (typeof value.value !== 'boolean') return null;
      field.value = value.value;
    } else if (field.type === 'multi-select') {
      if (!Array.isArray(value.value) || value.value.length > UI_LIMITS.maxOptions
        || !value.value.every((item) => readId(item, 64) !== undefined)
        || new Set(value.value).size !== value.value.length) return null;
      field.value = value.value as string[];
    } else {
      if (typeof value.value !== 'string' || value.value.length > UI_LIMITS.maxStringLength) return null;
      field.value = value.value;
    }
  }
  return field;
}

export function parseSurfaceDescriptor(value: unknown): SurfaceDescriptor | null {
  if (!isPlainRecord(value) || !isBoundedPayload(value)) return null;
  const surfaceId = readId(value.surfaceId);
  const requestId = readId(value.requestId);
  const instanceId = readId(value.instanceId);
  const title = readText(value.title, 160);
  if (!requestId || !instanceId || !surfaceId || !title || typeof value.kind !== 'string'
    || !surfaceKinds.has(value.kind as SurfaceKind)) return null;
  const kind = value.kind as SurfaceKind;
  if (value.tone !== undefined && (typeof value.tone !== 'string' || !surfaceTones.has(value.tone as SurfaceTone))) return null;
  if (value.dismissible !== undefined && typeof value.dismissible !== 'boolean') return null;
  if (value.confirmLabel !== undefined && !readText(value.confirmLabel, 96)) return null;
  if (value.cancelLabel !== undefined && !readText(value.cancelLabel, 96)) return null;
  if (value.initialFocus !== undefined && !readId(value.initialFocus, 64)) return null;
  const allowedCommon = new Set([
    'requestId', 'instanceId', 'surfaceId', 'kind', 'title', 'description', 'tone', 'dismissible',
    'confirmLabel', 'cancelLabel', 'initialFocus', 'ownerResource', 'ownerEpoch', 'revision',
  ]);
  const allowedByKind: Record<SurfaceKind, readonly string[]> = {
    alert: [],
    confirm: [],
    input: ['fields'],
    form: ['fields'],
    select: ['options', 'multiple', 'searchable', 'placeholder'],
    menu: ['sections'],
    contextMenu: ['sections', 'anchor'],
  };
  const allowedKeys = new Set([...allowedCommon, ...allowedByKind[kind]]);
  if (Object.keys(value).some((key) => !allowedKeys.has(key))) return null;
  const optionCounter = { count: 0, ids: new Set<string>() };
  const options = parseOptions(value.options, 1, optionCounter);
  if (options === null) return null;
  const rawFields = value.fields ?? [];
  if (!Array.isArray(rawFields) || rawFields.length > UI_LIMITS.maxFields) return null;
  const fields = rawFields.map(parseField);
  if (fields.some((field) => field === null)) return null;
  const parsedFields = fields as SurfaceField[];
  if (new Set(parsedFields.map((field) => field.id)).size !== parsedFields.length) return null;
  const rawSections = value.sections ?? [];
  if (!Array.isArray(rawSections) || rawSections.length > UI_LIMITS.maxSections) return null;
  const sections: SurfaceSection[] = [];
  const sectionIds = new Set<string>();
  for (const rawSection of rawSections) {
    if (!isPlainRecord(rawSection)) return null;
    if (Object.keys(rawSection).some((key) => !['id', 'label', 'items'].includes(key))) return null;
    if (rawSection.label !== undefined && (typeof rawSection.label !== 'string' || rawSection.label.length > 160)) return null;
    const id = readId(rawSection.id, 64);
    const items = parseOptions(rawSection.items, 1, optionCounter);
    if (!id || items === null || items.length === 0 || sectionIds.has(id)) return null;
    sectionIds.add(id);
    const section: SurfaceSection = { id, items };
    const label = readText(rawSection.label, 160);
    if (label) section.label = label;
    sections.push(section);
  }
  if (kind === 'input' && parsedFields.length !== 1) return null;
  if (kind === 'form' && parsedFields.length === 0) return null;
  if (kind === 'select' && (options.length === 0 || options.some((option) => option.options !== undefined))) return null;
  if ((kind === 'menu' || kind === 'contextMenu') && sections.length === 0) return null;
  const descriptor: SurfaceDescriptor = {
    requestId,
    instanceId,
    surfaceId,
    kind,
    title,
    tone: typeof value.tone === 'string' && surfaceTones.has(value.tone as SurfaceTone)
      ? value.tone as SurfaceTone
      : 'neutral',
    dismissible: value.dismissible !== false,
    fields: parsedFields,
    options,
    sections,
  };
  const description = readText(value.description, 2_048);
  const confirmLabel = readText(value.confirmLabel, 96);
  const cancelLabel = readText(value.cancelLabel, 96);
  const initialFocus = readId(value.initialFocus, 64);
  const placeholder = readText(value.placeholder, 256);
  if (description) descriptor.description = description;
  if (confirmLabel) descriptor.confirmLabel = confirmLabel;
  if (cancelLabel) descriptor.cancelLabel = cancelLabel;
  if (initialFocus) descriptor.initialFocus = initialFocus;
  if (kind === 'select') {
    if (value.multiple !== undefined && typeof value.multiple !== 'boolean') return null;
    if (value.searchable !== undefined && typeof value.searchable !== 'boolean') return null;
    if (value.multiple === true) descriptor.multiple = true;
    if (value.searchable === true) descriptor.searchable = true;
    if (placeholder) descriptor.placeholder = placeholder;
  }
  if (kind === 'contextMenu') {
    if (!isPlainRecord(value.anchor)) return null;
    if (Object.keys(value.anchor).some((key) => !['x', 'y'].includes(key))) return null;
    const x = readFinite(value.anchor.x);
    const y = readFinite(value.anchor.y);
    if (x === undefined || y === undefined || x < 0 || x > 1 || y < 0 || y > 1) return null;
    descriptor.anchor = { x, y };
  }
  return descriptor;
}

function parseSignalProgress(value: unknown): SignalProgress | null {
  if (!isPlainRecord(value) || Object.keys(value).some((key) => !['state', 'mode', 'value', 'maximum'].includes(key))) {
    return null;
  }
  if (typeof value.state !== 'string' || !signalProgressStates.has(value.state as SignalProgressState)
    || typeof value.mode !== 'string' || !signalProgressModes.has(value.mode as SignalProgressMode)) return null;
  const mode = value.mode as SignalProgressMode;
  if (mode === 'indeterminate') {
    if (value.value !== undefined || value.maximum !== undefined) return null;
    return { state: value.state as SignalProgressState, mode };
  }
  const current = readFinite(value.value);
  const maximum = readFinite(value.maximum);
  if (current === undefined || maximum === undefined || current < 0 || maximum <= 0 || current > maximum
    || current > Number.MAX_SAFE_INTEGER || maximum > Number.MAX_SAFE_INTEGER) return null;
  return { state: value.state as SignalProgressState, mode, value: current, maximum };
}

function parseSignalAction(value: unknown): SignalActionHint | null {
  if (!isPlainRecord(value) || Object.keys(value).some((key) => !['token', 'label', 'hint', 'style'].includes(key))) {
    return null;
  }
  const token = readId(value.token, 96);
  const label = readSignalText(value.label, 64);
  if (!token || !label) return null;
  if (value.hint !== undefined && !readSignalText(value.hint, 24)) return null;
  if (value.style !== undefined && (typeof value.style !== 'string'
    || !signalActionStyles.has(value.style as SignalActionStyle))) return null;
  const action: SignalActionHint = { token, label };
  const hint = readSignalText(value.hint, 24);
  if (hint) action.hint = hint;
  if (typeof value.style === 'string') action.style = value.style as SignalActionStyle;
  return action;
}

function parseInteractionProjection(value: unknown): InteractionProjection | null {
  if (!isPlainRecord(value)
    || Object.keys(value).some((key) => !['visible', 'behindCamera', 'x', 'y'].includes(key))
    || typeof value.visible !== 'boolean' || typeof value.behindCamera !== 'boolean') return null;
  const x = readFinite(value.x);
  const y = readFinite(value.y);
  if (x === undefined || y === undefined || x < 0 || x > 1 || y < 0 || y > 1) return null;
  return { visible: value.visible, behindCamera: value.behindCamera, x, y };
}

function parseInteractionInputBinding(value: unknown): InteractionInputBinding | null {
  if (!isPlainRecord(value)
    || Object.keys(value).some((key) => !['keyboard', 'gamepad', 'mouse'].includes(key))) return null;
  const keyboard = readSignalText(value.keyboard, 24);
  const gamepad = readSignalText(value.gamepad, 24);
  if (!keyboard || !gamepad) return null;
  if (value.mouse !== undefined && !readSignalText(value.mouse, 24)) return null;
  const binding: InteractionInputBinding = { keyboard, gamepad };
  const mouse = readSignalText(value.mouse, 24);
  if (mouse) binding.mouse = mouse;
  return binding;
}

function parseInteractionInputHints(value: unknown): InteractionInputHints | null {
  if (!isPlainRecord(value)
    || Object.keys(value).some((key) => !['primary', 'more', 'cancel'].includes(key))) return null;
  const primary = value.primary === undefined ? undefined : parseInteractionInputBinding(value.primary);
  const more = value.more === undefined ? undefined : parseInteractionInputBinding(value.more);
  const cancel = value.cancel === undefined ? undefined : parseInteractionInputBinding(value.cancel);
  if ((value.primary !== undefined && !primary) || (value.more !== undefined && !more)
    || (value.cancel !== undefined && !cancel)) return null;
  const hints: InteractionInputHints = {};
  if (primary) hints.primary = primary;
  if (more) hints.more = more;
  if (cancel) hints.cancel = cancel;
  return hints;
}

function parseInteractionIntent(value: unknown): InteractionIntent | null {
  if (!isPlainRecord(value)
    || Object.keys(value).some((key) => !['intentId', 'label', 'description', 'iconKey', 'disabled'].includes(key))) {
    return null;
  }
  const intentId = readId(value.intentId, 96);
  const label = readSignalText(value.label, 96);
  if (!intentId || !label) return null;
  if (value.description !== undefined && !readSignalText(value.description, 180)) return null;
  if (value.iconKey !== undefined && (typeof value.iconKey !== 'string' || !iconKeys.has(value.iconKey))) return null;
  if (value.disabled !== undefined && typeof value.disabled !== 'boolean') return null;
  const intent: InteractionIntent = { intentId, label };
  const description = readSignalText(value.description, 180);
  if (description) intent.description = description;
  if (typeof value.iconKey === 'string') intent.iconKey = value.iconKey as InteractionIntent['iconKey'];
  if (value.disabled === true) intent.disabled = true;
  return intent;
}

function parseInteractionProgress(value: unknown): InteractionProgress | null {
  if (!isPlainRecord(value)
    || Object.keys(value).some((key) => !['mode', 'value', 'maximum', 'elapsedMs', 'durationMs'].includes(key))
    || typeof value.mode !== 'string'
    || !interactionProgressModes.has(value.mode as InteractionProgressMode)) return null;
  if (value.mode === 'indeterminate') {
    if (Object.keys(value).length !== 1) return null;
    return { mode: 'indeterminate' };
  }
  if (value.mode === 'determinate') {
    if (Object.keys(value).some((key) => !['mode', 'value', 'maximum'].includes(key))) return null;
    const current = readFinite(value.value);
    const maximum = readFinite(value.maximum);
    if (current === undefined || maximum === undefined || current < 0 || maximum <= 0 || current > maximum
      || current > Number.MAX_SAFE_INTEGER || maximum > Number.MAX_SAFE_INTEGER) return null;
    return { mode: 'determinate', value: current, maximum };
  }
  if (Object.keys(value).some((key) => !['mode', 'elapsedMs', 'durationMs'].includes(key))) return null;
  const elapsedMs = readFinite(value.elapsedMs);
  const durationMs = readFinite(value.durationMs);
  if (!Number.isSafeInteger(elapsedMs) || !Number.isSafeInteger(durationMs)
    || (elapsedMs as number) < 0 || (durationMs as number) < 1
    || (durationMs as number) > UI_LIMITS.maxInteractionDurationMs
    || (elapsedMs as number) > (durationMs as number)) return null;
  return { mode: 'timed', elapsedMs: elapsedMs as number, durationMs: durationMs as number };
}

export function parseInteractionDescriptor(value: unknown): InteractionDescriptor | null {
  if (!isPlainRecord(value) || !isBoundedPayload(value)) return null;
  const allowed = [
    'interactionId', 'revision', 'mode', 'label', 'targetLabel', 'projection', 'intents',
    'selectedIntentId', 'moreCount', 'pointer', 'input', 'progress', 'cancellable',
  ];
  if (Object.keys(value).some((key) => !allowed.includes(key))) return null;
  const interactionId = readId(value.interactionId, 96);
  const revision = readFinite(value.revision);
  const label = readSignalText(value.label, 120);
  if (!interactionId || !Number.isSafeInteger(revision) || (revision as number) < 1 || !label
    || typeof value.mode !== 'string' || !interactionModes.has(value.mode as InteractionMode)
    || typeof value.pointer !== 'boolean' || typeof value.cancellable !== 'boolean') return null;
  if (value.targetLabel !== undefined && !readSignalText(value.targetLabel, 80)) return null;
  const projection = value.projection === undefined ? undefined : parseInteractionProjection(value.projection);
  if (value.projection !== undefined && !projection) return null;
  const input = parseInteractionInputHints(value.input);
  if (!input || !Array.isArray(value.intents)
    || value.intents.length > UI_LIMITS.maxInteractionIntents) return null;
  const parsedIntents = value.intents.map(parseInteractionIntent);
  if (parsedIntents.some((intent) => intent === null)) return null;
  const intents = parsedIntents as InteractionIntent[];
  if (new Set(intents.map((intent) => intent.intentId)).size !== intents.length) return null;
  const selectedIntentId = value.selectedIntentId === undefined ? undefined : readId(value.selectedIntentId, 96);
  if (value.selectedIntentId !== undefined && !selectedIntentId) return null;
  const selected = selectedIntentId
    ? intents.find((intent) => intent.intentId === selectedIntentId && intent.disabled !== true)
    : undefined;
  const progress = value.progress === undefined ? undefined : parseInteractionProgress(value.progress);
  if (value.progress !== undefined && !progress) return null;
  if (value.moreCount !== undefined && (!Number.isSafeInteger(value.moreCount)
    || (value.moreCount as number) < 0 || (value.moreCount as number) > 99)) return null;

  const mode = value.mode as InteractionMode;
  if (mode === 'cue') {
    const moreCount = typeof value.moreCount === 'number' ? value.moreCount : 0;
    if (intents.length !== 1 || value.pointer !== false || value.cancellable !== false || progress
      || (selectedIntentId !== undefined && selectedIntentId !== intents[0]?.intentId)
      || !input.primary || input.cancel || (moreCount > 0) !== Boolean(input.more)) return null;
  } else if (mode === 'bloom') {
    if (intents.length < 2 || intents.length > UI_LIMITS.maxInteractionIntents || !selected
      || progress || value.moreCount !== undefined || !input.primary || !input.cancel || input.more
      || value.cancellable !== true) return null;
  } else if (intents.length !== 0 || selectedIntentId !== undefined || value.moreCount !== undefined
    || value.pointer !== false || !progress || input.primary || input.more
    || value.cancellable !== Boolean(input.cancel)) return null;

  const descriptor: InteractionDescriptor = {
    interactionId,
    revision: revision as number,
    mode,
    label,
    intents,
    pointer: value.pointer,
    input,
    cancellable: value.cancellable,
  };
  const targetLabel = readSignalText(value.targetLabel, 80);
  if (targetLabel) descriptor.targetLabel = targetLabel;
  if (projection) descriptor.projection = projection;
  if (selectedIntentId) descriptor.selectedIntentId = selectedIntentId;
  if (typeof value.moreCount === 'number') descriptor.moreCount = value.moreCount;
  if (progress) descriptor.progress = progress;
  return descriptor;
}

export function parseSignalDescriptor(value: unknown): SignalDescriptor | null {
  if (!isPlainRecord(value) || !isBoundedPayload(value)) return null;
  const allowed = [
    'signalId', 'revision', 'kind', 'tone', 'priority', 'title', 'message', 'iconKey', 'count',
    'progress', 'actions', 'createdAt', 'expiresAt', 'position',
  ];
  if (Object.keys(value).some((key) => !allowed.includes(key))) return null;
  const signalId = readId(value.signalId);
  const revision = readFinite(value.revision);
  const title = readSignalText(value.title, 120);
  const createdAt = readFinite(value.createdAt);
  if (!signalId || !Number.isSafeInteger(revision) || (revision as number) < 1 || !title
    || !Number.isSafeInteger(createdAt) || (createdAt as number) < 0
    || typeof value.kind !== 'string' || !signalKinds.has(value.kind as SignalKind)
    || typeof value.tone !== 'string' || !signalTones.has(value.tone as SignalTone)
    || typeof value.priority !== 'string' || !signalPriorities.has(value.priority as SignalPriority)
    || typeof value.position !== 'string' || !signalPositions.has(value.position as SignalPosition)) return null;
  if (value.message !== undefined && readSignalText(value.message, 720, true) === undefined) return null;
  if (value.iconKey !== undefined && (typeof value.iconKey !== 'string' || !iconKeys.has(value.iconKey))) return null;
  if (value.count !== undefined && (!Number.isSafeInteger(value.count) || (value.count as number) < 1
    || (value.count as number) > 9_999)) return null;
  if (value.expiresAt !== undefined && (!Number.isSafeInteger(value.expiresAt)
    || (value.expiresAt as number) <= (createdAt as number))) return null;
  const progress = value.progress === undefined ? undefined : parseSignalProgress(value.progress);
  if (value.progress !== undefined && progress === null) return null;
  const rawActions = value.actions ?? [];
  if (!Array.isArray(rawActions) || rawActions.length > UI_LIMITS.maxSignalActions) return null;
  const parsedActions = rawActions.map(parseSignalAction);
  if (parsedActions.some((action) => action === null)) return null;
  const actions = parsedActions as SignalActionHint[];
  if (new Set(actions.map((action) => action.token)).size !== actions.length) return null;
  const descriptor: SignalDescriptor = {
    signalId,
    revision: revision as number,
    kind: value.kind as SignalKind,
    tone: value.tone as SignalTone,
    priority: value.priority as SignalPriority,
    title,
    actions,
    createdAt: createdAt as number,
    position: value.position as SignalPosition,
  };
  if (typeof value.message === 'string' && value.message.length > 0) descriptor.message = value.message;
  if (typeof value.iconKey === 'string') descriptor.iconKey = value.iconKey as SignalDescriptor['iconKey'];
  if (typeof value.count === 'number') descriptor.count = value.count;
  if (progress) descriptor.progress = progress;
  if (typeof value.expiresAt === 'number') descriptor.expiresAt = value.expiresAt;
  return descriptor;
}

export function parseSignalSoundPayload(value: unknown): SignalSoundMessagePayload | null {
  if (!isPlainRecord(value) || Object.keys(value).length !== 3
    || Object.keys(value).some((key) => !['tone', 'volume', 'browserBootId'].includes(key))
    || typeof value.tone !== 'string' || !signalSoundTones.has(value.tone as SignalSoundTone)
    || !Number.isSafeInteger(value.volume) || (value.volume as number) < 1
    || (value.volume as number) > 100) return null;
  const browserBootId = readId(value.browserBootId);
  if (!browserBootId) return null;
  return {
    tone: value.tone as SignalSoundTone,
    volume: value.volume as number,
    browserBootId,
  };
}

export function parseGameEnvelope(value: unknown): GameEnvelope | null {
  if (!isPlainRecord(value) || !isBoundedPayload(value)) return null;
  if (Object.keys(value).some((key) => ![
    'protocolVersion', 'messageId', 'type', 'ownerResource', 'ownerEpoch', 'revision', 'payload',
  ].includes(key))) return null;
  if (value.protocolVersion !== UI_PROTOCOL_VERSION) return null;
  const messageId = readId(value.messageId);
  const ownerResource = readId(value.ownerResource);
  const ownerEpoch = readFinite(value.ownerEpoch);
  const revision = readFinite(value.revision);
  if (!messageId || !ownerResource || !Number.isInteger(ownerEpoch) || (ownerEpoch as number) < 1
    || !Number.isInteger(revision) || (revision as number) < 0
    || typeof value.type !== 'string' || !allowedMessageTypes.has(value.type as GameMessageType)
    || !isPlainRecord(value.payload)) return null;
  let payload: Record<string, unknown> = value.payload;
  if (value.type === 'signal:sound') {
    const sound = parseSignalSoundPayload(value.payload);
    if (!sound || ownerResource !== 'synex_notify' || revision !== 0) return null;
    payload = { tone: sound.tone, volume: sound.volume, browserBootId: sound.browserBootId };
  } else if (value.type === 'interaction:upsert') {
    if (ownerResource !== 'synex_interact') return null;
    const { generation, ...rawDescriptor } = value.payload;
    const descriptor = parseInteractionDescriptor(rawDescriptor);
    if (!descriptor || descriptor.revision !== revision || !Number.isSafeInteger(generation)
      || (generation as number) < 1) return null;
    payload = { ...descriptor, generation: generation as number };
  } else if (value.type === 'interaction:remove') {
    if (ownerResource !== 'synex_interact'
      || Object.keys(value.payload).some((key) => !['interactionId', 'generation'].includes(key))) return null;
    const interactionId = readId(value.payload.interactionId, 96);
    const generation = readFinite(value.payload.generation);
    if (!interactionId || !Number.isSafeInteger(generation) || (generation as number) < 1
      || (revision as number) < 1) return null;
    payload = { interactionId, generation: generation as number };
  }
  return {
    protocolVersion: 1,
    messageId,
    type: value.type as GameMessageType,
    ownerResource,
    ownerEpoch: ownerEpoch as number,
    revision: revision as number,
    payload,
  };
}

export function createBrowserBootId(): string {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return `ui_${Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}
