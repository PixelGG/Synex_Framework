import {
  createContext,
  forwardRef,
  useContext,
  useMemo,
  useState,
  type AriaAttributes,
  type ChangeEvent,
  type FieldsetHTMLAttributes,
  type HTMLAttributes,
  type InputHTMLAttributes,
  type ReactNode,
  type TextareaHTMLAttributes,
} from "react";
import { Button, IconButton } from "./actions.js";
import { clamp, composeIds, mergeRefs, sx, useControllableState, useStableId, type SynexSize } from "./internal.js";

interface FieldContextValue {
  controlId: string;
  descriptionId?: string;
  validationId?: string;
  invalid: boolean;
  required: boolean;
  disabled: boolean;
}

const FieldContext = createContext<FieldContextValue | null>(null);

export interface FieldProps extends HTMLAttributes<HTMLDivElement> {
  label: ReactNode;
  description?: ReactNode;
  validation?: ReactNode;
  invalid?: boolean;
  required?: boolean;
  disabled?: boolean;
  controlId?: string;
  optionalLabel?: string;
}

export const Field = forwardRef<HTMLDivElement, FieldProps>(function Field(
  {
    label,
    description,
    validation,
    invalid = validation !== undefined,
    required = false,
    disabled = false,
    controlId: explicitId,
    optionalLabel = "Optional",
    className,
    children,
    ...props
  },
  ref,
) {
  const controlId = useStableId(explicitId, "sx-field");
  const descriptionId = description === undefined ? undefined : `${controlId}-description`;
  const validationId = validation === undefined ? undefined : `${controlId}-validation`;
  const context = useMemo<FieldContextValue>(
    () => ({ controlId, ...(descriptionId ? { descriptionId } : {}), ...(validationId ? { validationId } : {}), invalid, required, disabled }),
    [controlId, descriptionId, disabled, invalid, required, validationId],
  );
  return (
    <FieldContext.Provider value={context}>
      <div ref={ref} className={sx("sx-field", className)} data-sx-invalid={invalid || undefined} data-sx-disabled={disabled || undefined} {...props}>
        <div className="sx-field__heading">
          <label className="sx-field__label" htmlFor={controlId}>{label}</label>
          {!required ? <span className="sx-field__optional">{optionalLabel}</span> : null}
        </div>
        {description !== undefined ? <div id={descriptionId} className="sx-field__description">{description}</div> : null}
        <div className="sx-field__control">{children}</div>
        {validation !== undefined ? <ValidationMessage id={validationId}>{validation}</ValidationMessage> : null}
      </div>
    </FieldContext.Provider>
  );
});

export interface FieldGroupProps extends FieldsetHTMLAttributes<HTMLFieldSetElement> {
  legend: ReactNode;
  description?: ReactNode;
  orientation?: "horizontal" | "vertical";
}

export const FieldGroup = forwardRef<HTMLFieldSetElement, FieldGroupProps>(function FieldGroup(
  { legend, description, orientation = "vertical", className, children, ...props },
  ref,
) {
  return (
    <fieldset ref={ref} className={sx("sx-field-group", className)} data-sx-orientation={orientation} {...props}>
      <legend className="sx-field-group__legend">{legend}</legend>
      {description ? <p className="sx-field-group__description">{description}</p> : null}
      <div className="sx-field-group__content">{children}</div>
    </fieldset>
  );
});

export const ValidationMessage = forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(function ValidationMessage(
  { className, ...props },
  ref,
) {
  return <div ref={ref} className={sx("sx-validation-message", className)} role="alert" aria-live="polite" {...props} />;
});

export function useFieldControlProps<T extends { id?: string; disabled?: boolean; required?: boolean; "aria-invalid"?: AriaAttributes["aria-invalid"]; "aria-describedby"?: string }>(props: T): T {
  const field = useContext(FieldContext);
  if (!field) return props;
  return {
    ...props,
    id: props.id ?? field.controlId,
    disabled: props.disabled ?? field.disabled,
    required: props.required ?? field.required,
    "aria-invalid": props["aria-invalid"] ?? (field.invalid || undefined),
    "aria-describedby": composeIds(props["aria-describedby"], field.descriptionId, field.validationId),
  };
}

export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  sizeVariant?: SynexSize;
  leading?: ReactNode;
  trailing?: ReactNode;
}

export const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { sizeVariant = "md", leading, trailing, className, ...inputProps },
  ref,
) {
  const props = useFieldControlProps(inputProps);
  return (
    <div className={sx("sx-input-frame", className)} data-sx-size={sizeVariant} data-sx-disabled={props.disabled || undefined} data-sx-invalid={props["aria-invalid"] === true || props["aria-invalid"] === "true" || undefined}>
      {leading ? <span className="sx-input-frame__leading" aria-hidden="true">{leading}</span> : null}
      <input ref={ref} className="sx-input" {...props} />
      {trailing ? <span className="sx-input-frame__trailing">{trailing}</span> : null}
    </div>
  );
});

export type TextAreaProps = TextareaHTMLAttributes<HTMLTextAreaElement> & { resize?: "none" | "vertical" | "both" };

export const TextArea = forwardRef<HTMLTextAreaElement, TextAreaProps>(function TextArea(
  { resize = "vertical", className, ...textareaProps },
  ref,
) {
  const props = useFieldControlProps(textareaProps);
  return <textarea ref={ref} className={sx("sx-textarea", className)} data-sx-resize={resize} {...props} />;
});

export interface NumberInputProps extends Omit<InputProps, "type" | "onChange" | "value" | "defaultValue"> {
  value?: number;
  defaultValue?: number;
  onValueChange?: (value: number) => void;
  minimum?: number;
  maximum?: number;
  step?: number;
}

export const NumberInput = forwardRef<HTMLInputElement, NumberInputProps>(function NumberInput(
  { value, defaultValue = 0, onValueChange, minimum = Number.NEGATIVE_INFINITY, maximum = Number.POSITIVE_INFINITY, step = 1, className, disabled, ...props },
  ref,
) {
  const [current, setCurrent] = useControllableState({ value, defaultValue, onChange: onValueChange });
  const update = (next: number) => setCurrent(clamp(next, minimum, maximum));
  return (
    <div className={sx("sx-number-input", className)}>
      <Input
        {...props}
        ref={ref}
        type="number"
        value={current}
        min={Number.isFinite(minimum) ? minimum : undefined}
        max={Number.isFinite(maximum) ? maximum : undefined}
        step={step}
        disabled={disabled}
        aria-valuenow={current}
        onChange={(event) => {
          const parsed = event.currentTarget.valueAsNumber;
          if (!Number.isNaN(parsed)) update(parsed);
        }}
      />
      <div className="sx-number-input__steppers">
        <IconButton label="Increase value" size="sm" variant="quiet" icon={<span className="sx-icon sx-icon--plus" />} disabled={disabled || current >= maximum} onClick={() => update(current + step)} />
        <IconButton label="Decrease value" size="sm" variant="quiet" icon={<span className="sx-icon sx-icon--minus" />} disabled={disabled || current <= minimum} onClick={() => update(current - step)} />
      </div>
    </div>
  );
});

export type SearchInputProps = Omit<InputProps, "type"> & { onClear?: () => void; clearLabel?: string };

export const SearchInput = forwardRef<HTMLInputElement, SearchInputProps>(function SearchInput(
  { onClear, clearLabel = "Clear search", value, defaultValue, onChange, ...props },
  ref,
) {
  const [internalValue, setInternalValue] = useState(String(defaultValue ?? ""));
  const currentValue = value === undefined ? internalValue : String(value);
  return (
    <Input
      ref={ref}
      type="search"
      leading={<span className="sx-icon sx-icon--search" />}
      value={currentValue}
      onChange={(event) => {
        if (value === undefined) setInternalValue(event.currentTarget.value);
        onChange?.(event);
      }}
      trailing={onClear && currentValue.length > 0 ? <IconButton label={clearLabel} variant="quiet" size="sm" icon={<span className="sx-icon sx-icon--close" />} onClick={() => { if (value === undefined) setInternalValue(""); onClear(); }} /> : undefined}
      {...props}
    />
  );
});

export interface PasswordInputProps extends Omit<InputProps, "type"> {
  revealLabel?: string;
  concealLabel?: string;
}

export const PasswordInput = forwardRef<HTMLInputElement, PasswordInputProps>(function PasswordInput(
  { revealLabel = "Show password", concealLabel = "Hide password", ...props },
  ref,
) {
  const [revealed, setRevealed] = useControllableState({ defaultValue: false });
  return (
    <Input
      ref={ref}
      type={revealed ? "text" : "password"}
      trailing={<IconButton label={revealed ? concealLabel : revealLabel} variant="quiet" size="sm" icon={<span className={sx("sx-icon", revealed ? "sx-icon--eye-off" : "sx-icon--eye")} />} onClick={() => setRevealed(!revealed)} />}
      {...props}
    />
  );
});

export interface CheckboxProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "size"> {
  label?: ReactNode;
  description?: ReactNode;
  indeterminate?: boolean;
  size?: SynexSize;
}

export const Checkbox = forwardRef<HTMLInputElement, CheckboxProps>(function Checkbox(
  { label, description, indeterminate = false, size = "md", className, ...inputProps },
  ref,
) {
  const props = useFieldControlProps(inputProps);
  return (
    <label className={sx("sx-checkbox", className)} data-sx-size={size} data-sx-indeterminate={indeterminate || undefined}>
      <input ref={mergeRefs(ref, (node) => { if (node) node.indeterminate = indeterminate; })} type="checkbox" className="sx-checkbox__input" aria-checked={indeterminate ? "mixed" : undefined} {...props} />
      <span className="sx-checkbox__control" aria-hidden="true" />
      {label || description ? <span className="sx-checkbox__copy"><span className="sx-checkbox__label">{label}</span>{description ? <span className="sx-checkbox__description">{description}</span> : null}</span> : null}
    </label>
  );
});

export interface RadioProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "size"> {
  label?: ReactNode;
  description?: ReactNode;
  size?: SynexSize;
}

export const Radio = forwardRef<HTMLInputElement, RadioProps>(function Radio(
  { label, description, size = "md", className, ...inputProps },
  ref,
) {
  const props = useFieldControlProps(inputProps);
  return (
    <label className={sx("sx-radio", className)} data-sx-size={size}>
      <input ref={ref} type="radio" className="sx-radio__input" {...props} />
      <span className="sx-radio__control" aria-hidden="true" />
      {label || description ? <span className="sx-radio__copy"><span className="sx-radio__label">{label}</span>{description ? <span className="sx-radio__description">{description}</span> : null}</span> : null}
    </label>
  );
});

export interface SwitchProps extends Omit<HTMLAttributes<HTMLButtonElement>, "onChange"> {
  checked?: boolean;
  defaultChecked?: boolean;
  onCheckedChange?: (checked: boolean) => void;
  disabled?: boolean;
  required?: boolean;
  label: ReactNode;
  description?: ReactNode;
  name?: string;
  value?: string;
}

export const Switch = forwardRef<HTMLButtonElement, SwitchProps>(function Switch(
  { checked, defaultChecked = false, onCheckedChange, disabled = false, required = false, label, description, name, value = "on", className, onClick, ...props },
  ref,
) {
  const [current, setCurrent] = useControllableState({ value: checked, defaultValue: defaultChecked, onChange: onCheckedChange });
  const labelId = useStableId(undefined, "sx-switch-label");
  const descriptionId = `${labelId}-description`;
  return (
    <div className={sx("sx-switch-row", className)} data-sx-disabled={disabled || undefined}>
      <span className="sx-switch-row__copy"><span id={labelId} className="sx-switch-row__label">{label}</span>{description ? <span id={descriptionId} className="sx-switch-row__description">{description}</span> : null}</span>
      <button
        {...props}
        ref={ref}
        type="button"
        role="switch"
        className="sx-switch"
        aria-checked={current}
        aria-labelledby={props["aria-labelledby"] ?? (props["aria-label"] ? undefined : labelId)}
        aria-describedby={composeIds(props["aria-describedby"], description ? descriptionId : undefined)}
        aria-required={required || undefined}
        disabled={disabled}
        onClick={(event) => {
          onClick?.(event);
          if (!event.defaultPrevented) setCurrent(!current);
        }}
      ><span className="sx-switch__thumb" aria-hidden="true" /></button>
      {name ? <input type="hidden" name={name} value={value} disabled={!current} /> : null}
    </div>
  );
});

export interface SliderProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "value" | "defaultValue" | "onChange" | "size"> {
  value?: number;
  defaultValue?: number;
  onValueChange?: (value: number) => void;
  minimum?: number;
  maximum?: number;
  step?: number;
  showValue?: boolean;
  formatValue?: (value: number) => ReactNode;
}

export const Slider = forwardRef<HTMLInputElement, SliderProps>(function Slider(
  { value, defaultValue = 0, onValueChange, minimum = 0, maximum = 100, step = 1, showValue = false, formatValue = String, className, ...inputProps },
  ref,
) {
  const [current, setCurrent] = useControllableState({ value, defaultValue: clamp(defaultValue, minimum, maximum), onChange: onValueChange });
  const percent = maximum === minimum ? 0 : ((current - minimum) / (maximum - minimum)) * 100;
  const props = useFieldControlProps(inputProps);
  return (
    <div className={sx("sx-slider", className)} style={{ "--sx-slider-value": `${percent}%` } as React.CSSProperties}>
      <input
        ref={ref}
        type="range"
        className="sx-slider__input"
        min={minimum}
        max={maximum}
        step={step}
        value={current}
        onChange={(event: ChangeEvent<HTMLInputElement>) => setCurrent(event.currentTarget.valueAsNumber)}
        {...props}
      />
      {showValue ? <output className="sx-slider__value">{formatValue(current)}</output> : null}
    </div>
  );
});
