import {
  forwardRef,
  useRef,
  type ButtonHTMLAttributes,
  type HTMLAttributes,
  type ReactNode,
} from "react";
import { Button, IconButton } from "./actions.js";
import { rovingKey, sx, useControllableState, useStableId, type Orientation } from "./internal.js";

export interface TabItem<Value extends string = string> {
  value: Value;
  label: ReactNode;
  content: ReactNode;
  disabled?: boolean;
  badge?: ReactNode;
}

export interface TabsProps<Value extends string = string> extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
  items: readonly TabItem<Value>[];
  value?: Value;
  defaultValue?: Value;
  onValueChange?: (value: Value) => void;
  orientation?: Orientation;
  activation?: "automatic" | "manual";
  label?: string;
}

export function Tabs<Value extends string = string>({
  items,
  value,
  defaultValue,
  onValueChange,
  orientation = "horizontal",
  activation = "automatic",
  label,
  className,
  ...props
}: TabsProps<Value>) {
  const id = useStableId(undefined, "sx-tabs");
  const fallback = defaultValue ?? items.find((item) => !item.disabled)?.value ?? ("" as Value);
  const [selected, setSelected] = useControllableState({ value, defaultValue: fallback, onChange: onValueChange });
  const refs = useRef<Array<HTMLButtonElement | null>>([]);
  const selectedIndex = Math.max(0, items.findIndex((item) => item.value === selected));
  const focus = (index: number, activate: boolean) => {
    const item = items[index];
    if (!item || item.disabled) return;
    refs.current[index]?.focus();
    if (activate) setSelected(item.value);
  };
  const panel = items.find((item) => item.value === selected);
  return (
    <div className={sx("sx-tabs", className)} data-sx-orientation={orientation} {...props}>
      <div role="tablist" className="sx-tabs__list" aria-label={label} aria-orientation={orientation}>
        {items.map((item, index) => (
          <button
            key={item.value}
            ref={(node) => { refs.current[index] = node; }}
            id={`${id}-tab-${index}`}
            type="button"
            role="tab"
            className="sx-tabs__tab"
            aria-selected={selected === item.value}
            aria-controls={`${id}-panel-${index}`}
            disabled={item.disabled}
            tabIndex={index === selectedIndex ? 0 : -1}
            onClick={() => setSelected(item.value)}
            onKeyDown={(event) => {
              const next = rovingKey(event, { current: index, length: items.length, orientation, isDisabled: (candidate) => items[candidate]?.disabled === true });
              if (next !== null) focus(next, activation === "automatic");
              if ((event.key === "Enter" || event.key === " ") && activation === "manual") {
                event.preventDefault();
                setSelected(item.value);
              }
            }}
          >
            <span>{item.label}</span>{item.badge ? <span className="sx-tabs__badge">{item.badge}</span> : null}
          </button>
        ))}
      </div>
      {panel ? (
        <div id={`${id}-panel-${selectedIndex}`} role="tabpanel" className="sx-tabs__panel" aria-labelledby={`${id}-tab-${selectedIndex}`} tabIndex={0}>
          {panel.content}
        </div>
      ) : null}
    </div>
  );
}

export interface BreadcrumbItem {
  label: ReactNode;
  href?: string;
  onClick?: () => void;
}

export interface BreadcrumbProps extends HTMLAttributes<HTMLElement> {
  items: readonly BreadcrumbItem[];
  label?: string;
  separator?: ReactNode;
}

export const Breadcrumb = forwardRef<HTMLElement, BreadcrumbProps>(function Breadcrumb(
  { items, label = "Breadcrumb", separator = <span className="sx-icon sx-icon--chevron" />, className, ...props },
  ref,
) {
  return (
    <nav ref={ref} className={sx("sx-breadcrumb", className)} aria-label={label} {...props}>
      <ol className="sx-breadcrumb__list">
        {items.map((item, index) => {
          const current = index === items.length - 1;
          return (
            <li key={index} className="sx-breadcrumb__item">
              {index > 0 ? <span className="sx-breadcrumb__separator" aria-hidden="true">{separator}</span> : null}
              {current ? <span aria-current="page">{item.label}</span> : item.href ? <a href={item.href} onClick={item.onClick}>{item.label}</a> : <button type="button" onClick={item.onClick}>{item.label}</button>}
            </li>
          );
        })}
      </ol>
    </nav>
  );
});

export interface PaginationProps extends HTMLAttributes<HTMLElement> {
  page: number;
  pageCount: number;
  onPageChange: (page: number) => void;
  siblingCount?: number;
  label?: string;
}

export const Pagination = forwardRef<HTMLElement, PaginationProps>(function Pagination(
  { page, pageCount, onPageChange, siblingCount = 1, label = "Pagination", className, ...props },
  ref,
) {
  const normalized = Math.min(pageCount, Math.max(1, page));
  const pages = Array.from({ length: pageCount }, (_, index) => index + 1).filter((entry) => entry === 1 || entry === pageCount || Math.abs(entry - normalized) <= siblingCount);
  const sequence: Array<number | "ellipsis"> = [];
  for (const entry of pages) {
    const previous = sequence.at(-1);
    if (typeof previous === "number" && entry - previous > 1) sequence.push("ellipsis");
    sequence.push(entry);
  }
  return (
    <nav ref={ref} className={sx("sx-pagination", className)} aria-label={label} {...props}>
      <IconButton label="Previous page" variant="quiet" icon={<span className="sx-icon sx-icon--previous" />} disabled={normalized <= 1} onClick={() => onPageChange(normalized - 1)} />
      <ol className="sx-pagination__pages">
        {sequence.map((entry, index) => entry === "ellipsis"
          ? <li key={`ellipsis-${index}`} className="sx-pagination__ellipsis" aria-hidden="true">…</li>
          : <li key={entry}><Button variant={entry === normalized ? "primary" : "quiet"} aria-current={entry === normalized ? "page" : undefined} aria-label={`Page ${entry}`} onClick={() => onPageChange(entry)}>{entry}</Button></li>)}
      </ol>
      <IconButton label="Next page" variant="quiet" icon={<span className="sx-icon sx-icon--next" />} disabled={normalized >= pageCount} onClick={() => onPageChange(normalized + 1)} />
    </nav>
  );
});

export interface StepItem<Value extends string = string> {
  value: Value;
  label: ReactNode;
  description?: ReactNode;
  optional?: boolean;
  disabled?: boolean;
}

export interface StepperProps<Value extends string = string> extends Omit<HTMLAttributes<HTMLOListElement>, "onChange"> {
  steps: readonly StepItem<Value>[];
  value: Value;
  completed?: readonly Value[];
  onValueChange?: (value: Value) => void;
  orientation?: Orientation;
}

export function Stepper<Value extends string = string>({ steps, value, completed = [], onValueChange, orientation = "horizontal", className, ...props }: StepperProps<Value>) {
  return (
    <ol className={sx("sx-stepper", className)} data-sx-orientation={orientation} {...props}>
      {steps.map((step, index) => {
        const current = value === step.value;
        const done = completed.includes(step.value);
        return (
          <li key={step.value} className="sx-stepper__step" data-sx-state={current ? "current" : done ? "complete" : "pending"}>
            <button type="button" className="sx-stepper__trigger" aria-current={current ? "step" : undefined} disabled={step.disabled || !onValueChange} onClick={() => onValueChange?.(step.value)}>
              <span className="sx-stepper__index" aria-hidden="true">{done ? <span className="sx-icon sx-icon--check" /> : index + 1}</span>
              <span className="sx-stepper__copy"><span className="sx-stepper__label">{step.label}{step.optional ? <span className="sx-stepper__optional"> Optional</span> : null}</span>{step.description ? <span className="sx-stepper__description">{step.description}</span> : null}</span>
            </button>
          </li>
        );
      })}
    </ol>
  );
}

export interface SideNavItem {
  id: string;
  label: ReactNode;
  icon?: ReactNode;
  href?: string;
  disabled?: boolean;
  badge?: ReactNode;
  children?: readonly SideNavItem[];
}

export interface SideNavProps extends HTMLAttributes<HTMLElement> {
  items: readonly SideNavItem[];
  activeId?: string;
  onNavigate?: (item: SideNavItem) => void;
  label?: string;
  collapsed?: boolean;
}

function SideNavEntry({ item, activeId, onNavigate, depth }: { item: SideNavItem; activeId?: string; onNavigate?: (item: SideNavItem) => void; depth: number }) {
  const active = item.id === activeId;
  const content = <><span className="sx-side-nav__icon" aria-hidden="true">{item.icon}</span><span className="sx-side-nav__label">{item.label}</span>{item.badge ? <span className="sx-side-nav__badge">{item.badge}</span> : null}</>;
  const common: ButtonHTMLAttributes<HTMLButtonElement> = { disabled: item.disabled, "aria-current": active ? "page" : undefined };
  return (
    <li className="sx-side-nav__item" data-sx-depth={depth}>
      {item.href ? <a className="sx-side-nav__link" href={item.href} aria-current={active ? "page" : undefined} aria-disabled={item.disabled || undefined} onClick={(event) => { if (item.disabled) event.preventDefault(); else onNavigate?.(item); }}>{content}</a> : <button {...common} type="button" className="sx-side-nav__link" onClick={() => onNavigate?.(item)}>{content}</button>}
      {item.children?.length ? <ul className="sx-side-nav__group">{item.children.map((child) => <SideNavEntry key={child.id} item={child} activeId={activeId} onNavigate={onNavigate} depth={depth + 1} />)}</ul> : null}
    </li>
  );
}

export const SideNav = forwardRef<HTMLElement, SideNavProps>(function SideNav(
  { items, activeId, onNavigate, label = "Navigation", collapsed = false, className, ...props },
  ref,
) {
  return <nav ref={ref} className={sx("sx-side-nav", className)} aria-label={label} data-sx-collapsed={collapsed || undefined} {...props}><ul className="sx-side-nav__list">{items.map((item) => <SideNavEntry key={item.id} item={item} activeId={activeId} onNavigate={onNavigate} depth={0} />)}</ul></nav>;
});
