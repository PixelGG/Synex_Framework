import type { GameEnvelope, SignalDescriptor, SurfaceDescriptor } from '../../runtime/src/protocol';

export type MockScenario = 'success' | 'error' | 'timeout' | 'malformed' | 'restart';

export interface MockResult<T = unknown> {
  ok: boolean;
  data?: T;
  error?: { code: string };
}

type Listener = (envelope: GameEnvelope) => void;

export class DesignLabMockTransport {
  #listeners = new Set<Listener>();
  #ownerEpoch = 1;
  #revision = 0;
  #signalGeneration = 0;

  subscribe(listener: Listener): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  emit(type: GameEnvelope['type'], payload: Record<string, unknown>, revision?: number): void {
    this.#revision += 1;
    const envelope: GameEnvelope = {
      protocolVersion: 1,
      messageId: `mock_${this.#revision}`,
      type,
      ownerResource: 'synex_design_lab',
      ownerEpoch: this.#ownerEpoch,
      revision: revision ?? this.#revision,
      payload,
    };
    for (const listener of this.#listeners) listener(envelope);
  }

  open(descriptor: SurfaceDescriptor): void {
    this.emit('surface:open', descriptor as unknown as Record<string, unknown>);
  }

  signalSnapshot(descriptors: readonly SignalDescriptor[]): void {
    this.#signalGeneration += 1;
    this.emit('runtime:sync', {
      signals: descriptors.map((descriptor) => ({
        ...descriptor,
        ownerResource: 'synex_design_lab',
        ownerEpoch: this.#ownerEpoch,
      })),
      signalGeneration: this.#signalGeneration,
    }, 0);
  }

  upsertSignal(descriptor: SignalDescriptor): void {
    this.#signalGeneration += 1;
    this.emit('signal:upsert', {
      ...descriptor,
      generation: this.#signalGeneration,
    }, descriptor.revision);
  }

  removeSignal(signalId: string, revision: number): void {
    this.#signalGeneration += 1;
    this.emit('signal:remove', { signalId, generation: this.#signalGeneration }, revision);
  }

  restart(): void {
    this.emit('runtime:shutdown', { reason: 'mock_restart' });
    this.#ownerEpoch += 1;
    this.#revision = 0;
    this.#signalGeneration = 0;
    this.emit('runtime:sync', {
      surfaces: [],
      signals: [],
      signalGeneration: 0,
      inputDevice: 'keyboard',
      preferences: {
        schemaVersion: 1,
        quality: 'BALANCED',
        scale: 100,
        density: 'comfortable',
        reducedMotion: false,
        reducedTransparency: false,
        highContrast: false,
      },
    });
  }

  async request<T>(scenario: MockScenario, data: T): Promise<MockResult<T>> {
    if (scenario === 'success') return { ok: true, data };
    if (scenario === 'error') return { ok: false, error: { code: 'UI_FOCUS_BUSY' } };
    if (scenario === 'malformed') return { ok: false, error: { code: 'UI_REQUEST_INVALID' } };
    if (scenario === 'restart') {
      this.restart();
      return { ok: false, error: { code: 'UI_OWNER_STALE' } };
    }
    return new Promise((resolve) => {
      window.setTimeout(() => resolve({ ok: false, error: { code: 'UI_REQUEST_TIMEOUT' } }), 320);
    });
  }
}

export const designLabTransport = new DesignLabMockTransport();
