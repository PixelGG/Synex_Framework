import type { SignalSoundPayload, SignalSoundTone } from './protocol';

interface SoundProfile {
  wave: OscillatorType;
  startHz: number;
  endHz: number;
  durationMs: number;
  peakGain: number;
}

const profiles: Readonly<Record<SignalSoundTone, SoundProfile>> = Object.freeze({
  neutral: { wave: 'sine', startHz: 392, endHz: 392, durationMs: 85, peakGain: 0.035 },
  info: { wave: 'sine', startHz: 440, endHz: 523, durationMs: 100, peakGain: 0.038 },
  success: { wave: 'sine', startHz: 523, endHz: 659, durationMs: 125, peakGain: 0.042 },
  warning: { wave: 'triangle', startHz: 587, endHz: 440, durationMs: 135, peakGain: 0.04 },
  danger: { wave: 'triangle', startHz: 330, endHz: 220, durationMs: 150, peakGain: 0.045 },
  critical: { wave: 'sine', startHz: 220, endHz: 165, durationMs: 175, peakGain: 0.05 },
});

type AudioContextWithWebkit = typeof window & {
  webkitAudioContext?: typeof AudioContext;
};

let context: AudioContext | null = null;
let audioGeneration = 0;
const activeVoices = new Set<{ oscillator: OscillatorNode; gain: GainNode }>();

const ingressLimits = Object.freeze({
  maximumRememberedMessages: 64,
  maximumSoundsPerWindow: 8,
  windowMs: 1_000,
  cooldownMs: 50,
  maximumActiveVoices: 4,
});

export interface SignalSoundIngressMetadata {
  browserBootId: string;
  messageId: string;
  ownerEpoch: number;
}

export interface SignalSoundIngressDecision {
  accepted: boolean;
  epochAdvanced: boolean;
}

export interface SignalSoundIngressFence {
  accept(metadata: SignalSoundIngressMetadata): SignalSoundIngressDecision;
  reset(): void;
}

export function createSignalSoundIngressFence(
  expectedBrowserBootId: string,
  now: () => number = () => performance.now(),
): SignalSoundIngressFence {
  let ownerEpoch = 0;
  let windowStartedAt = Number.NEGATIVE_INFINITY;
  let count = 0;
  let lastAt = Number.NEGATIVE_INFINITY;
  const seen = new Set<string>();
  const seenOrder: string[] = [];

  const resetPressure = () => {
    windowStartedAt = Number.NEGATIVE_INFINITY;
    count = 0;
    lastAt = Number.NEGATIVE_INFINITY;
    seen.clear();
    seenOrder.length = 0;
  };

  return {
    accept(metadata) {
      if (metadata.browserBootId !== expectedBrowserBootId
        || !Number.isSafeInteger(metadata.ownerEpoch) || metadata.ownerEpoch < 1
        || seen.has(metadata.messageId)) return { accepted: false, epochAdvanced: false };

      if (ownerEpoch > 0 && metadata.ownerEpoch < ownerEpoch) {
        return { accepted: false, epochAdvanced: false };
      }

      const epochAdvanced = ownerEpoch > 0 && metadata.ownerEpoch > ownerEpoch;
      if (ownerEpoch === 0 || metadata.ownerEpoch > ownerEpoch) {
        ownerEpoch = metadata.ownerEpoch;
      }

      seen.add(metadata.messageId);
      seenOrder.push(metadata.messageId);
      if (seenOrder.length > ingressLimits.maximumRememberedMessages) {
        const expired = seenOrder.shift();
        if (expired) seen.delete(expired);
      }

      const current = now();
      if (!Number.isFinite(current)) return { accepted: false, epochAdvanced };
      if (!Number.isFinite(windowStartedAt) || current < windowStartedAt
        || current - windowStartedAt >= ingressLimits.windowMs) {
        windowStartedAt = current;
        count = 0;
      }
      if (current - lastAt < ingressLimits.cooldownMs
        || count >= ingressLimits.maximumSoundsPerWindow) {
        return { accepted: false, epochAdvanced };
      }
      lastAt = current;
      count += 1;
      return { accepted: true, epochAdvanced };
    },
    reset() {
      ownerEpoch = 0;
      resetPressure();
    },
  };
}

function audioContextConstructor(): typeof AudioContext | undefined {
  const scope = window as AudioContextWithWebkit;
  return scope.AudioContext ?? scope.webkitAudioContext;
}

export async function playSignalSound(payload: SignalSoundPayload): Promise<boolean> {
  const AudioContextConstructor = audioContextConstructor();
  if (!AudioContextConstructor || activeVoices.size >= ingressLimits.maximumActiveVoices) return false;

  let oscillator: OscillatorNode | undefined;
  let gain: GainNode | undefined;
  let voice: { oscillator: OscillatorNode; gain: GainNode } | undefined;
  try {
    if (!context || context.state === 'closed') {
      audioGeneration += 1;
      activeVoices.clear();
      context = new AudioContextConstructor();
    }
    const activeContext = context;
    const generation = audioGeneration;
    if (activeContext.state === 'suspended') await activeContext.resume();
    if (generation !== audioGeneration || context !== activeContext
      || activeContext.state !== 'running'
      || activeVoices.size >= ingressLimits.maximumActiveVoices) return false;

    const profile = profiles[payload.tone];
    const startedAt = activeContext.currentTime;
    const attackEndsAt = startedAt + 0.008;
    const endsAt = startedAt + (profile.durationMs / 1_000);
    const normalizedVolume = payload.volume / 100;
    const peakGain = profile.peakGain * Math.pow(normalizedVolume, 1.6);

    oscillator = activeContext.createOscillator();
    gain = activeContext.createGain();
    voice = { oscillator, gain };
    activeVoices.add(voice);
    oscillator.type = profile.wave;
    oscillator.frequency.setValueAtTime(profile.startHz, startedAt);
    oscillator.frequency.exponentialRampToValueAtTime(profile.endHz, endsAt);
    gain.gain.setValueAtTime(0.000001, startedAt);
    gain.gain.exponentialRampToValueAtTime(peakGain, attackEndsAt);
    gain.gain.exponentialRampToValueAtTime(0.000001, endsAt);
    oscillator.connect(gain);
    gain.connect(activeContext.destination);
    oscillator.addEventListener('ended', () => {
      if (voice) activeVoices.delete(voice);
      oscillator?.disconnect();
      gain?.disconnect();
    }, { once: true });
    oscillator.start(startedAt);
    oscillator.stop(endsAt);
    return true;
  } catch {
    if (voice) activeVoices.delete(voice);
    oscillator?.disconnect();
    gain?.disconnect();
    return false;
  }
}

export async function closeSignalSound(): Promise<void> {
  audioGeneration += 1;
  const active = context;
  context = null;
  for (const voice of activeVoices) {
    try { voice.oscillator.stop(); } catch { /* The one-shot may already have ended. */ }
    try { voice.oscillator.disconnect(); } catch { /* Cleanup is best-effort during shutdown. */ }
    try { voice.gain.disconnect(); } catch { /* Cleanup is best-effort during shutdown. */ }
  }
  activeVoices.clear();
  if (!active || active.state === 'closed') return;
  try {
    await active.close();
  } catch {
    // The runtime is already shutting down; audio cleanup must stay best-effort.
  }
}
