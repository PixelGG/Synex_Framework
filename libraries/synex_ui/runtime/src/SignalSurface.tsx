import { Icon, KeyHint, Surface, type SynexIconName } from '@synex/ui';
import {
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from 'react';
import './signal-surface.css';
import {
  UI_LIMITS,
  type Density,
  type InputDevice,
  type RuntimeSignal,
  type ScreenMetrics,
  type SignalPosition,
  type SignalProgressState,
  type SignalTone,
  type UiScale,
} from './protocol';
import { SignalAnnouncer } from './signalAnnouncements';

export const SIGNAL_EXIT_MS = 140;

const priorityWeight = {
  low: 0,
  normal: 1,
  high: 2,
  critical: 3,
} as const;

const positionOrder: readonly SignalPosition[] = [
  'top-right',
  'top-center',
  'top-left',
  'bottom-right',
  'bottom-center',
  'bottom-left',
];

const iconByTone: Record<SignalTone, SynexIconName> = {
  neutral: 'signal',
  info: 'info',
  success: 'success',
  warning: 'warning',
  danger: 'error',
};

const iconByProgressState: Partial<Record<SignalProgressState, SynexIconName>> = {
  SUCCESS: 'success',
  FAILED: 'error',
  CANCELLED: 'close',
};

const defaultActionHints = {
  keyboard: ['F9', 'F10'],
  mouse: ['F9', 'F10'],
  gamepad: ['D-pad Left', 'D-pad Right'],
} as const satisfies Record<InputDevice, readonly [string, string]>;

const progressStateLabel: Record<SignalProgressState, string> = {
  PENDING: 'Pending',
  RUNNING: 'Running',
  SUCCESS: 'Complete',
  FAILED: 'Failed',
  CANCELLED: 'Cancelled',
};

interface PresentedSignal {
  signal: RuntimeSignal;
  phase: 'active' | 'dismissing';
}

function signalIdentity(signal: RuntimeSignal): string {
  return `${signal.ownerResource}\u0000${signal.ownerEpoch}\u0000${signal.signalId}`;
}

function signalIcon(signal: RuntimeSignal): SynexIconName {
  return (signal.progress ? iconByProgressState[signal.progress.state] : undefined)
    ?? signal.iconKey
    ?? iconByTone[signal.tone];
}

function progressPercentage(signal: RuntimeSignal): number | null {
  const progress = signal.progress;
  if (!progress || progress.mode !== 'determinate' || progress.value === undefined || progress.maximum === undefined) {
    return null;
  }
  return Math.round((progress.value / progress.maximum) * 100);
}

function progressValueText(signal: RuntimeSignal, percentage: number | null): string | undefined {
  if (!signal.progress) return undefined;
  const state = progressStateLabel[signal.progress.state];
  return percentage === null ? state : `${state}, ${percentage}%`;
}

function progressDisplayText(signal: RuntimeSignal, percentage: number | null): string | undefined {
  if (!signal.progress) return undefined;
  const state = progressStateLabel[signal.progress.state];
  return percentage === null ? state : `${state} \u00b7 ${percentage}%`;
}

function environmentPrefersReducedMotion(): boolean {
  if (typeof document !== 'undefined' && document.documentElement.dataset.sxReducedMotion === 'true') return true;
  return typeof window !== 'undefined' && typeof window.matchMedia === 'function'
    && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

const signalStackLayout = Object.freeze({
  comfortableHeightPx: 152,
  compactHeightPx: 128,
  narrowHeightBonusPx: 28,
  narrowWidthPx: 360,
  edgeInsetPx: 20,
});

const defaultSignalScreen: ScreenMetrics = Object.freeze({
  width: 1920,
  height: 1080,
  aspectRatio: 16 / 9,
  safeLeft: 0,
  safeRight: 0,
  safeTop: 0,
  safeBottom: 0,
});

export function resolveVisibleSignalCapacity(
  screen: ScreenMetrics,
  scale: UiScale,
  density: Density,
): number {
  const scaleFactor = scale / 100;
  const horizontalSpace = Math.max(0, screen.width - screen.safeLeft - screen.safeRight);
  const narrowBonus = horizontalSpace < signalStackLayout.narrowWidthPx * scaleFactor
    ? signalStackLayout.narrowHeightBonusPx
    : 0;
  const surfaceHeight = (
    density === 'compact'
      ? signalStackLayout.compactHeightPx
      : signalStackLayout.comfortableHeightPx
  ) + narrowBonus;
  const topInset = Math.max(screen.safeTop, signalStackLayout.edgeInsetPx * scaleFactor);
  const bottomInset = Math.max(screen.safeBottom, signalStackLayout.edgeInsetPx * scaleFactor);
  const availableHeight = Math.max(0, screen.height - topInset - bottomInset);
  const capacity = Math.floor(availableHeight / (surfaceHeight * scaleFactor));
  return Math.max(1, Math.min(UI_LIMITS.maxVisibleSignals, capacity));
}

function reconcilePresented(
  current: readonly PresentedSignal[],
  next: readonly RuntimeSignal[],
  reducedMotion: boolean,
  capacity: number,
): PresentedSignal[] {
  if (reducedMotion) return next.map((signal) => ({ signal, phase: 'active' }));
  const nextByIdentity = new Map(next.map((signal) => [signalIdentity(signal), signal]));
  const exiting = current.flatMap((entry) => nextByIdentity.has(signalIdentity(entry.signal)) ? [] : [{
    signal: entry.signal,
    phase: 'dismissing' as const,
  }]);
  const exitSlots = current.length > capacity ? 0 : Math.min(exiting.length, capacity);
  const retainedExiting = exiting.slice(0, exitSlots);
  const active = next.slice(0, Math.max(0, capacity - retainedExiting.length))
    .map((signal) => ({ signal, phase: 'active' as const }));
  if (retainedExiting.length === 0) return active;

  const activeByIdentity = new Map(active.map((entry) => [signalIdentity(entry.signal), entry]));
  const exitingByIdentity = new Map(retainedExiting.map((entry) => [signalIdentity(entry.signal), entry]));
  const ordered: PresentedSignal[] = [];
  for (const entry of current) {
    const identity = signalIdentity(entry.signal);
    const replacement = activeByIdentity.get(identity) ?? exitingByIdentity.get(identity);
    if (!replacement) continue;
    ordered.push(replacement);
    activeByIdentity.delete(identity);
    exitingByIdentity.delete(identity);
  }
  ordered.push(...activeByIdentity.values(), ...exitingByIdentity.values());
  return ordered.slice(0, capacity);
}

export function selectVisibleSignals(
  signals: readonly RuntimeSignal[],
  capacity: number = UI_LIMITS.maxVisibleSignals,
): RuntimeSignal[] {
  const boundedCapacity = Math.max(1, Math.min(
    UI_LIMITS.maxVisibleSignals,
    Number.isFinite(capacity) ? Math.floor(capacity) : UI_LIMITS.maxVisibleSignals,
  ));
  return [...signals].sort((left, right) => {
    const priority = priorityWeight[right.priority] - priorityWeight[left.priority];
    if (priority !== 0) return priority;
    if (right.createdAt !== left.createdAt) return right.createdAt - left.createdAt;
    if (right.revision !== left.revision) return right.revision - left.revision;
    return left.signalId.localeCompare(right.signalId);
  }).slice(0, boundedCapacity);
}

export function SignalSurface({
  signal,
  phase = 'active',
  inputDevice = 'keyboard',
}: {
  signal: RuntimeSignal;
  phase?: PresentedSignal['phase'];
  inputDevice?: InputDevice;
}) {
  const titleId = useId();
  const messageId = useId();
  const surfaceRef = useRef<HTMLDivElement>(null);
  const progress = signal.progress;
  const percentage = progressPercentage(signal);
  const progressStyle = percentage === null ? undefined : {
    '--sx-signal-progress': String(percentage / 100),
  } as CSSProperties;
  useLayoutEffect(() => {
    const surface = surfaceRef.current;
    if (surface && phase === 'active') {
      surface.style.removeProperty('--sx-signal-height');
      surface.style.setProperty('--sx-signal-height', `${surface.offsetHeight}px`);
    }
  }, [phase, signal]);
  return (
    <Surface
      ref={surfaceRef}
      material="translucent"
      intensity="subtle"
      elevation="flat"
      className="sx-signal-surface"
      role="group"
      aria-labelledby={titleId}
      aria-describedby={signal.message ? messageId : undefined}
      data-sx-signal-id={signal.signalId}
      data-sx-kind={signal.kind}
      data-sx-tone={signal.tone}
      data-sx-priority={signal.priority}
      data-sx-phase={phase}
    >
      <span className="sx-signal-locator" aria-hidden="true">
        <span className="sx-signal-locator__icon"><Icon name={signalIcon(signal)} size="sm" /></span>
        <span className="sx-signal-locator__state" />
      </span>
      <span className="sx-signal-surface__copy">
        <span className="sx-signal-surface__heading">
          <strong id={titleId}>{signal.title}</strong>
          {signal.count && signal.count > 1 ? (
            <>
              <span className="sx-signal-surface__count" aria-hidden="true">
                &times;{signal.count}
              </span>
              <span className="sx-visually-hidden">
                {`Grouped notification count: ${signal.count}`}
              </span>
            </>
          ) : null}
        </span>
        {signal.message ? <span id={messageId} className="sx-signal-surface__message">{signal.message}</span> : null}
      </span>
      {progress ? (
        <span className="sx-signal-progress" data-sx-mode={progress.mode} data-sx-state={progress.state}>
          <span
            className="sx-signal-progress__track"
            role="progressbar"
            aria-labelledby={titleId}
            aria-valuetext={progressValueText(signal, percentage)}
            aria-valuemin={progress.mode === 'determinate' ? 0 : undefined}
            aria-valuemax={progress.mode === 'determinate' ? progress.maximum : undefined}
            aria-valuenow={progress.mode === 'determinate' ? progress.value : undefined}
          >
            <span className="sx-signal-progress__fill" style={progressStyle} />
          </span>
          <span className="sx-signal-progress__value" aria-hidden="true">
            {progressDisplayText(signal, percentage)}
          </span>
        </span>
      ) : null}
      {signal.actions.length > 0 ? (
        <span className="sx-signal-actions">
          {signal.actions.map((action, index) => (
            <span key={action.token} className="sx-signal-action" data-sx-style={action.style ?? 'default'}>
              <KeyHint>{action.hint ?? defaultActionHints[inputDevice][index]}</KeyHint>
              <span>{action.label}</span>
            </span>
          ))}
        </span>
      ) : null}
    </Surface>
  );
}

export function SignalRail({
  signals,
  reducedMotion,
  inputDevice = 'keyboard',
  screen = defaultSignalScreen,
  scale = 100,
  density = 'comfortable',
  onVisibleChange,
}: {
  signals: readonly RuntimeSignal[];
  reducedMotion?: boolean;
  inputDevice?: InputDevice;
  screen?: ScreenMetrics;
  scale?: UiScale;
  density?: Density;
  onVisibleChange?: (signals: readonly RuntimeSignal[], capacity: number) => void;
}) {
  const capacity = useMemo(
    () => resolveVisibleSignalCapacity(screen, scale, density),
    [density, scale, screen],
  );
  const visible = useMemo(() => selectVisibleSignals(signals, capacity), [capacity, signals]);
  const motionReduced = reducedMotion ?? environmentPrefersReducedMotion();
  const latestVisible = useRef(visible);
  const timers = useRef(new Map<string, ReturnType<typeof setTimeout>>());
  const [presented, setPresented] = useState<PresentedSignal[]>(
    () => visible.map((signal) => ({ signal, phase: 'active' })),
  );
  latestVisible.current = visible;

  useLayoutEffect(() => {
    setPresented((current) => reconcilePresented(current, visible, motionReduced, capacity));
  }, [capacity, motionReduced, visible]);

  useEffect(() => {
    onVisibleChange?.(presented.flatMap((entry) => (
      entry.phase === 'active' ? [entry.signal] : []
    )), capacity);
  }, [capacity, onVisibleChange, presented]);

  useEffect(() => {
    const dismissing = new Set(presented
      .filter((entry) => entry.phase === 'dismissing')
      .map((entry) => signalIdentity(entry.signal)));
    for (const [identity, timer] of timers.current) {
      if (!dismissing.has(identity) || motionReduced) {
        clearTimeout(timer);
        timers.current.delete(identity);
      }
    }
    if (motionReduced) return;
    for (const identity of dismissing) {
      if (timers.current.has(identity)) continue;
      timers.current.set(identity, setTimeout(() => {
        timers.current.delete(identity);
        setPresented((current) => reconcilePresented(
          current.filter((entry) => signalIdentity(entry.signal) !== identity),
          latestVisible.current,
          false,
          capacity,
        ));
      }, SIGNAL_EXIT_MS));
    }
  }, [capacity, motionReduced, presented]);

  useEffect(() => () => {
    for (const timer of timers.current.values()) clearTimeout(timer);
    timers.current.clear();
  }, []);

  const activeSignals = presented.flatMap((entry) => (
    entry.phase === 'active' ? [entry.signal] : []
  ));
  return (
    <>
      <SignalAnnouncer signals={activeSignals} />
      {positionOrder.map((position) => {
        const positioned = presented.filter((entry) => entry.signal.position === position);
        return positioned.length > 0 ? (
          <div
            key={position}
            className="sx-signal-rail"
            data-sx-position={position}
            data-sx-capacity={capacity}
          >
            {positioned.map((entry) => (
              <SignalSurface
                key={signalIdentity(entry.signal)}
                signal={entry.signal}
                phase={entry.phase}
                inputDevice={inputDevice}
              />
            ))}
          </div>
        ) : null;
      })}
    </>
  );
}
