import {
  cloneElement,
  forwardRef,
  isValidElement,
  useEffect,
  useRef,
  useState,
  type HTMLAttributes,
  type ReactNode,
  type SVGAttributes,
} from "react";
import { composeIds, sx, useStableId, type SynexSize, type SynexTone } from "./internal.js";

export interface TooltipProps extends Omit<HTMLAttributes<HTMLSpanElement>, "content"> {
  content: ReactNode;
  placement?: "top" | "right" | "bottom" | "left";
  delay?: number;
  disabled?: boolean;
}

export const Tooltip = forwardRef<HTMLSpanElement, TooltipProps>(function Tooltip(
  { content, placement = "top", delay = 250, disabled = false, className, children, ...props },
  ref,
) {
  const id = useStableId(undefined, "sx-tooltip");
  const [visible, setVisible] = useState(false);
  const timer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  useEffect(() => {
    if (!disabled) return;
    window.clearTimeout(timer.current);
    setVisible(false);
  }, [disabled]);
  const show = () => {
    if (disabled) return;
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setVisible(true), delay);
  };
  const hide = () => {
    window.clearTimeout(timer.current);
    setVisible(false);
  };
  const anchor = isValidElement<{ "aria-describedby"?: string }>(children)
    ? cloneElement(children, { "aria-describedby": composeIds(children.props["aria-describedby"], visible ? id : undefined) })
    : <span className="sx-tooltip__fallback-anchor" tabIndex={0} aria-describedby={visible ? id : undefined}>{children}</span>;
  return (
    <span ref={ref} className={sx("sx-tooltip", className)} data-sx-open={visible || undefined} onPointerEnter={show} onPointerLeave={hide} onFocus={show} onBlur={hide} {...props}>
      <span className="sx-tooltip__anchor">{anchor}</span>
      {visible ? <span id={id} role="tooltip" className="sx-tooltip__content" data-sx-placement={placement}>{content}</span> : null}
    </span>
  );
});

export const KeyHint = forwardRef<HTMLElement, HTMLAttributes<HTMLElement>>(function KeyHint(
  { className, ...props },
  ref,
) {
  return <kbd ref={ref} className={sx("sx-key-hint", className)} {...props} />;
});

export interface ShortcutProps extends HTMLAttributes<HTMLSpanElement> {
  keys: readonly string[];
  separator?: ReactNode;
  label?: string;
}

export const Shortcut = forwardRef<HTMLSpanElement, ShortcutProps>(function Shortcut(
  { keys, separator = "+", label, className, ...props },
  ref,
) {
  return <span ref={ref} className={sx("sx-shortcut", className)} aria-label={label ?? keys.join(" plus ")} {...props}>{keys.map((key, index) => <span key={`${key}-${index}`} className="sx-shortcut__part">{index > 0 ? <span className="sx-shortcut__separator" aria-hidden="true">{separator}</span> : null}<KeyHint>{key}</KeyHint></span>)}</span>;
});

export type SynexIconName =
  | "check"
  | "close"
  | "chevron-down"
  | "chevron-right"
  | "arrow-left"
  | "arrow-right"
  | "search"
  | "plus"
  | "minus"
  | "more"
  | "copy"
  | "eye"
  | "eye-off"
  | "info"
  | "warning"
  | "error"
  | "success"
  | "menu"
  | "command"
  | "signal";

const iconPaths: Record<SynexIconName, readonly string[]> = {
  check: ["M5 12.5l4.2 4.2L19 6.9"],
  close: ["M6 6l12 12", "M18 6L6 18"],
  "chevron-down": ["M6.5 9l5.5 5.5L17.5 9"],
  "chevron-right": ["M9 6.5l5.5 5.5L9 17.5"],
  "arrow-left": ["M19 12H5", "M11 6l-6 6 6 6"],
  "arrow-right": ["M5 12h14", "M13 6l6 6-6 6"],
  search: ["M10.5 18a7.5 7.5 0 1 1 0-15 7.5 7.5 0 0 1 0 15Z", "m16 16 5 5"],
  plus: ["M12 5v14", "M5 12h14"],
  minus: ["M5 12h14"],
  more: ["M6 12h.01", "M12 12h.01", "M18 12h.01"],
  copy: ["M9 8h10v11H9z", "M5 16V5h10"],
  eye: ["M2.5 12s3.5-6 9.5-6 9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6Z", "M12 9a3 3 0 1 1 0 6 3 3 0 0 1 0-6Z"],
  "eye-off": ["M4 4l16 16", "M9.5 6.4A10.9 10.9 0 0 1 12 6c6 0 9.5 6 9.5 6a13 13 0 0 1-2.4 3.1", "M6.2 7.3A13.5 13.5 0 0 0 2.5 12s3.5 6 9.5 6c1 0 2-.2 2.8-.5"],
  info: ["M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Z", "M12 10v7", "M12 7h.01"],
  warning: ["M12 3 2.5 20h19L12 3Z", "M12 9v5", "M12 17h.01"],
  error: ["M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Z", "M8.5 8.5l7 7", "M15.5 8.5l-7 7"],
  success: ["M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Z", "M7.5 12l3 3 6-7"],
  menu: ["M4 7h16", "M4 12h16", "M4 17h16"],
  command: ["M9 8V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6"],
  signal: ["M4 17V7", "M9.3 17V10", "M14.7 17V5", "M20 17v-8"],
};

export interface IconProps extends SVGAttributes<SVGSVGElement> {
  name: SynexIconName;
  label?: string;
  size?: SynexSize | number;
  tone?: SynexTone;
}

export const Icon = forwardRef<SVGSVGElement, IconProps>(function Icon(
  { name, label, size = "md", tone, className, ...props },
  ref,
) {
  return (
    <svg
      ref={ref}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={sx("sx-synex-icon", className)}
      data-sx-size={size}
      data-sx-tone={tone}
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      {...props}
    >
      {iconPaths[name].map((path, index) => <path key={index} d={path} />)}
    </svg>
  );
});

export const SynexIcon = Icon;

export const VisuallyHidden = forwardRef<HTMLSpanElement, HTMLAttributes<HTMLSpanElement>>(function VisuallyHidden(
  { className, ...props },
  ref,
) {
  return <span ref={ref} className={sx("sx-visually-hidden", className)} {...props} />;
});
