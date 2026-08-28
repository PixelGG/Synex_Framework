import {
  type GameEnvelope,
  type InputDevice,
  type NavigationIntent,
  type RuntimeSnapshot,
  type RuntimeSurface,
  type ScreenMetrics,
  type UiPreferences,
  parseSurfaceDescriptor,
} from './protocol';

export const defaultPreferences: UiPreferences = {
  schemaVersion: 1,
  quality: 'BALANCED',
  scale: 100,
  density: 'comfortable',
  reducedMotion: false,
  reducedTransparency: false,
  highContrast: false,
};

export const defaultScreen: ScreenMetrics = {
  width: 1920,
  height: 1080,
  aspectRatio: 16 / 9,
  safeLeft: 0,
  safeRight: 0,
  safeTop: 0,
  safeBottom: 0,
};

export type RuntimeAction =
  | { type: 'message'; envelope: GameEnvelope }
  | { type: 'input-device'; device: InputDevice }
  | { type: 'intent'; intent: NavigationIntent }
  | { type: 'browser-ready'; browserBootId: string }
  | { type: 'browser-error' };

function parsePreferences(value: unknown, fallback: UiPreferences): UiPreferences {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return fallback;
  const candidate = value as Partial<UiPreferences>;
  return {
    schemaVersion: 1,
    quality: ['LOW', 'BALANCED', 'HIGH', 'ULTRA'].includes(candidate.quality ?? '')
      ? candidate.quality as UiPreferences['quality'] : fallback.quality,
    scale: [85, 100, 115, 125].includes(candidate.scale ?? 0)
      ? candidate.scale as UiPreferences['scale'] : fallback.scale,
    density: candidate.density === 'compact' || candidate.density === 'comfortable'
      ? candidate.density : fallback.density,
    reducedMotion: candidate.reducedMotion === true,
    reducedTransparency: candidate.reducedTransparency === true,
    highContrast: candidate.highContrast === true,
  };
}

function parseScreen(value: unknown, fallback: ScreenMetrics): ScreenMetrics {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return fallback;
  const candidate = value as Partial<ScreenMetrics>;
  const finite = (input: unknown, defaultValue: number, min: number, max: number) =>
    typeof input === 'number' && Number.isFinite(input) && input >= min && input <= max ? input : defaultValue;
  const width = finite(candidate.width, fallback.width, 320, 16_384);
  const height = finite(candidate.height, fallback.height, 240, 8_192);
  return {
    width,
    height,
    aspectRatio: finite(candidate.aspectRatio, width / height, 1, 8),
    safeLeft: finite(candidate.safeLeft, fallback.safeLeft, 0, width / 4),
    safeRight: finite(candidate.safeRight, fallback.safeRight, 0, width / 4),
    safeTop: finite(candidate.safeTop, fallback.safeTop, 0, height / 4),
    safeBottom: finite(candidate.safeBottom, fallback.safeBottom, 0, height / 4),
  };
}

function parseHealth(value: unknown, fallback: RuntimeSnapshot['health']): RuntimeSnapshot['health'] {
  return value === 'READY' || value === 'DEGRADED' || value === 'UNHEALTHY' ? value : fallback;
}

export function createInitialRuntimeState(browserBootId: string): RuntimeSnapshot {
  return {
    browserBootId,
    ready: false,
    surfaces: [],
    preferences: defaultPreferences,
    screen: defaultScreen,
    inputDevice: 'keyboard',
    health: 'DEGRADED',
  };
}

function surfaceFromEnvelope(envelope: GameEnvelope): RuntimeSurface | null {
  if ((envelope.payload.ownerResource !== undefined && envelope.payload.ownerResource !== envelope.ownerResource)
    || (envelope.payload.ownerEpoch !== undefined && envelope.payload.ownerEpoch !== envelope.ownerEpoch)
    || (envelope.payload.revision !== undefined && envelope.payload.revision !== envelope.revision)) return null;
  const descriptor = parseSurfaceDescriptor(envelope.payload);
  return descriptor ? {
    ...descriptor,
    ownerResource: envelope.ownerResource,
    ownerEpoch: envelope.ownerEpoch,
    revision: envelope.revision,
  } : null;
}

export function runtimeReducer(state: RuntimeSnapshot, action: RuntimeAction): RuntimeSnapshot {
  if (action.type === 'browser-ready') {
    return {
      ...state,
      ready: true,
      browserBootId: action.browserBootId,
      health: state.ready || state.health === 'UNHEALTHY' ? state.health : 'READY',
    };
  }
  if (action.type === 'browser-error') return { ...state, health: 'DEGRADED' };
  if (action.type === 'input-device') return state.inputDevice === action.device ? state : { ...state, inputDevice: action.device };
  if (action.type === 'intent') return state;

  const envelope = action.envelope;
  if (envelope.type === 'runtime:shutdown') return { ...state, ready: false, surfaces: [], health: 'UNHEALTHY' };
  if (envelope.type === 'runtime:sync') {
    const rawSurfaces = Array.isArray(envelope.payload.surfaces) ? envelope.payload.surfaces : null;
    const surfaces = rawSurfaces === null ? state.surfaces : rawSurfaces.flatMap((item) => {
      if (item === null || typeof item !== 'object' || Array.isArray(item)) return [];
      const raw = item as Record<string, unknown>;
      const descriptor = parseSurfaceDescriptor(raw);
      const ownerResource = typeof raw.ownerResource === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$/.test(raw.ownerResource)
        ? raw.ownerResource : null;
      if (!descriptor || !ownerResource || !Number.isInteger(raw.ownerEpoch) || (raw.ownerEpoch as number) < 1
        || !Number.isInteger(raw.revision) || (raw.revision as number) < 0) return [];
      return [{ ...descriptor, ownerResource, ownerEpoch: raw.ownerEpoch as number, revision: raw.revision as number }];
    });
    return {
      ...state,
      ready: true,
      surfaces,
      preferences: parsePreferences(envelope.payload.preferences, state.preferences),
      screen: parseScreen(envelope.payload.screen, state.screen),
      inputDevice: envelope.payload.inputDevice === 'mouse' || envelope.payload.inputDevice === 'gamepad'
        || envelope.payload.inputDevice === 'keyboard' ? envelope.payload.inputDevice : state.inputDevice,
      health: parseHealth(envelope.payload.health, state.health),
    };
  }
  if (envelope.type === 'preferences:sync') {
    return { ...state, preferences: parsePreferences(envelope.payload, state.preferences) };
  }
  if (envelope.type === 'input:intent') return state;
  if (envelope.type === 'surface:close') {
    const surfaceId = typeof envelope.payload.surfaceId === 'string' ? envelope.payload.surfaceId : '';
    return { ...state, surfaces: state.surfaces.filter((surface) => !(
      surface.surfaceId === surfaceId && surface.ownerResource === envelope.ownerResource
      && surface.ownerEpoch === envelope.ownerEpoch && surface.revision <= envelope.revision
    )) };
  }
  const surface = surfaceFromEnvelope(envelope);
  if (!surface) return { ...state, health: 'DEGRADED' };
  const current = state.surfaces.find((entry) => entry.surfaceId === surface.surfaceId);
  if (current && (current.ownerResource !== surface.ownerResource || current.ownerEpoch !== surface.ownerEpoch)) {
    return { ...state, health: 'DEGRADED' };
  }
  if (envelope.type === 'surface:open' && current) {
    return current.revision === surface.revision ? state : { ...state, health: 'DEGRADED' };
  }
  if (envelope.type === 'surface:update' && (!current || surface.revision <= current.revision)) {
    return current && surface.revision === current.revision ? state : { ...state, health: 'DEGRADED' };
  }
  const surfaces = state.surfaces.filter((entry) => entry.surfaceId !== surface.surfaceId);
  surfaces.push(surface);
  return { ...state, surfaces, health: 'READY' };
}
