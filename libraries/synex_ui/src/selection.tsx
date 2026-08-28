import {
  forwardRef,
  useEffect,
  useMemo,
  useRef,
  useState,
  type HTMLAttributes,
  type KeyboardEvent,
  type ReactNode,
  type SelectHTMLAttributes,
} from "react";
import { Checkbox, Input, SearchInput, useFieldControlProps } from "./forms.js";
import { normalizedText, rovingKey, sx, useControllableState, useOutsidePointer, useStableId } from "./internal.js";

export interface SelectOption<Value extends string = string> {
  value: Value;
  label: ReactNode;
  disabled?: boolean;
  description?: ReactNode;
  keywords?: readonly string[];
  textValue?: string;
}

function optionText<Value extends string>(option: SelectOption<Value>): string {
  if (option.textValue) return option.textValue;
  if (typeof option.label === "string" || typeof option.label === "number") return String(option.label);
  return option.value;
}

export interface SelectProps<Value extends string = string> extends Omit<SelectHTMLAttributes<HTMLSelectElement>, "value" | "defaultValue" | "onChange" | "size"> {
  options: readonly SelectOption<Value>[];
  value?: Value;
  defaultValue?: Value;
  onValueChange?: (value: Value) => void;
  placeholder?: string;
}

export function Select<Value extends string = string>({
  options,
  value,
  defaultValue,
  onValueChange,
  placeholder,
  className,
  ...props
}: SelectProps<Value>) {
  const controlProps = useFieldControlProps(props);
  return (
    <div className={sx("sx-select", className)} data-sx-invalid={controlProps["aria-invalid"] === true || controlProps["aria-invalid"] === "true" || undefined}>
      <select
        className="sx-select__control"
        value={value}
        defaultValue={defaultValue}
        onChange={(event) => onValueChange?.(event.currentTarget.value as Value)}
        {...controlProps}
      >
        {placeholder ? <option value="" disabled>{placeholder}</option> : null}
        {options.map((option) => <option key={option.value} value={option.value} disabled={option.disabled}>{optionText(option)}</option>)}
      </select>
      <span className="sx-select__indicator sx-icon sx-icon--chevron" aria-hidden="true" />
    </div>
  );
}

export interface ComboboxProps<Value extends string = string> extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
  options: readonly SelectOption<Value>[];
  value?: Value;
  defaultValue?: Value;
  onValueChange?: (value: Value) => void;
  query?: string;
  defaultQuery?: string;
  onQueryChange?: (query: string) => void;
  placeholder?: string;
  noResults?: ReactNode;
  filter?: (option: SelectOption<Value>, query: string) => boolean;
  disabled?: boolean;
  required?: boolean;
}

export function Combobox<Value extends string = string>({
  options,
  value,
  defaultValue,
  onValueChange,
  query,
  defaultQuery = "",
  onQueryChange,
  placeholder = "Search",
  noResults = "No matching options",
  filter,
  disabled = false,
  required = false,
  className,
  id: explicitId,
  "aria-label": ariaLabel,
  "aria-labelledby": ariaLabelledBy,
  "aria-invalid": ariaInvalid,
  "aria-describedby": ariaDescribedBy,
  ...props
}: ComboboxProps<Value>) {
  const id = useStableId(explicitId, "sx-combobox");
  const controlProps = useFieldControlProps({
    id,
    disabled,
    required,
    "aria-label": ariaLabel,
    "aria-labelledby": ariaLabelledBy,
    "aria-invalid": ariaInvalid,
    "aria-describedby": ariaDescribedBy,
  });
  const [selected, setSelected] = useControllableState({ value, defaultValue: defaultValue ?? ("" as Value), onChange: onValueChange });
  const [search, setSearch] = useControllableState({ value: query, defaultValue: defaultQuery, onChange: onQueryChange });
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const rootRef = useRef<HTMLDivElement | null>(null);
  useOutsidePointer([rootRef], () => setOpen(false), open);
  const visible = useMemo(() => {
    const needle = search.trim().toLocaleLowerCase();
    if (!needle) return options;
    return options.filter((option) => filter?.(option, search) ?? [normalizedText(option.label), option.value.toLocaleLowerCase(), ...(option.keywords ?? []).map((entry) => entry.toLocaleLowerCase())].some((entry) => entry.includes(needle)));
  }, [filter, options, search]);

  const select = (option: SelectOption<Value>) => {
    if (option.disabled) return;
    setSelected(option.value);
    setSearch(optionText(option));
    setOpen(false);
    inputRef.current?.focus();
  };
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      setOpen(true);
      const direction = event.key === "ArrowDown" ? 1 : -1;
      const next = rovingKey(event, { current: active, length: visible.length, orientation: "vertical", isDisabled: (index) => visible[index]?.disabled === true });
      if (next !== null) setActive(next);
      else if (visible.length > 0) setActive(direction === 1 ? 0 : visible.length - 1);
    } else if (event.key === "Enter" && open) {
      event.preventDefault();
      const option = visible[active];
      if (option) select(option);
    } else if (event.key === "Escape") {
      event.preventDefault();
      setOpen(false);
    }
  };

  return (
    <div ref={rootRef} className={sx("sx-combobox", className)} data-sx-open={open || undefined} data-sx-invalid={controlProps["aria-invalid"] === true || controlProps["aria-invalid"] === "true" || undefined} {...props}>
      <Input
        ref={inputRef}
        role="combobox"
        aria-autocomplete="list"
        aria-expanded={open}
        aria-controls={`${id}-listbox`}
        aria-activedescendant={open && visible[active] ? `${id}-option-${active}` : undefined}
        value={search}
        placeholder={placeholder}
        {...controlProps}
        onFocus={() => setOpen(true)}
        onChange={(event) => {
          setSearch(event.currentTarget.value);
          setOpen(true);
          setActive(0);
        }}
        onKeyDown={onKeyDown}
      />
      <input type="hidden" value={selected} readOnly />
      {open ? (
        <div id={`${id}-listbox`} className="sx-combobox__list" role="listbox">
          {visible.length === 0 ? <div className="sx-combobox__empty">{noResults}</div> : visible.map((option, index) => (
            <button
              key={option.value}
              id={`${id}-option-${index}`}
              type="button"
              role="option"
              tabIndex={-1}
              className="sx-combobox__option"
              aria-selected={selected === option.value}
              data-sx-active={active === index || undefined}
              disabled={option.disabled}
              onPointerMove={() => setActive(index)}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => select(option)}
            >
              <span className="sx-combobox__option-label">{option.label}</span>
              {option.description ? <span className="sx-combobox__option-description">{option.description}</span> : null}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

export type SearchSelectProps<Value extends string = string> = ComboboxProps<Value> & {
  minimumQueryLength?: number;
};

export function SearchSelect<Value extends string = string>({ minimumQueryLength = 0, filter, ...props }: SearchSelectProps<Value>) {
  return <Combobox {...props} filter={(option, query) => query.length >= minimumQueryLength && (filter?.(option, query) ?? [normalizedText(option.label), option.value.toLocaleLowerCase(), ...(option.keywords ?? [])].join(" ").includes(query.toLocaleLowerCase()))} />;
}

export interface MultiSelectProps<Value extends string = string> extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
  options: readonly SelectOption<Value>[];
  value?: readonly Value[];
  defaultValue?: readonly Value[];
  onValueChange?: (values: readonly Value[]) => void;
  placeholder?: string;
  searchPlaceholder?: string;
  disabled?: boolean;
  required?: boolean;
}

export function MultiSelect<Value extends string = string>({
  options,
  value,
  defaultValue = [],
  onValueChange,
  placeholder = "Select options",
  searchPlaceholder = "Filter options",
  disabled = false,
  required = false,
  className,
  id: explicitId,
  "aria-label": ariaLabel,
  "aria-labelledby": ariaLabelledBy,
  "aria-invalid": ariaInvalid,
  "aria-describedby": ariaDescribedBy,
  onKeyDown: onRootKeyDown,
  ...props
}: MultiSelectProps<Value>) {
  const id = useStableId(explicitId, "sx-multiselect");
  const controlProps = useFieldControlProps({
    id,
    disabled,
    required,
    "aria-invalid": ariaInvalid,
    "aria-describedby": ariaDescribedBy,
  });
  const [selected, setSelected] = useControllableState<readonly Value[]>({ value, defaultValue, onChange: onValueChange });
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const searchRef = useRef<HTMLInputElement | null>(null);
  useOutsidePointer([rootRef], () => setOpen(false), open);
  useEffect(() => {
    if (open) searchRef.current?.focus();
  }, [open]);
  const visible = options.filter((option) => [normalizedText(option.label), option.value, ...(option.keywords ?? [])].join(" ").toLocaleLowerCase().includes(query.toLocaleLowerCase()));
  const toggle = (option: SelectOption<Value>) => {
    if (option.disabled) return;
    setSelected(selected.includes(option.value) ? selected.filter((value) => value !== option.value) : [...selected, option.value]);
  };
  return (
    <div
      ref={rootRef}
      className={sx("sx-multi-select", className)}
      data-sx-open={open || undefined}
      data-sx-invalid={controlProps["aria-invalid"] === true || controlProps["aria-invalid"] === "true" || undefined}
      {...props}
      onKeyDown={(event) => {
        onRootKeyDown?.(event);
        if (event.defaultPrevented || event.key !== "Escape" || !open) return;
        event.preventDefault();
        event.stopPropagation();
        setOpen(false);
        queueMicrotask(() => triggerRef.current?.focus());
      }}
    >
      <button ref={triggerRef} type="button" id={controlProps.id} className="sx-multi-select__trigger" aria-label={ariaLabel} aria-labelledby={ariaLabelledBy} aria-haspopup="dialog" aria-expanded={open} aria-controls={`${id}-popover`} aria-describedby={controlProps["aria-describedby"]} aria-invalid={controlProps["aria-invalid"]} aria-required={controlProps.required || undefined} disabled={controlProps.disabled} onClick={() => setOpen(!open)}>
        <span className="sx-multi-select__summary">{selected.length === 0 ? placeholder : `${selected.length} selected`}</span>
        <span className="sx-icon sx-icon--chevron" aria-hidden="true" />
      </button>
      {open ? (
        <div id={`${id}-popover`} className="sx-multi-select__popover" role="dialog" aria-label={ariaLabel ?? placeholder} aria-labelledby={ariaLabelledBy}>
          <SearchInput ref={searchRef} value={query} placeholder={searchPlaceholder} aria-label={searchPlaceholder} onChange={(event) => setQuery(event.currentTarget.value)} onClear={() => setQuery("")} />
          <div className="sx-multi-select__list" role="group" aria-label="Options">
            {visible.map((option) => (
              <Checkbox
                key={option.value}
                label={option.label}
                description={option.description}
                checked={selected.includes(option.value)}
                disabled={option.disabled}
                onChange={() => toggle(option)}
              />
            ))}
          </div>
        </div>
      ) : null}
    </div>
  );
}

export interface SegmentOption<Value extends string = string> {
  value: Value;
  label: ReactNode;
  disabled?: boolean;
  icon?: ReactNode;
}

export interface SegmentedControlProps<Value extends string = string> extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
  options: readonly SegmentOption<Value>[];
  value?: Value;
  defaultValue?: Value;
  onValueChange?: (value: Value) => void;
  label: string;
}

export function SegmentedControl<Value extends string = string>({ options, value, defaultValue, onValueChange, label, className, ...props }: SegmentedControlProps<Value>) {
  const fallback = defaultValue ?? options.find((option) => !option.disabled)?.value ?? ("" as Value);
  const [selected, setSelected] = useControllableState({ value, defaultValue: fallback, onChange: onValueChange });
  const refs = useRef<Array<HTMLButtonElement | null>>([]);
  const selectedIndex = Math.max(0, options.findIndex((option) => option.value === selected));
  const activate = (index: number) => {
    const option = options[index];
    if (!option || option.disabled) return;
    setSelected(option.value);
    refs.current[index]?.focus();
  };
  return (
    <div className={sx("sx-segmented-control", className)} role="radiogroup" aria-label={label} {...props}>
      {options.map((option, index) => (
        <button
          key={option.value}
          ref={(node) => { refs.current[index] = node; }}
          type="button"
          role="radio"
          className="sx-segmented-control__item"
          aria-checked={option.value === selected}
          disabled={option.disabled}
          tabIndex={index === selectedIndex ? 0 : -1}
          onClick={() => activate(index)}
          onKeyDown={(event) => {
            const next = rovingKey(event, { current: index, length: options.length, isDisabled: (candidate) => options[candidate]?.disabled === true });
            if (next !== null) activate(next);
          }}
        >
          {option.icon ? <span className="sx-segmented-control__icon" aria-hidden="true">{option.icon}</span> : null}
          <span>{option.label}</span>
        </button>
      ))}
    </div>
  );
}
