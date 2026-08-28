import {
  Children,
  cloneElement,
  isValidElement,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type HTMLAttributes,
  type KeyboardEvent,
  type MutableRefObject,
  type ReactElement,
  type ReactNode,
  type MouseEvent as ReactMouseEvent,
  type Ref,
} from "react";

export type SynexSize = "sm" | "md" | "lg";
export type SynexTone = "neutral" | "accent" | "positive" | "warning" | "danger" | "info";
export type SynexDensity = "compact" | "comfortable" | "spacious";
export type Orientation = "horizontal" | "vertical";
export type SynexSpacing = "2xs" | "xs" | "sm" | "md" | "lg" | "xl" | number | (string & {});

const namedSpacing: Record<string, string> = {
  "2xs": "var(--sx-space-1)",
  xs: "var(--sx-space-2)",
  sm: "var(--sx-space-3)",
  md: "var(--sx-space-4)",
  lg: "var(--sx-space-6)",
  xl: "var(--sx-space-8)",
};

export function spacingValue(value: SynexSpacing | undefined): string | undefined {
  if (typeof value === "number") return `${value}px`;
  if (value === undefined) return undefined;
  return namedSpacing[value] ?? value;
}

export function sx(...values: Array<string | false | null | undefined>): string {
  return values.filter(Boolean).join(" ");
}

export function composeIds(...ids: Array<string | undefined>): string | undefined {
  const value = ids.filter(Boolean).join(" ");
  return value.length > 0 ? value : undefined;
}

export function useStableId(explicit: string | undefined, prefix: string): string {
  const generated = useId();
  return explicit ?? `${prefix}-${generated.replaceAll(":", "")}`;
}

export function useControllableState<T>(options: {
  value?: T;
  defaultValue: T;
  onChange?: (value: T) => void;
}): [T, (value: T | ((current: T) => T)) => void] {
  const { value, defaultValue, onChange } = options;
  const [internal, setInternal] = useState(defaultValue);
  const controlled = value !== undefined;
  const current = controlled ? value : internal;
  const setCurrent = useCallback(
    (next: T | ((current: T) => T)) => {
      const resolved = typeof next === "function" ? (next as (current: T) => T)(current) : next;
      if (!controlled) setInternal(resolved);
      if (!Object.is(resolved, current)) onChange?.(resolved);
    },
    [controlled, current, onChange],
  );
  return [current, setCurrent];
}

export function useLatest<T>(value: T): MutableRefObject<T> {
  const ref = useRef(value);
  useLayoutEffect(() => {
    ref.current = value;
  }, [value]);
  return ref;
}

export function useOutsidePointer(
  refs: Array<MutableRefObject<HTMLElement | null>>,
  handler: (event: PointerEvent) => void,
  enabled = true,
): void {
  const latest = useLatest(handler);
  const latestRefs = useLatest(refs);
  useEffect(() => {
    if (!enabled) return;
    const onPointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (latestRefs.current.some((ref) => ref.current?.contains(target))) return;
      latest.current(event);
    };
    document.addEventListener("pointerdown", onPointerDown, true);
    return () => document.removeEventListener("pointerdown", onPointerDown, true);
  }, [enabled, latest, latestRefs]);
}

const FOCUSABLE = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled]):not([type='hidden'])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])",
].join(",");

export function focusableElements(container: HTMLElement): HTMLElement[] {
  return Array.from(container.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
    (element) => !element.hidden && element.getAttribute("aria-hidden") !== "true",
  );
}

export function useFocusTrap(
  containerRef: MutableRefObject<HTMLElement | null>,
  active: boolean,
  options: { initialFocusRef?: MutableRefObject<HTMLElement | null>; restore?: boolean } = {},
): void {
  const initialFocusRef = options.initialFocusRef;
  const restore = options.restore ?? true;
  useEffect(() => {
    if (!active) return;
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const container = containerRef.current;
    if (!container) return;
    const first = initialFocusRef?.current ?? focusableElements(container)[0] ?? container;
    queueMicrotask(() => first.focus({ preventScroll: true }));

    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Tab") return;
      const focusable = focusableElements(container);
      if (focusable.length === 0) {
        event.preventDefault();
        container.focus();
        return;
      }
      const firstItem = focusable[0];
      const lastItem = focusable.at(-1);
      if (event.shiftKey && document.activeElement === firstItem) {
        event.preventDefault();
        lastItem?.focus();
      } else if (!event.shiftKey && document.activeElement === lastItem) {
        event.preventDefault();
        firstItem?.focus();
      }
    };
    container.addEventListener("keydown", onKeyDown);
    return () => {
      container.removeEventListener("keydown", onKeyDown);
      if (restore && previous?.isConnected) previous.focus({ preventScroll: true });
    };
  }, [active, containerRef, initialFocusRef, restore]);
}

export function nextEnabledIndex(
  current: number,
  direction: 1 | -1,
  length: number,
  isDisabled: (index: number) => boolean,
  loop = true,
): number {
  if (length === 0) return -1;
  let candidate = current;
  for (let tries = 0; tries < length; tries += 1) {
    candidate += direction;
    if (loop) candidate = (candidate + length) % length;
    else if (candidate < 0 || candidate >= length) return current;
    if (!isDisabled(candidate)) return candidate;
  }
  return current;
}

export function rovingKey(
  event: KeyboardEvent,
  options: {
    current: number;
    length: number;
    orientation?: Orientation;
    isDisabled?: (index: number) => boolean;
    loop?: boolean;
  },
): number | null {
  const { current, length, orientation = "horizontal", isDisabled = () => false, loop = true } = options;
  const previousKeys = orientation === "horizontal" ? ["ArrowLeft"] : ["ArrowUp"];
  const nextKeys = orientation === "horizontal" ? ["ArrowRight"] : ["ArrowDown"];
  if (previousKeys.includes(event.key)) {
    event.preventDefault();
    return nextEnabledIndex(current, -1, length, isDisabled, loop);
  }
  if (nextKeys.includes(event.key)) {
    event.preventDefault();
    return nextEnabledIndex(current, 1, length, isDisabled, loop);
  }
  if (event.key === "Home") {
    event.preventDefault();
    for (let index = 0; index < length; index += 1) if (!isDisabled(index)) return index;
  }
  if (event.key === "End") {
    event.preventDefault();
    for (let index = length - 1; index >= 0; index -= 1) if (!isDisabled(index)) return index;
  }
  return null;
}

export function styleVars(values: Record<`--${string}`, string | number | undefined>): CSSProperties {
  const result: Record<string, string | number> = {};
  for (const [key, value] of Object.entries(values)) if (value !== undefined) result[key] = value;
  return result as CSSProperties;
}

export function mergeRefs<T>(...refs: Array<Ref<T> | undefined>): (value: T | null) => void {
  return (value) => {
    for (const ref of refs) {
      if (typeof ref === "function") ref(value);
      else if (ref) (ref as MutableRefObject<T | null>).current = value;
    }
  };
}

export function Slot({ children, ...props }: HTMLAttributes<HTMLElement> & { children: ReactNode }): ReactElement | null {
  const child = Children.only(children);
  if (!isValidElement<Record<string, unknown>>(child)) return null;
  const childClass = typeof child.props.className === "string" ? child.props.className : undefined;
  return cloneElement(child, {
    ...props,
    ...child.props,
    className: sx(props.className, childClass),
  });
}

interface InteractiveTriggerElementProps {
  onClick?: (event: ReactMouseEvent<HTMLElement>) => void;
  "aria-haspopup"?: "menu" | "listbox" | "tree" | "grid" | "dialog" | true | false;
  "aria-expanded"?: boolean;
  "aria-controls"?: string;
}

export function InteractiveTrigger({
  children,
  popup,
  expanded,
  controls,
  onActivate,
  className,
}: {
  children: ReactNode;
  popup: InteractiveTriggerElementProps["aria-haspopup"];
  expanded: boolean;
  controls?: string;
  onActivate: () => void;
  className?: string;
}): ReactElement {
  if (isValidElement<InteractiveTriggerElementProps & { className?: string }>(children)) {
    const original = children.props.onClick;
    return cloneElement(children, {
      "aria-haspopup": popup,
      "aria-expanded": expanded,
      "aria-controls": controls,
      className: sx(className, children.props.className),
      onClick: (event: ReactMouseEvent<HTMLElement>) => {
        original?.(event);
        if (!event.defaultPrevented) onActivate();
      },
    });
  }
  return <button type="button" className={className} aria-haspopup={popup} aria-expanded={expanded} aria-controls={controls} onClick={onActivate}>{children}</button>;
}

export function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}

export function normalizedText(value: ReactNode): string {
  if (typeof value === "string" || typeof value === "number") return String(value).toLocaleLowerCase();
  return "";
}

export function useDebouncedValue<T>(value: T, delay: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(value), delay);
    return () => window.clearTimeout(timer);
  }, [delay, value]);
  return debounced;
}

export function useObservedSize<T extends HTMLElement>(): {
  ref: MutableRefObject<T | null>;
  width: number;
  height: number;
} {
  const ref = useRef<T | null>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    const update = () => setSize({ width: element.clientWidth, height: element.clientHeight });
    update();
    if (typeof ResizeObserver === "undefined") {
      window.addEventListener("resize", update);
      return () => window.removeEventListener("resize", update);
    }
    const observer = new ResizeObserver(update);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  return useMemo(() => ({ ref, ...size }), [size]);
}
