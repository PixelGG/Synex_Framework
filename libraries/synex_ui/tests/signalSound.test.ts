import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  closeSignalSound,
  createSignalSoundIngressFence,
  playSignalSound,
} from '../runtime/src/signalSound';
import type { SignalSoundTone } from '../runtime/src/protocol';

interface AudioFixture {
  context: AudioContext;
  createGain: ReturnType<typeof vi.fn>;
  createOscillator: ReturnType<typeof vi.fn>;
  gains: Array<{ gain: { exponentialRampToValueAtTime: ReturnType<typeof vi.fn> } }>;
  oscillators: Array<{
    type: OscillatorType;
    frequency: { setValueAtTime: ReturnType<typeof vi.fn>; exponentialRampToValueAtTime: ReturnType<typeof vi.fn> };
    ended?: () => void;
    disconnect: ReturnType<typeof vi.fn>;
    start: ReturnType<typeof vi.fn>;
    stop: ReturnType<typeof vi.fn>;
  }>;
}

let originalAudioContext: typeof AudioContext | undefined;

function installAudioContext(state: AudioContextState = 'running', resume = vi.fn(async () => undefined)): AudioFixture {
  const gains: AudioFixture['gains'] = [];
  const oscillators: AudioFixture['oscillators'] = [];
  const createGain = vi.fn(() => {
    const node = {
      gain: {
        setValueAtTime: vi.fn(),
        exponentialRampToValueAtTime: vi.fn(),
      },
      connect: vi.fn(),
      disconnect: vi.fn(),
    };
    gains.push(node);
    return node;
  });
  const createOscillator = vi.fn(() => {
    const node = {
      type: 'sine' as OscillatorType,
      frequency: {
        setValueAtTime: vi.fn(),
        exponentialRampToValueAtTime: vi.fn(),
      },
      connect: vi.fn(),
      disconnect: vi.fn(),
      ended: undefined as (() => void) | undefined,
      addEventListener: vi.fn((_type: string, listener: () => void) => { node.ended = listener; }),
      start: vi.fn(),
      stop: vi.fn(),
    };
    oscillators.push(node);
    return node;
  });
  const context = {
    state,
    currentTime: 10,
    destination: {},
    createGain,
    createOscillator,
    resume,
    close: vi.fn(async () => undefined),
  } as unknown as AudioContext;
  const Constructor = vi.fn(function AudioContextFixture() { return context; });
  Object.defineProperty(window, 'AudioContext', { configurable: true, value: Constructor });
  return { context, createGain, createOscillator, gains, oscillators };
}

afterEach(async () => {
  await closeSignalSound();
  if (originalAudioContext) {
    Object.defineProperty(window, 'AudioContext', { configurable: true, value: originalAudioContext });
  } else {
    Reflect.deleteProperty(window, 'AudioContext');
  }
});

describe('one-shot notification sound', () => {
  it('uses distinct bounded oscillator profiles without timers or network work', async () => {
    originalAudioContext = window.AudioContext;
    const fixture = installAudioContext();
    const tones: SignalSoundTone[] = ['neutral', 'info', 'success', 'warning', 'danger', 'critical'];
    for (const tone of tones) {
      expect(await playSignalSound({ tone, volume: 50 })).toBe(true);
      fixture.oscillators.at(-1)?.ended?.();
    }

    const durations = fixture.oscillators.map((oscillator) => (
      Number(oscillator.stop.mock.calls[0]?.[0]) - 10
    ));
    expect(durations.every((duration) => duration >= 0.08 && duration <= 0.18)).toBe(true);
    expect(new Set(durations).size).toBe(tones.length);
    expect(new Set(fixture.oscillators.map((oscillator) => (
      oscillator.frequency.exponentialRampToValueAtTime.mock.calls[0]?.[0]
    ))).size).toBeGreaterThan(3);
  });

  it('maps larger configured volume to a strictly larger GainNode peak', async () => {
    originalAudioContext = window.AudioContext;
    const fixture = installAudioContext();
    expect(await playSignalSound({ tone: 'info', volume: 20 })).toBe(true);
    expect(await playSignalSound({ tone: 'info', volume: 80 })).toBe(true);
    const peaks = fixture.gains.map((gain) => (
      Number(gain.gain.exponentialRampToValueAtTime.mock.calls[0]?.[0])
    ));
    expect(peaks[0]).toBeGreaterThan(0);
    expect(peaks[1]).toBeGreaterThan(peaks[0] as number);
  });

  it('fails cleanly when audio is unavailable or resume is denied', async () => {
    originalAudioContext = window.AudioContext;
    Reflect.deleteProperty(window, 'AudioContext');
    expect(await playSignalSound({ tone: 'warning', volume: 50 })).toBe(false);

    const fixture = installAudioContext('suspended', vi.fn(async () => Promise.reject(new Error('blocked'))));
    expect(await playSignalSound({ tone: 'warning', volume: 50 })).toBe(false);
    expect(fixture.createOscillator).not.toHaveBeenCalled();
    expect(fixture.createGain).not.toHaveBeenCalled();
  });

  it('bounds concurrent voices and releases capacity when a one-shot ends', async () => {
    originalAudioContext = window.AudioContext;
    const fixture = installAudioContext();
    for (let index = 0; index < 4; index += 1) {
      expect(await playSignalSound({ tone: 'neutral', volume: 50 })).toBe(true);
    }
    expect(await playSignalSound({ tone: 'neutral', volume: 50 })).toBe(false);
    fixture.oscillators[0]?.ended?.();
    expect(await playSignalSound({ tone: 'neutral', volume: 50 })).toBe(true);
  });

  it('fences a delayed resume across cleanup and a replacement audio context', async () => {
    originalAudioContext = window.AudioContext;
    let resolveResume: (() => void) | undefined;
    const resume = new Promise<void>((resolve) => { resolveResume = resolve; });
    const oldCreateOscillator = vi.fn();
    const oldContext = {
      state: 'suspended' as AudioContextState,
      currentTime: 1,
      destination: {},
      resume: vi.fn(() => resume),
      close: vi.fn(async () => undefined),
      createOscillator: oldCreateOscillator,
      createGain: vi.fn(),
    } as unknown as AudioContext;

    const freshOscillator = {
      type: 'sine' as OscillatorType,
      frequency: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() },
      connect: vi.fn(),
      disconnect: vi.fn(),
      addEventListener: vi.fn(),
      start: vi.fn(),
      stop: vi.fn(),
    };
    const freshGain = {
      gain: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() },
      connect: vi.fn(),
      disconnect: vi.fn(),
    };
    const freshContext = {
      state: 'running' as AudioContextState,
      currentTime: 2,
      destination: {},
      resume: vi.fn(async () => undefined),
      close: vi.fn(async () => undefined),
      createOscillator: vi.fn(() => freshOscillator),
      createGain: vi.fn(() => freshGain),
    } as unknown as AudioContext;
    const contexts = [oldContext, freshContext];
    const Constructor = vi.fn(function AudioContextFixture() { return contexts.shift(); });
    Object.defineProperty(window, 'AudioContext', { configurable: true, value: Constructor });

    const stale = playSignalSound({ tone: 'info', volume: 50 });
    await Promise.resolve();
    expect(oldContext.resume).toHaveBeenCalledTimes(1);
    await closeSignalSound();
    expect(await playSignalSound({ tone: 'success', volume: 50 })).toBe(true);
    (oldContext as AudioContext & { state: AudioContextState }).state = 'running';
    resolveResume?.();
    expect(await stale).toBe(false);
    expect(oldCreateOscillator).not.toHaveBeenCalled();
    expect(freshContext.createOscillator).toHaveBeenCalledTimes(1);
  });

  it('rejects wrong boots, duplicates, stale epochs, cooldown bursts, and window overflow', () => {
    let now = 0;
    const fence = createSignalSoundIngressFence('ui_boot_expected', () => now);
    const metadata = (messageId: string, ownerEpoch = 3, browserBootId = 'ui_boot_expected') => ({
      messageId, ownerEpoch, browserBootId,
    });

    expect(fence.accept(metadata('sound_01')).accepted).toBe(true);
    expect(fence.accept(metadata('sound_epoch_burst_04', 4))).toEqual({
      accepted: false,
      epochAdvanced: true,
    });
    expect(fence.accept(metadata('sound_epoch_burst_05', 5))).toEqual({
      accepted: false,
      epochAdvanced: true,
    });
    now += 50;
    expect(fence.accept(metadata('sound_01')).accepted).toBe(false);
    expect(fence.accept(metadata('sound_wrong_boot', 3, 'ui_boot_wrong')).accepted).toBe(false);

    for (let index = 2; index <= 8; index += 1) {
      expect(fence.accept(metadata(`sound_0${index}`, 5)).accepted).toBe(true);
      now += 50;
    }
    expect(fence.accept(metadata('sound_09', 5)).accepted).toBe(false);

    now = 1_000;
    const advanced = fence.accept(metadata('sound_epoch_06', 6));
    expect(advanced).toEqual({ accepted: true, epochAdvanced: true });
    now += 50;
    expect(fence.accept(metadata('sound_stale_epoch', 5)).accepted).toBe(false);

    fence.reset();
    expect(fence.accept(metadata('sound_after_reset', 1)).accepted).toBe(true);
  });
});
