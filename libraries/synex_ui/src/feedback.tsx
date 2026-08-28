import { forwardRef, type HTMLAttributes, type ReactNode } from "react";
import { Button, type ButtonProps } from "./actions.js";
import { clamp, styleVars, sx, type SynexSize, type SynexTone } from "./internal.js";

export interface SpinnerProps extends HTMLAttributes<HTMLSpanElement> {
  label?: string;
  size?: SynexSize;
}

export const Spinner = forwardRef<HTMLSpanElement, SpinnerProps>(function Spinner(
  { label = "Loading", size = "md", className, ...props },
  ref,
) {
  const announced = label.trim().length > 0;
  return <span ref={ref} role={announced ? "status" : undefined} className={sx("sx-spinner", className)} data-sx-size={size} aria-label={announced ? label : undefined} aria-hidden={announced ? undefined : true} {...props}><span className="sx-spinner__track" aria-hidden="true" /></span>;
});

export interface SkeletonProps extends HTMLAttributes<HTMLDivElement> {
  shape?: "text" | "rect" | "circle";
  lines?: number;
}

export const Skeleton = forwardRef<HTMLDivElement, SkeletonProps>(function Skeleton(
  { shape = "rect", lines = 1, className, ...props },
  ref,
) {
  return (
    <div ref={ref} className={sx("sx-skeleton", className)} data-sx-shape={shape} aria-hidden="true" {...props}>
      {Array.from({ length: Math.max(1, lines) }, (_, index) => <span key={index} className="sx-skeleton__line" data-sx-last={index === lines - 1 || undefined} />)}
    </div>
  );
});

export interface ProgressBarProps extends HTMLAttributes<HTMLDivElement> {
  value?: number;
  maximum?: number;
  label: string;
  showValue?: boolean;
  indeterminate?: boolean;
  tone?: SynexTone;
  formatValue?: (value: number, maximum: number) => ReactNode;
}

export const ProgressBar = forwardRef<HTMLDivElement, ProgressBarProps>(function ProgressBar(
  { value = 0, maximum = 100, label, showValue = false, indeterminate = false, tone = "accent", formatValue = (current, max) => `${Math.round((current / max) * 100)}%`, className, ...props },
  ref,
) {
  const safeMaximum = maximum > 0 ? maximum : 100;
  const current = clamp(value, 0, safeMaximum);
  const percent = (current / safeMaximum) * 100;
  return (
    <div ref={ref} className={sx("sx-progress", className)} data-sx-indeterminate={indeterminate || undefined} data-sx-tone={tone} {...props}>
      <div className="sx-progress__header"><span>{label}</span>{showValue ? <span className="sx-progress__value">{formatValue(current, safeMaximum)}</span> : null}</div>
      <div className="sx-progress__track" role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={safeMaximum} aria-valuenow={indeterminate ? undefined : current}>
        <span className="sx-progress__fill" style={styleVars({ "--sx-progress-ratio": String(percent / 100) })} />
      </div>
    </div>
  );
});

export interface ProgressRingProps extends HTMLAttributes<HTMLDivElement> {
  value?: number;
  maximum?: number;
  label: string;
  size?: number;
  strokeWidth?: number;
  tone?: SynexTone;
  children?: ReactNode;
}

export const ProgressRing = forwardRef<HTMLDivElement, ProgressRingProps>(function ProgressRing(
  { value = 0, maximum = 100, label, size = 48, strokeWidth = 4, tone = "accent", children, className, ...props },
  ref,
) {
  const safeMaximum = maximum > 0 ? maximum : 100;
  const current = clamp(value, 0, safeMaximum);
  const radius = Math.max(1, (size - strokeWidth) / 2);
  const circumference = 2 * Math.PI * radius;
  const offset = circumference * (1 - current / safeMaximum);
  return (
    <div ref={ref} role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={safeMaximum} aria-valuenow={current} className={sx("sx-progress-ring", className)} data-sx-tone={tone} style={{ width: size, height: size }} {...props}>
      <svg viewBox={`0 0 ${size} ${size}`} aria-hidden="true">
        <circle className="sx-progress-ring__track" cx={size / 2} cy={size / 2} r={radius} fill="none" strokeWidth={strokeWidth} />
        <circle className="sx-progress-ring__value" cx={size / 2} cy={size / 2} r={radius} fill="none" strokeWidth={strokeWidth} strokeDasharray={circumference} strokeDashoffset={offset} />
      </svg>
      {children ? <span className="sx-progress-ring__content">{children}</span> : null}
    </div>
  );
});

export interface LoadingOverlayProps extends HTMLAttributes<HTMLDivElement> {
  visible: boolean;
  label?: string;
  description?: ReactNode;
  blocking?: boolean;
}

export const LoadingOverlay = forwardRef<HTMLDivElement, LoadingOverlayProps>(function LoadingOverlay(
  { visible, label = "Loading", description, blocking = true, className, ...props },
  ref,
) {
  if (!visible) return null;
  return (
    <div ref={ref} className={sx("sx-loading-overlay", className)} role="status" aria-live="polite" data-sx-blocking={blocking || undefined} {...props}>
      <Spinner label="" />
      <span className="sx-loading-overlay__label">{label}</span>
      {description ? <span className="sx-loading-overlay__description">{description}</span> : null}
    </div>
  );
});

export interface EmptyStateAction extends Omit<ButtonProps, "children"> {
  label: ReactNode;
}

export interface EmptyStateProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  title: ReactNode;
  description?: ReactNode;
  icon?: ReactNode;
  primaryAction?: EmptyStateAction;
  secondaryAction?: EmptyStateAction;
}

export const EmptyState = forwardRef<HTMLDivElement, EmptyStateProps>(function EmptyState(
  { title, description, icon, primaryAction, secondaryAction, className, ...props },
  ref,
) {
  return (
    <div ref={ref} className={sx("sx-empty-state", className)} {...props}>
      {icon ? <div className="sx-empty-state__icon" aria-hidden="true">{icon}</div> : null}
      <h3 className="sx-empty-state__title">{title}</h3>
      {description ? <p className="sx-empty-state__description">{description}</p> : null}
      {primaryAction || secondaryAction ? <div className="sx-empty-state__actions">{secondaryAction ? <Button {...secondaryAction} variant={secondaryAction.variant ?? "secondary"}>{secondaryAction.label}</Button> : null}{primaryAction ? <Button {...primaryAction}>{primaryAction.label}</Button> : null}</div> : null}
    </div>
  );
});

export interface ToastProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  title: ReactNode;
  description?: ReactNode;
  tone?: SynexTone;
  action?: EmptyStateAction;
  onDismiss?: () => void;
  dismissLabel?: string;
}

export const Toast = forwardRef<HTMLDivElement, ToastProps>(function Toast(
  { title, description, tone = "neutral", action, onDismiss, dismissLabel = "Dismiss notification", className, ...props },
  ref,
) {
  return (
    <div ref={ref} role={tone === "danger" ? "alert" : "status"} className={sx("sx-toast", className)} data-sx-tone={tone} {...props}>
      <span className="sx-toast__signal" aria-hidden="true" />
      <div className="sx-toast__copy"><strong className="sx-toast__title">{title}</strong>{description ? <span className="sx-toast__description">{description}</span> : null}</div>
      {action ? <Button {...action} variant={action.variant ?? "quiet"}>{action.label}</Button> : null}
      {onDismiss ? <button type="button" className="sx-toast__dismiss" aria-label={dismissLabel} onClick={onDismiss}><span className="sx-icon sx-icon--close" aria-hidden="true" /></button> : null}
    </div>
  );
});
