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
});

export const UI_ERROR_CODES = [
  'UI_NOT_READY',
  'UI_FOCUS_BUSY',
  'UI_FOCUS_DENIED',
  'UI_FOCUS_LEASE_INVALID',
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

export interface UiPreferences {
  schemaVersion: 1;
  quality: QualityProfile;
  scale: UiScale;
  density: Density;
  reducedMotion: boolean;
  reducedTransparency: boolean;
  highContrast: boolean;
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

export interface RuntimeSnapshot {
  browserBootId: string;
  ready: boolean;
  surfaces: RuntimeSurface[];
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
  'input:intent',
  'preferences:sync',
]);

const surfaceKinds = new Set<SurfaceKind>(['alert', 'confirm', 'input', 'form', 'select', 'menu', 'contextMenu']);
const surfaceTones = new Set<SurfaceTone>(['neutral', 'accent', 'info', 'success', 'warning', 'danger']);
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
  return {
    protocolVersion: 1,
    messageId,
    type: value.type as GameMessageType,
    ownerResource,
    ownerEpoch: ownerEpoch as number,
    revision: revision as number,
    payload: value.payload,
  };
}

export function createBrowserBootId(): string {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return `ui_${Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}
