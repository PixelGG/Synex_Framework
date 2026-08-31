import {
  type GameEnvelope,
  type InputDevice,
  type NavigationIntent,
  type RuntimeSnapshot,
  type RuntimeInteraction,
  type RuntimeSignal,
  type RuntimeSurface,
  type ScreenMetrics,
  type UiPreferences,
  UI_LIMITS,
  isPlainRecord,
  parseInteractionDescriptor,
  parseSignalDescriptor,
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
  interactionAssist: false,
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
    interactionAssist: candidate.interactionAssist === true,
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
    signals: [],
    signalGeneration: 0,
    signalRevisions: {},
    interaction: null,
    interactionGeneration: 0,
    interactionRevisions: {},
    preferences: defaultPreferences,
    screen: defaultScreen,
    inputDevice: 'keyboard',
    health: 'DEGRADED',
  };
}

const safeIdPattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$/;

function signalIdentity(signal: Pick<RuntimeSignal, 'ownerResource' | 'ownerEpoch' | 'signalId'>): string {
  return `${signal.ownerResource}\u0000${signal.ownerEpoch}\u0000${signal.signalId}`;
}

function withSignalRevision(
  revisions: Readonly<Record<string, number>>,
  identity: string,
  revision: number,
  activeSignals: readonly RuntimeSignal[],
): Record<string, number> {
  const next = { ...revisions, [identity]: revision };
  const active = new Set(activeSignals.map(signalIdentity));
  for (const candidate of Object.keys(next)) {
    if (Object.keys(next).length <= UI_LIMITS.maxSignalRevisionFences) break;
    if (candidate !== identity && !active.has(candidate)) delete next[candidate];
  }
  return next;
}

function parseRuntimeSignal(value: unknown): RuntimeSignal | null {
  if (!isPlainRecord(value)) return null;
  const { ownerResource: rawOwnerResource, ownerEpoch: rawOwnerEpoch, ...rawDescriptor } = value;
  if (typeof rawOwnerResource !== 'string' || !safeIdPattern.test(rawOwnerResource)
    || !Number.isSafeInteger(rawOwnerEpoch) || (rawOwnerEpoch as number) < 1) return null;
  const descriptor = parseSignalDescriptor(rawDescriptor);
  return descriptor ? {
    ...descriptor,
    ownerResource: rawOwnerResource,
    ownerEpoch: rawOwnerEpoch as number,
  } : null;
}

function parseSignalSnapshot(value: unknown): RuntimeSignal[] | null {
  if (!Array.isArray(value) || value.length > UI_LIMITS.maxSignals) return null;
  const parsed = value.map(parseRuntimeSignal);
  if (parsed.some((signal) => signal === null)) return null;
  const signals = parsed as RuntimeSignal[];
  const identities = signals.map(signalIdentity);
  return new Set(identities).size === identities.length ? signals : null;
}

function signalFromEnvelope(envelope: GameEnvelope): { signal: RuntimeSignal; generation: number } | null {
  if (!isPlainRecord(envelope.payload)) return null;
  const { generation: rawGeneration, ...rawDescriptor } = envelope.payload;
  if (!Number.isSafeInteger(rawGeneration) || (rawGeneration as number) < 1) return null;
  const descriptor = parseSignalDescriptor(rawDescriptor);
  if (!descriptor || descriptor.revision !== envelope.revision) return null;
  return {
    signal: {
      ...descriptor,
      ownerResource: envelope.ownerResource,
      ownerEpoch: envelope.ownerEpoch,
    },
    generation: rawGeneration as number,
  };
}

function parseRuntimeInteraction(value: unknown): RuntimeInteraction | null {
  if (!isPlainRecord(value)) return null;
  const { ownerResource, ownerEpoch, ...rawDescriptor } = value;
  if (ownerResource !== 'synex_interact' || !Number.isSafeInteger(ownerEpoch) || (ownerEpoch as number) < 1) {
    return null;
  }
  const descriptor = parseInteractionDescriptor(rawDescriptor);
  return descriptor ? {
    ...descriptor,
    ownerResource,
    ownerEpoch: ownerEpoch as number,
  } : null;
}

function interactionFromEnvelope(envelope: GameEnvelope): { interaction: RuntimeInteraction; generation: number } | null {
  if (envelope.ownerResource !== 'synex_interact') return null;
  const { generation, ...rawDescriptor } = envelope.payload;
  if (!Number.isSafeInteger(generation) || (generation as number) < 1) return null;
  const descriptor = parseInteractionDescriptor(rawDescriptor);
  if (!descriptor || descriptor.revision !== envelope.revision) return null;
  return {
    interaction: {
      ...descriptor,
      ownerResource: envelope.ownerResource,
      ownerEpoch: envelope.ownerEpoch,
    },
    generation: generation as number,
  };
}

function interactionIdentity(
  value: Pick<RuntimeInteraction, 'ownerResource' | 'ownerEpoch' | 'interactionId'>,
): string {
  return `${value.ownerResource}\u0000${value.ownerEpoch}\u0000${value.interactionId}`;
}

function withInteractionRevision(
  revisions: Readonly<Record<string, number>>,
  identity: string,
  revision: number,
  active: RuntimeInteraction | null,
): Record<string, number> {
  const next = { ...revisions, [identity]: revision };
  const activeIdentity = active ? interactionIdentity(active) : null;
  for (const candidate of Object.keys(next)) {
    if (Object.keys(next).length <= UI_LIMITS.maxInteractionRevisionFences) break;
    if (candidate !== identity && candidate !== activeIdentity) delete next[candidate];
  }
  return next;
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
  if (envelope.type === 'runtime:shutdown') return {
    ...state,
    ready: false,
    surfaces: [],
    signals: [],
    signalGeneration: 0,
    signalRevisions: {},
    interaction: null,
    interactionGeneration: 0,
    interactionRevisions: {},
    health: 'UNHEALTHY',
  };
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
    const carriesSignals = envelope.payload.signals !== undefined || envelope.payload.signalGeneration !== undefined;
    let signals = state.signals;
    let signalGeneration = state.signalGeneration;
    let signalRevisions = state.signalRevisions;
    if (carriesSignals) {
      const parsedSignals = parseSignalSnapshot(envelope.payload.signals);
      const nextGeneration = envelope.payload.signalGeneration;
      if (!parsedSignals || !Number.isSafeInteger(nextGeneration) || (nextGeneration as number) < signalGeneration) {
        return { ...state, health: 'DEGRADED' };
      }
      signals = parsedSignals;
      signalGeneration = nextGeneration as number;
      signalRevisions = {};
      for (const signal of signals) {
        signalRevisions = withSignalRevision(
          signalRevisions,
          signalIdentity(signal),
          signal.revision,
          signals,
        );
      }
    }
    const carriesInteraction = envelope.payload.interaction !== undefined
      || envelope.payload.interactionGeneration !== undefined;
    let interaction = state.interaction;
    let interactionGeneration = state.interactionGeneration;
    let interactionRevisions = state.interactionRevisions;
    if (carriesInteraction) {
      const nextGeneration = envelope.payload.interactionGeneration;
      if (!Number.isSafeInteger(nextGeneration) || (nextGeneration as number) < interactionGeneration
        || (envelope.payload.interaction !== null
          && parseRuntimeInteraction(envelope.payload.interaction) === null)) {
        return { ...state, health: 'DEGRADED' };
      }
      interaction = envelope.payload.interaction === null
        ? null
        : parseRuntimeInteraction(envelope.payload.interaction);
      interactionGeneration = nextGeneration as number;
      if (interaction) {
        interactionRevisions = withInteractionRevision(
          interactionRevisions,
          interactionIdentity(interaction),
          interaction.revision,
          interaction,
        );
      }
    }
    return {
      ...state,
      ready: true,
      surfaces,
      signals,
      signalGeneration,
      signalRevisions,
      interaction,
      interactionGeneration,
      interactionRevisions,
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
  if (envelope.type === 'signal:sound') return state;
  if (envelope.type === 'interaction:remove') {
    const interactionId = envelope.payload.interactionId;
    const generation = envelope.payload.generation;
    if (envelope.ownerResource !== 'synex_interact' || typeof interactionId !== 'string'
      || !safeIdPattern.test(interactionId) || !Number.isSafeInteger(generation)) {
      return { ...state, health: 'DEGRADED' };
    }
    if ((generation as number) <= state.interactionGeneration) {
      return generation === state.interactionGeneration ? state : { ...state, health: 'DEGRADED' };
    }
    const removesCurrent = state.interaction?.interactionId === interactionId
      && state.interaction.ownerResource === envelope.ownerResource
      && state.interaction.ownerEpoch === envelope.ownerEpoch
      && state.interaction.revision < envelope.revision;
    const identity = `${envelope.ownerResource}\u0000${envelope.ownerEpoch}\u0000${interactionId}`;
    if (envelope.revision <= (state.interactionRevisions[identity] ?? 0)) {
      return { ...state, health: 'DEGRADED' };
    }
    const nextInteraction = removesCurrent ? null : state.interaction;
    return {
      ...state,
      interaction: nextInteraction,
      interactionGeneration: generation as number,
      interactionRevisions: withInteractionRevision(
        state.interactionRevisions,
        identity,
        envelope.revision,
        nextInteraction,
      ),
      health: 'READY',
    };
  }
  if (envelope.type === 'interaction:upsert') {
    const parsed = interactionFromEnvelope(envelope);
    if (!parsed || parsed.generation <= state.interactionGeneration) {
      return parsed?.generation === state.interactionGeneration ? state : { ...state, health: 'DEGRADED' };
    }
    const identity = interactionIdentity(parsed.interaction);
    if (parsed.interaction.revision <= (state.interactionRevisions[identity] ?? 0)) {
      return { ...state, health: 'DEGRADED' };
    }
    if (state.interaction?.interactionId === parsed.interaction.interactionId
      && state.interaction.ownerEpoch === parsed.interaction.ownerEpoch
      && parsed.interaction.revision <= state.interaction.revision) {
      return { ...state, health: 'DEGRADED' };
    }
    return {
      ...state,
      interaction: parsed.interaction,
      interactionGeneration: parsed.generation,
      interactionRevisions: withInteractionRevision(
        state.interactionRevisions,
        identity,
        parsed.interaction.revision,
        parsed.interaction,
      ),
      health: 'READY',
    };
  }
  if (envelope.type === 'signal:remove') {
    if (Object.keys(envelope.payload).some((key) => !['signalId', 'generation'].includes(key))) {
      return { ...state, health: 'DEGRADED' };
    }
    const signalId = typeof envelope.payload.signalId === 'string' && safeIdPattern.test(envelope.payload.signalId)
      ? envelope.payload.signalId : null;
    const generation = envelope.payload.generation;
    if (!signalId || !Number.isSafeInteger(generation)) return { ...state, health: 'DEGRADED' };
    if ((generation as number) <= state.signalGeneration) {
      return generation === state.signalGeneration ? state : { ...state, health: 'DEGRADED' };
    }
    const identity = `${envelope.ownerResource}\u0000${envelope.ownerEpoch}\u0000${signalId}`;
    if (envelope.revision <= (state.signalRevisions[identity] ?? 0)) return { ...state, health: 'DEGRADED' };
    const nextSignals = state.signals.filter((signal) => !(signal.signalId === signalId
      && signal.ownerResource === envelope.ownerResource && signal.ownerEpoch === envelope.ownerEpoch));
    return {
      ...state,
      signals: nextSignals,
      signalGeneration: generation as number,
      signalRevisions: withSignalRevision(state.signalRevisions, identity, envelope.revision, nextSignals),
      health: 'READY',
    };
  }
  if (envelope.type === 'signal:upsert') {
    const parsed = signalFromEnvelope(envelope);
    if (!parsed || parsed.generation <= state.signalGeneration) {
      return parsed?.generation === state.signalGeneration ? state : { ...state, health: 'DEGRADED' };
    }
    const identity = signalIdentity(parsed.signal);
    const current = state.signals.find((signal) => signalIdentity(signal) === identity);
    if (parsed.signal.revision <= (state.signalRevisions[identity] ?? 0)) return { ...state, health: 'DEGRADED' };
    if (!current && state.signals.length >= UI_LIMITS.maxSignals) return { ...state, health: 'DEGRADED' };
    const nextSignals = [...state.signals.filter((signal) => signalIdentity(signal) !== identity), parsed.signal];
    return {
      ...state,
      signals: nextSignals,
      signalGeneration: parsed.generation,
      signalRevisions: withSignalRevision(state.signalRevisions, identity, parsed.signal.revision, nextSignals),
      health: 'READY',
    };
  }
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
