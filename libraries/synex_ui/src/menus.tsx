import {
  forwardRef,
  useEffect,
  useRef,
  useState,
  type HTMLAttributes,
  type ReactNode,
} from "react";
import { IconButton } from "./actions.js";
import { KeyHint } from "./utilities.js";
import { InteractiveTrigger, rovingKey, styleVars, sx, useControllableState, useOutsidePointer, useStableId } from "./internal.js";

export type MenuItem =
  | { type?: "action"; id: string; label: ReactNode; icon?: ReactNode; hint?: string; disabled?: boolean; danger?: boolean; onSelect: () => void }
  | { type: "checkbox"; id: string; label: ReactNode; checked: boolean; disabled?: boolean; onCheckedChange: (checked: boolean) => void }
  | { type: "radio"; id: string; label: ReactNode; value: string; selectedValue: string; disabled?: boolean; onValueChange: (value: string) => void }
  | { type: "label"; id: string; label: ReactNode }
  | { type: "separator"; id: string }
  | { type: "submenu"; id: string; label: ReactNode; icon?: ReactNode; disabled?: boolean; items: readonly MenuItem[] };

function isDisabled(item: MenuItem): boolean {
  return item.type === "separator" || item.type === "label" || item.disabled === true;
}

export interface MenuProps extends HTMLAttributes<HTMLDivElement> {
  items: readonly MenuItem[];
  label?: string;
  onClose?: () => void;
  initialActiveId?: string;
  autoFocus?: boolean;
}

export const Menu = forwardRef<HTMLDivElement, MenuProps>(function Menu(
  { items, label = "Menu", onClose, initialActiveId, autoFocus = true, className, onKeyDown, ...props },
  ref,
) {
  const requestedInitial = items.findIndex((item) => item.id === initialActiveId && !isDisabled(item));
  const firstEnabled = items.findIndex((item) => !isDisabled(item));
  const initial = requestedInitial >= 0 ? requestedInitial : Math.max(0, firstEnabled);
  const [active, setActive] = useState(initial);
  const itemRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const didAutoFocus = useRef(false);
  const [submenuId, setSubmenuId] = useState<string | null>(null);
  useEffect(() => {
    if (!autoFocus || didAutoFocus.current) return;
    const preferred = !isDisabled(items[active] ?? { type: "separator", id: "none" }) ? active : items.findIndex((item) => !isDisabled(item));
    if (preferred >= 0) {
      didAutoFocus.current = true;
      queueMicrotask(() => itemRefs.current[preferred]?.focus());
    }
  }, [autoFocus, items]);
  useEffect(() => {
    const first = items.findIndex((item) => !isDisabled(item));
    if (isDisabled(items[active] ?? { type: "separator", id: "none" })) setActive(Math.max(0, first));
  }, [active, items]);
  const move = (next: number) => {
    setActive(next);
    itemRefs.current[next]?.focus();
  };
  const select = (item: MenuItem) => {
    if (isDisabled(item)) return;
    if (item.type === "separator") return;
    if (item.type === "checkbox") item.onCheckedChange(!item.checked);
    else if (item.type === "radio") item.onValueChange(item.value);
    else if (item.type === "submenu") {
      setSubmenuId(submenuId === item.id ? null : item.id);
      return;
    } else if (item.type === "action" || item.type === undefined) item.onSelect();
    onClose?.();
  };
  return (
    <div
      ref={ref}
      role="menu"
      aria-label={label}
      className={sx("sx-menu", className)}
      tabIndex={-1}
      onKeyDown={(event) => {
        onKeyDown?.(event);
        if (event.defaultPrevented) return;
        const next = rovingKey(event, { current: active, length: items.length, orientation: "vertical", isDisabled: (index) => isDisabled(items[index] ?? { type: "separator", id: "missing" }) });
        if (next !== null) {
          event.stopPropagation();
          move(next);
        }
        else if (event.key === "Escape" || event.key === "ArrowLeft") {
          if (onClose) {
            event.preventDefault();
            event.stopPropagation();
            onClose();
          }
        } else if ((event.key === "Enter" || event.key === " ") && items[active]) {
          event.preventDefault();
          event.stopPropagation();
          select(items[active]);
        } else if (event.key === "ArrowRight" && items[active]?.type === "submenu") {
          event.preventDefault();
          event.stopPropagation();
          setSubmenuId(items[active].id);
        }
      }}
      {...props}
    >
      {items.map((item, index) => {
        if (item.type === "separator") return <div key={item.id} role="separator" className="sx-menu__separator" />;
        if (item.type === "label") return <div key={item.id} role="presentation" className="sx-menu__label">{item.label}</div>;
        const checked = item.type === "checkbox" ? item.checked : item.type === "radio" ? item.value === item.selectedValue : undefined;
        const role = item.type === "checkbox" ? "menuitemcheckbox" : item.type === "radio" ? "menuitemradio" : "menuitem";
        const open = item.type === "submenu" && submenuId === item.id;
        return (
          <div key={item.id} className="sx-menu__entry" data-sx-submenu-open={open || undefined}>
            <button
              ref={(node) => { itemRefs.current[index] = node; }}
              type="button"
              role={role}
              className="sx-menu__item"
              tabIndex={active === index ? 0 : -1}
              disabled={item.disabled}
              aria-checked={checked}
              aria-haspopup={item.type === "submenu" ? "menu" : undefined}
              aria-expanded={item.type === "submenu" ? open : undefined}
              data-sx-danger={item.type === "action" && item.danger || undefined}
              onFocus={() => setActive(index)}
              onPointerMove={() => { if (!item.disabled) setActive(index); }}
              onClick={() => select(item)}
            >
              {item.type === "checkbox" || item.type === "radio" ? <span className="sx-menu__check" aria-hidden="true">{checked ? <span className="sx-icon sx-icon--check" /> : null}</span> : "icon" in item && item.icon ? <span className="sx-menu__icon" aria-hidden="true">{item.icon}</span> : <span className="sx-menu__icon" />}
              <span className="sx-menu__label">{item.label}</span>
              {item.type === "action" && item.hint ? <KeyHint>{item.hint}</KeyHint> : null}
              {item.type === "submenu" ? <span className="sx-icon sx-icon--next" aria-hidden="true" /> : null}
            </button>
            {open && item.type === "submenu" ? (
              <Submenu
                items={item.items}
                label={`${label} submenu`}
                onClose={() => {
                  setSubmenuId(null);
                  queueMicrotask(() => itemRefs.current[index]?.focus());
                }}
              />
            ) : null}
          </div>
        );
      })}
    </div>
  );
});

export interface SubmenuProps extends MenuProps {
  placement?: "right-start" | "left-start";
}

export const Submenu = forwardRef<HTMLDivElement, SubmenuProps>(function Submenu(
  { placement = "right-start", className, ...props },
  ref,
) {
  return <Menu ref={ref} className={sx("sx-submenu", className)} data-sx-placement={placement} {...props} />;
});

export interface DropdownProps extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
  trigger: ReactNode;
  items: readonly MenuItem[];
  label?: string;
  open?: boolean;
  defaultOpen?: boolean;
  onOpenChange?: (open: boolean) => void;
  align?: "start" | "end";
}

export const Dropdown = forwardRef<HTMLDivElement, DropdownProps>(function Dropdown(
  { trigger, items, label, open, defaultOpen = false, onOpenChange, align = "end", className, ...props },
  ref,
) {
  const [visible, setVisible] = useControllableState({ value: open, defaultValue: defaultOpen, onChange: onOpenChange });
  const root = useRef<HTMLDivElement | null>(null);
  const menuId = useStableId(undefined, "sx-dropdown-menu");
  useOutsidePointer([root], () => setVisible(false), visible);
  const closeAndRestore = () => {
    setVisible(false);
    queueMicrotask(() => root.current?.querySelector<HTMLElement>(`[aria-controls="${menuId}"]`)?.focus());
  };
  return (
    <div ref={(node) => { root.current = node; if (typeof ref === "function") ref(node); else if (ref) ref.current = node; }} className={sx("sx-dropdown", className)} data-sx-open={visible || undefined} {...props}>
      <InteractiveTrigger className="sx-dropdown__trigger" popup="menu" expanded={visible} controls={menuId} onActivate={() => setVisible(!visible)}>{trigger}</InteractiveTrigger>
      {visible ? <Menu id={menuId} className="sx-dropdown__menu" data-sx-align={align} items={items} label={label} onClose={closeAndRestore} /> : null}
    </div>
  );
});

export interface ContextMenuProps extends Omit<HTMLAttributes<HTMLDivElement>, "onContextMenu"> {
  items: readonly MenuItem[];
  label?: string;
}

export const ContextMenu = forwardRef<HTMLDivElement, ContextMenuProps>(function ContextMenu(
  { items, label = "Context menu", className, children, onKeyDown, tabIndex, ...props },
  ref,
) {
  const [position, setPosition] = useState<{ x: number; y: number } | null>(null);
  const root = useRef<HTMLDivElement | null>(null);
  const menu = useRef<HTMLDivElement | null>(null);
  useOutsidePointer([root, menu], () => setPosition(null), position !== null);
  const openAt = (x: number, y: number) => setPosition({
    x: Math.max(8, Math.min(x, window.innerWidth - 240)),
    y: Math.max(8, Math.min(y, window.innerHeight - 320)),
  });
  const closeAndRestore = () => {
    setPosition(null);
    queueMicrotask(() => root.current?.focus());
  };
  return (
    <div
      ref={(node) => { root.current = node; if (typeof ref === "function") ref(node); else if (ref) ref.current = node; }}
      className={sx("sx-context-menu", className)}
      tabIndex={tabIndex ?? 0}
      aria-haspopup="menu"
      aria-expanded={position !== null}
      onContextMenu={(event) => {
        event.preventDefault();
        openAt(event.clientX, event.clientY);
      }}
      onKeyDown={(event) => {
        onKeyDown?.(event);
        if (event.defaultPrevented) return;
        if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
          event.preventDefault();
          const bounds = event.currentTarget.getBoundingClientRect();
          openAt(bounds.left + Math.min(bounds.width / 2, 120), bounds.top + Math.min(bounds.height / 2, 48));
        } else if (event.key === "Escape" && position !== null) {
          event.preventDefault();
          closeAndRestore();
        }
      }}
      {...props}
    >
      {children}
      {position ? (
        <div className="sx-context-menu__layer" style={styleVars({ "--sx-context-x": `${position.x}px`, "--sx-context-y": `${position.y}px` })}>
          <Menu ref={menu} items={items} label={label} onClose={closeAndRestore} />
        </div>
      ) : null}
    </div>
  );
});

export interface ActionMenuProps extends Omit<DropdownProps, "trigger"> {
  triggerLabel?: string;
  trigger?: ReactNode;
}

export function ActionMenu({ triggerLabel = "Actions", trigger, ...props }: ActionMenuProps) {
  return <Dropdown {...props} trigger={trigger ?? <IconButton label={triggerLabel} variant="quiet" icon={<span className="sx-icon sx-icon--more" />} />} />;
}
