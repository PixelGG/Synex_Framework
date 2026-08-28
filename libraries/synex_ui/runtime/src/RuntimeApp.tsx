import {
  Component,
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  type CSSProperties,
  type ErrorInfo,
  type ReactNode,
} from 'react';
import {
  ActionRow,
  Button,
  Checkbox,
  Combobox,
  Dialog,
  Field,
  FieldGroup,
  Icon,
  Input,
  KeyHint,
  Menu,
  MultiSelect,
  NumberInput,
  Radio,
  SearchSelect,
  Slider,
  Stack,
  Switch,
  TextArea,
  ValidationMessage,
  type MenuItem,
  type SynexIconName,
} from '@synex/ui';
import {
  UI_PROTOCOL_VERSION,
  createBrowserBootId,
  parseGameEnvelope,
  type InputDevice,
  type NavigationIntent,
  type RuntimeSurface,
  type SurfaceField,
  type SurfaceOption,
} from './protocol';
import { createInitialRuntimeState, runtimeReducer } from './store';
import { createNuiTransport, type NuiTransport } from './transport';

interface BoundaryProps {
  open: boolean;
  surface?: RuntimeSurface;
  transport: NuiTransport;
  browserBootId: string;
  children: ReactNode;
}
interface BoundaryState { failed: boolean }

export class OpenSurfaceBoundary extends Component<BoundaryProps, BoundaryState> {
  override state: BoundaryState = { failed: false };

  static getDerivedStateFromError(): BoundaryState {
    return { failed: true };
  }

  override componentDidCatch(_error: Error, _info: ErrorInfo) {
    // The callback contains no exception text or payload data by design.
    const surface = this.props.surface;
    void this.props.transport.post('runtime:error', {
      requestId: createRequestId('error'),
      browserBootId: this.props.browserBootId,
      code: 'UI_REQUEST_INVALID',
      stage: 'render',
      ...(surface ? {
        surfaceRequestId: surface.requestId,
        instanceId: surface.instanceId,
        surfaceId: surface.surfaceId,
        ownerEpoch: surface.ownerEpoch,
        revision: surface.revision,
      } : {}),
    });
  }

  override componentDidUpdate(previous: BoundaryProps) {
    if (!this.state.failed || !this.props.open) return;
    const previousSurface = previous.surface;
    const currentSurface = this.props.surface;
    const opened = !previous.open;
    const correlationChanged = previousSurface?.requestId !== currentSurface?.requestId
      || previousSurface?.instanceId !== currentSurface?.instanceId
      || previousSurface?.surfaceId !== currentSurface?.surfaceId
      || previousSurface?.ownerResource !== currentSurface?.ownerResource
      || previousSurface?.ownerEpoch !== currentSurface?.ownerEpoch
      || previousSurface?.revision !== currentSurface?.revision;
    if (opened || correlationChanged) this.setState({ failed: false });
  }

  override render() {
    if (!this.props.open) return null;
    if (!this.state.failed) return <div className="sx-root sx-runtime-root">{this.props.children}</div>;
    const surface = this.props.surface;
    return (
      <div className="sx-root sx-runtime-root">
        <div className="sx-runtime-error" role="alert">
          <strong>This surface could not be rendered.</strong>
          <span>The runtime requested a fail-safe focus release. Retry the action from its owning resource.</span>
          {surface ? <button type="button" className="sx-button" data-sx-variant="secondary" onClick={() => {
            void this.props.transport.post('runtime:close', {
              requestId: surface.requestId,
              browserBootId: this.props.browserBootId,
              instanceId: surface.instanceId,
              surfaceId: surface.surfaceId,
              ownerEpoch: surface.ownerEpoch,
              revision: surface.revision,
              reason: 'renderFailure',
            });
          }}>Release focus</button> : null}
        </div>
      </div>
    );
  }
}

function createRequestId(prefix: string): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return `${prefix}_${Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}

function allowedMessageOrigins(): Set<string> {
  return new Set([
    window.location.origin,
    'https://nui-game-internal',
    'https://cfx-nui-synex_ui',
  ]);
}

const navigationIntentEvents = new WeakSet<Event>();

function dispatchIntentKey(target: HTMLElement | Document, key: string): boolean {
  const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true });
  navigationIntentEvents.add(event);
  return !target.dispatchEvent(event);
}

export function focusByIntent(intent: NavigationIntent) {
  const active = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  if (intent === 'BACK') {
    dispatchIntentKey(active ?? document, 'Escape');
    return;
  }
  if (intent === 'CONFIRM') {
    active?.click();
    return;
  }
  if (intent === 'NEXT_TAB' || intent === 'PREVIOUS_TAB') {
    const selectedTab = active?.closest<HTMLElement>('[role="tab"]')
      ?? document.querySelector<HTMLElement>('[role="tab"][aria-selected="true"]');
    if (selectedTab && dispatchIntentKey(selectedTab, intent === 'NEXT_TAB' ? 'ArrowRight' : 'ArrowLeft')) return;
  }
  const keyByIntent: Partial<Record<NavigationIntent, string>> = {
    UP: 'ArrowUp',
    DOWN: 'ArrowDown',
    LEFT: 'ArrowLeft',
    RIGHT: 'ArrowRight',
    PAGE_UP: 'PageUp',
    PAGE_DOWN: 'PageDown',
  };
  const semanticKey = keyByIntent[intent];
  if (active && semanticKey && dispatchIntentKey(active, semanticKey)) return;
  const candidates = Array.from(document.querySelectorAll<HTMLElement>(
    '[data-sx-roving-item]:not([disabled]), button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex="0"]',
  )).filter((element) => element.offsetParent !== null);
  if (candidates.length === 0) return;
  const current = Math.max(candidates.indexOf(document.activeElement as HTMLElement), 0);
  const backwards = intent === 'UP' || intent === 'LEFT' || intent === 'PREVIOUS_TAB' || intent === 'PAGE_UP';
  const next = (current + (backwards ? -1 : 1) + candidates.length) % candidates.length;
  candidates[next]?.focus();
}

function applyDocumentState(open: boolean, state: ReturnType<typeof createInitialRuntimeState>) {
  document.body.dataset.sxOpen = open ? 'true' : 'false';
  document.documentElement.dataset.sxQuality = state.preferences.quality.toLowerCase();
  document.documentElement.dataset.sxDensity = state.preferences.density;
  document.documentElement.dataset.sxReducedMotion = String(state.preferences.reducedMotion);
  document.documentElement.dataset.sxReducedTransparency = String(state.preferences.reducedTransparency);
  document.documentElement.dataset.sxHighContrast = String(state.preferences.highContrast);
  document.documentElement.dataset.sxInput = state.inputDevice;
  const style = document.documentElement.style;
  style.setProperty('--synex-screen-width', `${state.screen.width}px`);
  style.setProperty('--synex-screen-height', `${state.screen.height}px`);
  style.setProperty('--synex-aspect-ratio', String(state.screen.aspectRatio));
  style.setProperty('--synex-safe-left', `${state.screen.safeLeft}px`);
  style.setProperty('--synex-safe-right', `${state.screen.safeRight}px`);
  style.setProperty('--synex-safe-top', `${state.screen.safeTop}px`);
  style.setProperty('--synex-safe-bottom', `${state.screen.safeBottom}px`);
  style.setProperty('--synex-ui-scale', String(state.preferences.scale / 100));
}

function defaultFieldValue(field: SurfaceField): unknown {
  if (field.value !== undefined) return field.value;
  if (field.type === 'checkbox' || field.type === 'switch') return false;
  if (field.type === 'multi-select') return [];
  if (field.type === 'number' || field.type === 'slider') return field.min ?? 0;
  return '';
}

function validateFieldValue(field: SurfaceField, value: unknown): string | undefined {
  if (field.disabled) return undefined;
  const optionIds = new Set(field.options.map((option) => option.id));
  if (field.required) {
    if ((field.type === 'checkbox' || field.type === 'switch') && value !== true) return 'This field must be enabled.';
    if (field.type === 'multi-select' && (!Array.isArray(value) || value.length === 0)) return 'Select at least one option.';
    if (typeof value === 'string' && value.length === 0) return 'This field is required.';
  }
  if (field.type === 'number' || field.type === 'slider') {
    if (typeof value !== 'number' || !Number.isFinite(value)) return 'Enter a valid number.';
    if (field.min !== undefined && value < field.min) return `Use a value of at least ${field.min}.`;
    if (field.max !== undefined && value > field.max) return `Use a value no greater than ${field.max}.`;
  }
  if (field.type === 'select' || field.type === 'radio') {
    if (typeof value !== 'string' || (value.length > 0 && !optionIds.has(value))) return 'Select a valid option.';
  }
  if (field.type === 'multi-select') {
    if (!Array.isArray(value) || value.some((entry) => typeof entry !== 'string' || !optionIds.has(entry))) return 'Select only available options.';
  }
  if (typeof value === 'string') {
    if (field.minLength !== undefined && value.length < field.minLength) return `Enter at least ${field.minLength} characters.`;
    if (field.maxLength !== undefined && value.length > field.maxLength) return `Enter no more than ${field.maxLength} characters.`;
  }
  return undefined;
}

function RuntimeOptionLabel({ option }: { option: SurfaceOption }) {
  return (
    <span className="sx-runtime-option-label">
      {option.icon ? <Icon name={option.icon as SynexIconName} /> : null}
      <span>{option.label}</span>
      {option.shortcut ? <KeyHint>{option.shortcut}</KeyHint> : null}
    </span>
  );
}

function optionSelectionData(option: SurfaceOption): { id: string; metadata?: Record<string, unknown> } {
  return option.metadata === undefined ? { id: option.id } : { id: option.id, metadata: option.metadata };
}

function runtimeMenuItems(options: readonly SurfaceOption[], onSelect: (option: SurfaceOption) => void, busy: boolean): MenuItem[] {
  return options.map((option) => {
    const label = <span className="sx-runtime-menu-option"><span>{option.label}</span>{option.description ? <small>{option.description}</small> : null}</span>;
    if (option.options?.length) {
      return {
        type: 'submenu',
        id: option.id,
        label,
        icon: option.icon ? <Icon name={option.icon as SynexIconName} /> : undefined,
        disabled: busy || option.disabled,
        items: runtimeMenuItems(option.options, onSelect, busy),
      };
    }
    return {
      id: option.id,
      label,
      icon: option.icon ? <Icon name={option.icon as SynexIconName} /> : undefined,
      hint: option.shortcut,
      disabled: busy || option.disabled,
      danger: option.danger,
      onSelect: () => onSelect(option),
    };
  });
}

function runtimeSectionItems(surface: RuntimeSurface, onSelect: (option: SurfaceOption) => void, busy: boolean): MenuItem[] {
  const sections = surface.sections.length > 0 ? surface.sections : [{ id: 'default', items: surface.options }];
  return sections.flatMap((section, index) => [
    ...(index > 0 ? [{ type: 'separator' as const, id: `section-separator-${section.id}` }] : []),
    ...(section.label ? [{ type: 'label' as const, id: `section-label-${section.id}`, label: section.label }] : []),
    ...runtimeMenuItems(section.items, onSelect, busy),
  ]);
}

function RuntimeField({ field, value, validation, onChange }: {
  field: SurfaceField;
  value: unknown;
  validation?: string;
  onChange: (value: unknown) => void;
}) {
  const validationId = `sx-runtime-${field.id}-validation`;
  const validationProps = {
    'aria-invalid': validation ? true : undefined,
    'aria-describedby': validation ? validationId : undefined,
  } as const;
  const common = {
    disabled: field.disabled,
    required: field.required,
    ...validationProps,
  };
  if (field.type === 'textarea') {
    return <TextArea {...common} data-sx-runtime-id={field.id} placeholder={field.placeholder} minLength={field.minLength} maxLength={field.maxLength} value={String(value ?? '')} onChange={(event) => onChange(event.currentTarget.value)} />;
  }
  if (field.type === 'number') {
    return <NumberInput {...common} data-sx-runtime-id={field.id} value={typeof value === 'number' ? value : 0} minimum={field.min} maximum={field.max} step={field.step} onValueChange={onChange} />;
  }
  if (field.type === 'checkbox') {
    return <Checkbox {...common} data-sx-runtime-id={field.id} label={field.label} description={field.description} checked={value === true} onChange={(event) => onChange(event.currentTarget.checked)} />;
  }
  if (field.type === 'switch') {
    return <Switch {...common} data-sx-runtime-id={field.id} label={field.label} description={field.description} checked={value === true} onCheckedChange={onChange} />;
  }
  if (field.type === 'slider') {
    return <Slider {...common} data-sx-runtime-id={field.id} value={typeof value === 'number' ? value : 0} minimum={field.min} maximum={field.max} step={field.step} showValue onValueChange={onChange} />;
  }
  if (field.type === 'radio') {
    return (
      <FieldGroup legend={field.label} description={field.description} aria-invalid={validation ? true : undefined} aria-describedby={validation ? validationId : undefined}>
        {field.options.map((option) => (
          <Radio key={option.id} data-sx-runtime-id={option.id} name={field.id} value={option.id} required={field.required} label={<RuntimeOptionLabel option={option} />} description={option.description} disabled={common.disabled || option.disabled} checked={value === option.id} onChange={() => onChange(option.id)} />
        ))}
      </FieldGroup>
    );
  }
  if (field.type === 'select') {
    return (
      <Combobox {...common} data-sx-runtime-id={field.id} value={String(value ?? '')} onValueChange={onChange} placeholder={field.placeholder} options={field.options.map((option) => ({ value: option.id, label: <RuntimeOptionLabel option={option} />, description: option.description, disabled: option.disabled, keywords: [option.label, option.description ?? ''] }))} />
    );
  }
  if (field.type === 'multi-select') {
    const selected = Array.isArray(value) ? value : [];
    return (
      <MultiSelect
        {...common}
        data-sx-runtime-id={field.id}
        options={field.options.map((option) => ({ value: option.id, label: <RuntimeOptionLabel option={option} />, description: option.description, disabled: option.disabled, keywords: [option.label, option.description ?? ''] }))}
        value={selected as string[]}
        onValueChange={(entries) => onChange([...entries])}
        placeholder={field.placeholder ?? 'Select options'}
      />
    );
  }
  return <Input {...common} data-sx-runtime-id={field.id} type="text" placeholder={field.placeholder} minLength={field.minLength} maxLength={field.maxLength} value={String(value ?? '')} onChange={(event) => onChange(event.currentTarget.value)} />;
}

function SharedSurface({ surface, active, transport, browserBootId, inputDevice }: {
  surface: RuntimeSurface;
  active: boolean;
  transport: NuiTransport;
  browserBootId: string;
  inputDevice: InputDevice;
}) {
  const initial = useMemo(() => Object.fromEntries(surface.fields.map((field) => [field.id, defaultFieldValue(field)])), [surface]);
  const [values, setValues] = useState<Record<string, unknown>>(initial);
  const [selectedOptions, setSelectedOptions] = useState<readonly string[]>([]);
  const [validationErrors, setValidationErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const cancelRef = useRef<HTMLButtonElement | null>(null);

  const updateField = (fieldId: string, value: unknown) => {
    setValues((current) => ({ ...current, [fieldId]: value }));
    setValidationErrors((current) => {
      if (current[fieldId] === undefined) return current;
      const next = { ...current };
      delete next[fieldId];
      return next;
    });
    setError(null);
  };

  useEffect(() => {
    if (!active || !surface.initialFocus) return;
    const target = document.querySelector<HTMLElement>(`[data-sx-runtime-id="${surface.initialFocus}"]`);
    const focusable = target?.matches('button, input, select, textarea, [tabindex]')
      ? target
      : target?.querySelector<HTMLElement>('button, input, select, textarea, [tabindex]');
    focusable?.focus();
  }, [active, surface.initialFocus]);

  const respond = async (action: 'confirmed' | 'cancelled' | 'selected', data?: unknown) => {
    if (busy) return;
    setBusy(true);
    setError(null);
    const response = await transport.post('runtime:respond', {
      requestId: surface.requestId,
      browserBootId,
      instanceId: surface.instanceId,
      surfaceId: surface.surfaceId,
      ownerEpoch: surface.ownerEpoch,
      revision: surface.revision,
      action,
      ...(data === undefined ? {} : { data }),
    });
    if (!response.ok) {
      setBusy(false);
      setError(response.error.code === 'UI_REQUEST_CANCELLED'
        ? 'The request was cancelled before it reached the owner.'
        : 'The owning resource did not accept this response. Try again.');
    }
  };

  const close = async () => {
    if (!surface.dismissible || busy) return;
    setBusy(true);
    const response = await transport.post('runtime:close', {
      requestId: surface.requestId,
      browserBootId,
      instanceId: surface.instanceId,
      surfaceId: surface.surfaceId,
      ownerEpoch: surface.ownerEpoch,
      revision: surface.revision,
      reason: 'cancelled',
    });
    if (!response.ok) {
      setBusy(false);
      setError('The surface could not be closed safely.');
    }
  };

  if (!active) return null;

  const body = surface.kind === 'menu' || surface.kind === 'contextMenu' ? (
    <Menu
      className="sx-runtime-menu"
      items={runtimeSectionItems(surface, (option) => { void respond('selected', optionSelectionData(option)); }, busy)}
      label={surface.title}
      initialActiveId={surface.initialFocus}
    />
  ) : surface.kind === 'select' ? (
    surface.multiple ? (
      <Stack gap="md" className="sx-runtime-options">
        <MultiSelect
          data-sx-runtime-id={surface.initialFocus}
          aria-label={surface.title}
          options={surface.options.map((option) => ({ value: option.id, label: <RuntimeOptionLabel option={option} />, description: option.description, disabled: option.disabled, keywords: [option.label, option.description ?? ''] }))}
          value={selectedOptions}
          onValueChange={setSelectedOptions}
          placeholder={surface.placeholder ?? 'Select options'}
          disabled={busy}
        />
        <ActionRow>
          {surface.dismissible ? <Button variant="secondary" disabled={busy} onClick={() => void respond('cancelled')}>{surface.cancelLabel ?? 'Cancel'}</Button> : null}
          <Button loading={busy} onClick={() => void respond('selected', { ids: selectedOptions })}>{surface.confirmLabel ?? 'Select'}</Button>
        </ActionRow>
      </Stack>
    ) : surface.searchable ? (
      <SearchSelect
        data-sx-runtime-id={surface.initialFocus}
        aria-label={surface.title}
        options={surface.options.map((option) => ({ value: option.id, label: <RuntimeOptionLabel option={option} />, description: option.description, disabled: option.disabled, keywords: [option.label, option.description ?? ''] }))}
        placeholder={surface.placeholder ?? 'Search options'}
        disabled={busy}
        onValueChange={(id) => { void respond('selected', { id }); }}
      />
    ) : (
      <Stack gap="xs" className="sx-runtime-options" role="group" aria-label={surface.title}>
        {surface.options.map((option) => (
          <Button key={option.id} variant={option.danger ? 'danger' : 'secondary'} disabled={option.disabled || busy} data-sx-roving-item data-sx-runtime-id={option.id} onClick={() => void respond('selected', optionSelectionData(option))}>
            <RuntimeOptionLabel option={option} />
            {option.description ? <small>{option.description}</small> : null}
          </Button>
        ))}
      </Stack>
    )
  ) : surface.fields.length > 0 ? (
    <form id={`sx-form-${surface.surfaceId}`} className="sx-runtime-form" noValidate onSubmit={(event) => {
      event.preventDefault();
      const nextErrors = Object.fromEntries(surface.fields.flatMap((field) => {
        const validation = validateFieldValue(field, values[field.id]);
        return validation ? [[field.id, validation] as const] : [];
      }));
      if (Object.keys(nextErrors).length > 0) {
        setValidationErrors(nextErrors);
        setError('Review the highlighted fields before continuing.');
        const firstInvalid = surface.fields.find((field) => nextErrors[field.id] !== undefined);
        if (firstInvalid) queueMicrotask(() => document.querySelector<HTMLElement>(`[data-sx-runtime-id="${firstInvalid.id}"]`)?.focus());
        return;
      }
      setValidationErrors({});
      void respond('confirmed', values);
    }}>
      <Stack gap="md">
        {surface.fields.map((field) => field.type === 'checkbox' || field.type === 'switch' || field.type === 'radio'
          ? <div key={field.id} data-sx-invalid={validationErrors[field.id] ? true : undefined}><RuntimeField field={field} value={values[field.id]} validation={validationErrors[field.id]} onChange={(value) => updateField(field.id, value)} />{validationErrors[field.id] ? <ValidationMessage id={`sx-runtime-${field.id}-validation`}>{validationErrors[field.id]}</ValidationMessage> : null}</div>
          : (
            <Field key={field.id} controlId={`sx-runtime-${field.id}`} label={field.label} description={field.description} validation={validationErrors[field.id]} required={field.required} disabled={field.disabled}>
              <RuntimeField field={field} value={values[field.id]} validation={validationErrors[field.id]} onChange={(value) => updateField(field.id, value)} />
            </Field>
          ))}
      </Stack>
    </form>
  ) : null;

  return (
    <Dialog
      open
      className={surface.kind === 'contextMenu' ? 'sx-runtime-context-menu' : undefined}
      style={surface.anchor ? {
        '--sx-runtime-anchor-x': `${surface.anchor.x * 100}vw`,
        '--sx-runtime-anchor-y': `${surface.anchor.y * 100}vh`,
      } as CSSProperties : undefined}
      title={surface.title}
      description={surface.description}
      initialFocusRef={surface.tone === 'danger' ? cancelRef : undefined}
      closeOnBackdrop={surface.dismissible && !busy}
      closeOnEscape={surface.dismissible && !busy}
      onOpenChange={(open) => { if (!open) void close(); }}
      size={surface.kind === 'menu' || surface.kind === 'contextMenu' ? 'sm' : 'md'}
      footer={surface.kind === 'menu' || surface.kind === 'contextMenu' || surface.kind === 'select' ? null : (
        <ActionRow>
          {surface.dismissible ? <Button ref={cancelRef} variant="secondary" disabled={busy} onClick={() => void respond('cancelled')}>{surface.cancelLabel ?? 'Cancel'}</Button> : null}
          <Button type={surface.fields.length > 0 ? 'submit' : 'button'} form={surface.fields.length > 0 ? `sx-form-${surface.surfaceId}` : undefined} variant={surface.tone === 'danger' ? 'danger' : 'primary'} loading={busy} onClick={surface.fields.length === 0 ? () => void respond('confirmed') : undefined}>{surface.confirmLabel ?? (surface.kind === 'alert' ? 'Acknowledge' : 'Continue')}</Button>
        </ActionRow>
      )}
    >
      {body}
      {error ? <ValidationMessage>{error}</ValidationMessage> : null}
      <div className="sx-runtime-hints" aria-label={`Current input: ${inputDevice}`}>
        <KeyHint>{inputDevice === 'gamepad' ? 'A' : inputDevice === 'mouse' ? 'Click' : 'Enter'}</KeyHint><span>Confirm</span>
        {surface.dismissible ? <><KeyHint>{inputDevice === 'gamepad' ? 'B' : inputDevice === 'mouse' ? 'Outside' : 'Esc'}</KeyHint><span>Back</span></> : null}
      </div>
    </Dialog>
  );
}

export function RuntimeApp() {
  const browserBootId = useMemo(createBrowserBootId, []);
  const transport = useMemo(() => createNuiTransport(), []);
  const [state, dispatch] = useReducer(runtimeReducer, browserBootId, createInitialRuntimeState);
  const inputRef = useRef<InputDevice>('keyboard');
  const open = state.surfaces.length > 0;

  useEffect(() => {
    inputRef.current = state.inputDevice;
  }, [state.inputDevice]);

  const reportInput = useCallback((device: InputDevice) => {
    if (inputRef.current === device) return;
    inputRef.current = device;
    dispatch({ type: 'input-device', device });
    void transport.post('runtime:input', {
      requestId: createRequestId('input'),
      browserBootId,
      device,
    });
  }, [browserBootId, transport]);

  useEffect(() => {
    const controller = new AbortController();
    void transport.post<{ ready: boolean }>('runtime:ready', {
      requestId: createRequestId('ready'),
      browserBootId,
      protocolVersion: UI_PROTOCOL_VERSION,
    }, controller.signal).then((response) => {
      dispatch(response.ok ? { type: 'browser-ready', browserBootId } : { type: 'browser-error' });
    });
    return () => controller.abort();
  }, [browserBootId, transport]);

  useEffect(() => {
    const origins = allowedMessageOrigins();
    const onMessage = (event: MessageEvent<unknown>) => {
      if (!origins.has(event.origin)) return;
      const envelope = parseGameEnvelope(event.data);
      if (!envelope) {
        void transport.post('runtime:error', {
          requestId: createRequestId('invalid'),
          browserBootId,
          code: 'UI_REQUEST_INVALID',
          stage: 'message',
        });
        return;
      }
      if (envelope.type === 'input:intent') {
        const intent = envelope.payload.intent;
        if (typeof intent === 'string' && ['UP', 'DOWN', 'LEFT', 'RIGHT', 'CONFIRM', 'BACK', 'NEXT_TAB', 'PREVIOUS_TAB', 'PAGE_UP', 'PAGE_DOWN'].includes(intent)) {
          reportInput('gamepad');
          focusByIntent(intent as NavigationIntent);
        }
      }
      dispatch({ type: 'message', envelope });
    };
    window.addEventListener('message', onMessage);
    return () => window.removeEventListener('message', onMessage);
  }, [browserBootId, reportInput, transport]);

  useEffect(() => {
    applyDocumentState(open, state);
    const root = document.getElementById('root');
    root?.setAttribute('aria-hidden', open ? 'false' : 'true');
  }, [open, state]);

  useEffect(() => {
    if (!open) return undefined;
    const pointer = () => reportInput('mouse');
    const keyboard = (event: KeyboardEvent) => {
      if (navigationIntentEvents.has(event)) return;
      if (!event.metaKey && !event.ctrlKey && !event.altKey) reportInput('keyboard');
    };
    window.addEventListener('pointermove', pointer, { passive: true });
    window.addEventListener('pointerdown', pointer, { passive: true });
    window.addEventListener('keydown', keyboard, true);
    return () => {
      window.removeEventListener('pointermove', pointer);
      window.removeEventListener('pointerdown', pointer);
      window.removeEventListener('keydown', keyboard, true);
    };
  }, [open, reportInput]);

  const activeSurface = state.surfaces[state.surfaces.length - 1];
  return (
    <OpenSurfaceBoundary open={open} surface={activeSurface} transport={transport} browserBootId={browserBootId}>
      {state.surfaces.map((surface) => (
        <SharedSurface
          key={`${surface.ownerResource}:${surface.ownerEpoch}:${surface.requestId}:${surface.instanceId}:${surface.surfaceId}`}
          surface={surface}
          active={surface === activeSurface}
          transport={transport}
          browserBootId={browserBootId}
          inputDevice={state.inputDevice}
        />
      ))}
    </OpenSurfaceBoundary>
  );
}
