import { Icon, KeyHint, type SynexIconName } from '@synex/ui';
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent as ReactMouseEvent,
} from 'react';
import './interaction-surface.css';
import {
  type InputDevice,
  type InteractionInputBinding,
  type InteractionIntent,
  type InteractionProjection,
  type RuntimeInteraction,
  type ScreenMetrics,
} from './protocol';
import type { NuiTransport } from './transport';

export interface InteractionPoint {
  x: number;
  y: number;
}

export interface InteractionBounds {
  left: number;
  right: number;
  top: number;
  bottom: number;
  width: number;
  height: number;
}

const edgeInsetPx = 20;
const projectionSmoothing = 0.34;
const projectionDeadZonePx = 2.5;
const bloomPreviousKeys = new Set(['ArrowUp', 'ArrowLeft', 'w', 'W', 'a', 'A']);
const bloomNextKeys = new Set(['ArrowDown', 'ArrowRight', 's', 'S', 'd', 'D']);

export function resolveInteractionPoint(
  projection: InteractionProjection | undefined,
  screen: ScreenMetrics,
): InteractionPoint | null {
  if (projection && (!projection.visible || projection.behindCamera)) return null;
  const normalizedX = projection?.x ?? 0.5;
  const normalizedY = projection?.y ?? 0.62;
  if (!Number.isFinite(normalizedX) || !Number.isFinite(normalizedY)
    || normalizedX < 0 || normalizedX > 1 || normalizedY < 0 || normalizedY > 1) return null;
  const rawX = normalizedX * screen.width;
  const rawY = normalizedY * screen.height;
  if (rawX < 0 || rawX > screen.width || rawY < 0 || rawY > screen.height) return null;
  const minimumX = Math.min(screen.width / 2, screen.safeLeft + edgeInsetPx);
  const maximumX = Math.max(screen.width / 2, screen.width - screen.safeRight - edgeInsetPx);
  const minimumY = Math.min(screen.height / 2, screen.safeTop + edgeInsetPx);
  const maximumY = Math.max(screen.height / 2, screen.height - screen.safeBottom - edgeInsetPx);
  return {
    x: Math.min(maximumX, Math.max(minimumX, rawX)),
    y: Math.min(maximumY, Math.max(minimumY, rawY)),
  };
}

export function stabilizeInteractionPoint(
  previous: InteractionPoint | null,
  target: InteractionPoint,
  reducedMotion = false,
  deadZonePx = projectionDeadZonePx,
): InteractionPoint {
  if (!previous || reducedMotion) return target;
  const deltaX = target.x - previous.x;
  const deltaY = target.y - previous.y;
  if (Math.hypot(deltaX, deltaY) <= deadZonePx) return previous;
  return {
    x: previous.x + deltaX * projectionSmoothing,
    y: previous.y + deltaY * projectionSmoothing,
  };
}

export function containInteractionOffset(
  bounds: InteractionBounds,
  currentOffset: InteractionPoint,
  screen: ScreenMetrics,
): InteractionPoint {
  if (bounds.width <= 0 || bounds.height <= 0) return { x: 0, y: 0 };
  const baseLeft = bounds.left - currentOffset.x;
  const baseRight = bounds.right - currentOffset.x;
  const baseTop = bounds.top - currentOffset.y;
  const baseBottom = bounds.bottom - currentOffset.y;
  const minimumX = screen.safeLeft + edgeInsetPx;
  const maximumX = screen.width - screen.safeRight - edgeInsetPx;
  const minimumY = screen.safeTop + edgeInsetPx;
  const maximumY = screen.height - screen.safeBottom - edgeInsetPx;
  return {
    x: baseLeft < minimumX
      ? minimumX - baseLeft
      : baseRight > maximumX ? maximumX - baseRight : 0,
    y: baseTop < minimumY
      ? minimumY - baseTop
      : baseBottom > maximumY ? maximumY - baseBottom : 0,
  };
}

function bindingLabel(binding: InteractionInputBinding | undefined, device: InputDevice): string | undefined {
  if (!binding) return undefined;
  if (device === 'gamepad') return binding.gamepad;
  if (device === 'mouse') return binding.mouse ?? binding.keyboard;
  return binding.keyboard;
}

function progressRatio(interaction: RuntimeInteraction): number | null {
  const progress = interaction.progress;
  if (!progress || progress.mode === 'indeterminate') return null;
  if (progress.mode === 'timed') return progress.elapsedMs / progress.durationMs;
  return progress.value / progress.maximum;
}

function useProgressRatio(interaction: RuntimeInteraction): number | null {
  const progress = interaction.progress;
  const initialRatio = progressRatio(interaction);
  const [ratio, setRatio] = useState(initialRatio);

  useEffect(() => {
    if (!progress || progress.mode !== 'timed') {
      setRatio(initialRatio);
      return undefined;
    }

    const durationMs = progress.durationMs;
    let elapsedMs = Math.min(durationMs, progress.elapsedMs);
    let previousTimestamp = performance.now();
    let timeout = 0;
    setRatio(elapsedMs / durationMs);

    const advance = () => {
      const timestamp = performance.now();
      const delta = Math.max(0, timestamp - previousTimestamp);
      previousTimestamp = Math.max(previousTimestamp, timestamp);
      elapsedMs = Math.min(durationMs, elapsedMs + delta);
      const nextRatio = elapsedMs / durationMs;
      setRatio((current) => Math.max(current ?? 0, nextRatio));
      if (elapsedMs < durationMs) timeout = window.setTimeout(advance, 50);
    };

    if (elapsedMs < durationMs) timeout = window.setTimeout(advance, 50);
    return () => window.clearTimeout(timeout);
  }, [initialRatio, interaction.interactionId, interaction.revision, progress]);

  return ratio;
}

function ProgressSurface({
  interaction,
  inputDevice,
}: {
  interaction: RuntimeInteraction;
  inputDevice: InputDevice;
}) {
  const progress = interaction.progress;
  const ratio = useProgressRatio(interaction);
  if (!progress) return null;
  const percentage = ratio === null ? null : Math.round(ratio * 100);
  const cancelHint = bindingLabel(interaction.input.cancel, inputDevice);
  return (
    <div className="sx-interaction-progress" data-sx-progress-mode={progress.mode}>
      <div className="sx-interaction-progress__copy">
        <strong>{interaction.label}</strong>
        {interaction.targetLabel ? <span>{interaction.targetLabel}</span> : null}
      </div>
      <div
        className="sx-interaction-progress__track"
        role="progressbar"
        aria-label={interaction.label}
        aria-valuemin={ratio === null ? undefined : 0}
        aria-valuemax={ratio === null ? undefined : 100}
        aria-valuenow={percentage ?? undefined}
        aria-valuetext={percentage === null ? 'In progress' : `${percentage}%`}
      >
        <span
          className="sx-interaction-progress__fill"
          style={ratio === null ? undefined : { '--sx-interaction-progress': ratio } as CSSProperties}
        />
      </div>
      <div className="sx-interaction-progress__meta">
        <span>{percentage === null ? 'Working' : `${percentage}%`}</span>
        {interaction.cancellable && cancelHint ? <span><KeyHint>{cancelHint}</KeyHint> Cancel</span> : null}
      </div>
    </div>
  );
}

function IntentCopy({ intent }: { intent: InteractionIntent }) {
  return (
    <>
      {intent.iconKey ? <Icon name={intent.iconKey as SynexIconName} size="sm" /> : null}
      <span className="sx-interaction-intent__copy">
        <strong>{intent.label}</strong>
        {intent.description ? <small>{intent.description}</small> : null}
      </span>
    </>
  );
}

export function InteractionSurface({
  interaction,
  inputDevice,
  screen,
  reducedMotion,
  interactionAssist,
  transport,
  browserBootId,
}: {
  interaction: RuntimeInteraction;
  inputDevice: InputDevice;
  screen: ScreenMetrics;
  reducedMotion: boolean;
  interactionAssist: boolean;
  transport: NuiTransport;
  browserBootId: string;
}) {
  const target = useMemo(
    () => resolveInteractionPoint(interaction.projection, screen),
    [interaction.projection, screen],
  );
  const renderedPoint = useRef<InteractionPoint | null>(target);
  const [point, setPoint] = useState<InteractionPoint | null>(target);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const actionPendingRef = useRef(false);
  const surfaceRef = useRef<HTMLDivElement>(null);
  const boundedOffsetRef = useRef<InteractionPoint>({ x: 0, y: 0 });
  const [boundedOffset, setBoundedOffset] = useState<InteractionPoint>({ x: 0, y: 0 });
  const enabledIntentIds = useMemo(
    () => interaction.intents.filter((intent) => intent.disabled !== true).map((intent) => intent.intentId),
    [interaction.intents],
  );
  const initialIntentId = interaction.selectedIntentId && enabledIntentIds.includes(interaction.selectedIntentId)
    ? interaction.selectedIntentId
    : enabledIntentIds[0];
  const [focusedIntentId, setFocusedIntentId] = useState<string | undefined>(initialIntentId);
  const intentRefs = useRef(new Map<string, HTMLButtonElement>());

  useEffect(() => {
    actionPendingRef.current = false;
    setPending(false);
    setError(null);
    setFocusedIntentId(initialIntentId);
  }, [initialIntentId, interaction.interactionId, interaction.revision]);

  useLayoutEffect(() => {
    if (!point || !surfaceRef.current) {
      boundedOffsetRef.current = { x: 0, y: 0 };
      setBoundedOffset({ x: 0, y: 0 });
      return;
    }
    const next = containInteractionOffset(
      surfaceRef.current.getBoundingClientRect(),
      boundedOffsetRef.current,
      screen,
    );
    if (next.x === boundedOffsetRef.current.x && next.y === boundedOffsetRef.current.y) return;
    boundedOffsetRef.current = next;
    setBoundedOffset(next);
  }, [interaction.interactionId, interaction.mode, interaction.revision, point, screen]);

  useLayoutEffect(() => {
    if (!target) {
      renderedPoint.current = null;
      setPoint(null);
      return undefined;
    }
    const initial = stabilizeInteractionPoint(
      renderedPoint.current,
      target,
      reducedMotion,
      interactionAssist ? projectionDeadZonePx * 1.4 : projectionDeadZonePx,
    );
    renderedPoint.current = initial;
    setPoint(initial);
    const remainingDistance = Math.hypot(target.x - initial.x, target.y - initial.y);
    if (reducedMotion || remainingDistance <= (interactionAssist
      ? projectionDeadZonePx * 1.4 : projectionDeadZonePx)) return undefined;
    let frame = 0;
    const advance = () => {
      const current = renderedPoint.current ?? target;
      const deltaX = target.x - current.x;
      const deltaY = target.y - current.y;
      if (Math.hypot(deltaX, deltaY) <= 0.5) {
        renderedPoint.current = target;
        setPoint(target);
        return;
      }
      const next = {
        x: current.x + deltaX * projectionSmoothing,
        y: current.y + deltaY * projectionSmoothing,
      };
      renderedPoint.current = next;
      setPoint(next);
      frame = window.requestAnimationFrame(advance);
    };
    frame = window.requestAnimationFrame(advance);
    return () => window.cancelAnimationFrame(frame);
  }, [interactionAssist, reducedMotion, target]);

  useEffect(() => {
    if (interaction.mode === 'bloom' && interaction.pointer && focusedIntentId) {
      intentRefs.current.get(focusedIntentId)?.focus();
    }
  }, [focusedIntentId, interaction.interactionId, interaction.mode, interaction.pointer, interaction.revision]);

  const postAction = useCallback(async (action: 'activate' | 'cancel', intentId?: string) => {
    if (actionPendingRef.current) return;
    actionPendingRef.current = true;
    setPending(true);
    setError(null);
    const response = await transport.post('runtime:interaction', {
      requestId: `interaction_${interaction.revision}`,
      browserBootId,
      interactionId: interaction.interactionId,
      ownerEpoch: interaction.ownerEpoch,
      revision: interaction.revision,
      action,
      device: inputDevice,
      ...(intentId ? { intentId } : {}),
    });
    if (!response.ok) {
      actionPendingRef.current = false;
      setPending(false);
      setError(response.error.code === 'UI_REQUEST_STALE'
        ? 'This interaction changed. Choose again.'
        : 'The interaction could not be handed off.');
    }
  }, [browserBootId, inputDevice, interaction, transport]);

  const onBloomKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (event.key === 'Escape' && interaction.cancellable) {
      event.preventDefault();
      void postAction('cancel');
      return;
    }
    if (!interaction.pointer || enabledIntentIds.length === 0 || pending) return;

    let nextIndex: number | undefined;
    const currentIndex = Math.max(0, enabledIntentIds.indexOf(focusedIntentId ?? ''));
    if (bloomPreviousKeys.has(event.key)) {
      nextIndex = (currentIndex - 1 + enabledIntentIds.length) % enabledIntentIds.length;
    } else if (bloomNextKeys.has(event.key)) {
      nextIndex = (currentIndex + 1) % enabledIntentIds.length;
    } else if (event.key === 'Home') {
      nextIndex = 0;
    } else if (event.key === 'End') {
      nextIndex = enabledIntentIds.length - 1;
    } else if ((event.key === 'Enter' || event.key === ' ') && focusedIntentId) {
      event.preventDefault();
      void postAction('activate', focusedIntentId);
      return;
    } else {
      return;
    }
    event.preventDefault();
    setFocusedIntentId(enabledIntentIds[nextIndex]);
  };

  const onBloomContextMenu = (event: ReactMouseEvent<HTMLDivElement>) => {
    if (!interaction.pointer || !interaction.cancellable) return;
    event.preventDefault();
    void postAction('cancel');
  };

  if (!point) return null;
  const position = {
    '--sx-interaction-x': `${point.x}px`,
    '--sx-interaction-y': `${point.y}px`,
    '--sx-interaction-offset-x': `${boundedOffset.x}px`,
    '--sx-interaction-offset-y': `${boundedOffset.y}px`,
  } as CSSProperties;
  const primary = interaction.intents[0];
  const primaryHint = bindingLabel(interaction.input.primary, inputDevice);
  const moreHint = bindingLabel(interaction.input.more, inputDevice);

  return (
    <div
      ref={surfaceRef}
      className="sx-interaction"
      style={position}
      data-sx-mode={interaction.mode}
      data-sx-pointer={interaction.pointer}
      data-sx-assist={interactionAssist}
      data-sx-interaction-id={interaction.interactionId}
      aria-label={interaction.label}
    >
      <span className="sx-interaction__locator" aria-hidden="true" />
      {interaction.mode === 'cue' && primary ? (
        <div className="sx-interaction-cue">
          {primaryHint ? <KeyHint>{primaryHint}</KeyHint> : null}
          <span className="sx-interaction-cue__copy">
            <strong>{primary.label}</strong>
            {interaction.targetLabel ? <small>{interaction.targetLabel}</small> : null}
          </span>
          {(interaction.moreCount ?? 0) > 0 ? (
            <span className="sx-interaction-cue__more">
              <span>+{interaction.moreCount}</span>
              {moreHint ? <KeyHint>{moreHint}</KeyHint> : null}
            </span>
          ) : null}
        </div>
      ) : null}
      {interaction.mode === 'bloom' ? (
        <div
          className="sx-interaction-bloom"
          aria-busy={pending || undefined}
          onKeyDown={onBloomKeyDown}
          onContextMenu={onBloomContextMenu}
        >
          <div className="sx-interaction-bloom__heading">
            <strong>{interaction.label}</strong>
            {interaction.targetLabel ? <span>{interaction.targetLabel}</span> : null}
          </div>
          <div className="sx-interaction-bloom__intents" role={interaction.pointer ? 'menu' : 'list'}>
            {interaction.intents.map((intent) => {
              const selected = intent.intentId === interaction.selectedIntentId;
              const focused = intent.intentId === focusedIntentId;
              return interaction.pointer ? (
                <button
                  ref={(element) => {
                    if (element) intentRefs.current.set(intent.intentId, element);
                    else intentRefs.current.delete(intent.intentId);
                  }}
                  key={intent.intentId}
                  type="button"
                  className="sx-interaction-intent"
                  role="menuitem"
                  data-sx-roving-item
                  data-sx-selected={selected}
                  disabled={intent.disabled || pending}
                  tabIndex={focused ? 0 : -1}
                  onFocus={() => setFocusedIntentId(intent.intentId)}
                  onClick={() => void postAction('activate', intent.intentId)}
                >
                  <IntentCopy intent={intent} />
                </button>
              ) : (
                <div
                  key={intent.intentId}
                  className="sx-interaction-intent"
                  role="listitem"
                  aria-current={selected ? 'true' : undefined}
                  aria-disabled={intent.disabled || undefined}
                  data-sx-selected={selected}
                  data-sx-disabled={intent.disabled || undefined}
                >
                  <IntentCopy intent={intent} />
                </div>
              );
            })}
          </div>
          <div className="sx-interaction-bloom__hints">
            {primaryHint ? <span><KeyHint>{primaryHint}</KeyHint> Select</span> : null}
            {bindingLabel(interaction.input.cancel, inputDevice) ? (
              <span><KeyHint>{bindingLabel(interaction.input.cancel, inputDevice)}</KeyHint> Back</span>
            ) : null}
          </div>
          {error ? <span className="sx-interaction-bloom__error" role="status">{error}</span> : null}
        </div>
      ) : null}
      {interaction.mode === 'progress' ? (
        <ProgressSurface interaction={interaction} inputDevice={inputDevice} />
      ) : null}
    </div>
  );
}
