import {
  forwardRef,
  useId,
  useRef,
  useState,
  type ButtonHTMLAttributes,
  type HTMLAttributes,
  type ReactNode,
} from "react";
import { mergeRefs, sx, useOutsidePointer, type SynexSize, type SynexTone } from "./internal.js";

export type ButtonVariant = "primary" | "secondary" | "quiet" | "outline" | "danger";

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: SynexSize;
  tone?: SynexTone;
  loading?: boolean;
  leading?: ReactNode;
  trailing?: ReactNode;
  fullWidth?: boolean;
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  {
    variant = "primary",
    size = "md",
    tone,
    loading = false,
    leading,
    trailing,
    fullWidth = false,
    disabled,
    type = "button",
    className,
    children,
    ...props
  },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      className={sx("sx-button", className)}
      data-sx-variant={variant}
      data-sx-size={size}
      data-sx-tone={tone}
      data-sx-loading={loading || undefined}
      data-sx-full-width={fullWidth || undefined}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      {...props}
    >
      {loading ? <span className="sx-button__spinner" aria-hidden="true" /> : leading ? <span className="sx-button__leading" aria-hidden="true">{leading}</span> : null}
      <span className="sx-button__label">{children}</span>
      {trailing ? <span className="sx-button__trailing" aria-hidden="true">{trailing}</span> : null}
    </button>
  );
});

export interface IconButtonProps extends Omit<ButtonProps, "children" | "leading" | "trailing"> {
  label: string;
  icon: ReactNode;
}

export const IconButton = forwardRef<HTMLButtonElement, IconButtonProps>(function IconButton(
  { label, icon, className, ...props },
  ref,
) {
  return (
    <Button ref={ref} className={sx("sx-icon-button", className)} aria-label={label} title={label} {...props}>
      <span aria-hidden="true" className="sx-icon-button__icon">{icon}</span>
    </Button>
  );
});

export interface SplitButtonProps extends Omit<ButtonProps, "trailing"> {
  menuLabel?: string;
  menu: ReactNode;
  open?: boolean;
  defaultOpen?: boolean;
  onOpenChange?: (open: boolean) => void;
}

export const SplitButton = forwardRef<HTMLDivElement, SplitButtonProps>(function SplitButton(
  {
    menu,
    menuLabel = "More actions",
    open,
    defaultOpen = false,
    onOpenChange,
    className,
    children,
    ...buttonProps
  },
  ref,
) {
  const generated = useId();
  const menuId = `sx-split-menu-${generated.replaceAll(":", "")}`;
  const rootRef = useRef<HTMLDivElement | null>(null);
  const menuTriggerRef = useRef<HTMLButtonElement | null>(null);
  const [internal, setInternal] = useState(defaultOpen);
  const isOpen = open ?? internal;
  const update = (next: boolean) => {
    if (open === undefined) setInternal(next);
    onOpenChange?.(next);
  };
  const closeAndRestore = () => {
    update(false);
    queueMicrotask(() => menuTriggerRef.current?.focus());
  };
  useOutsidePointer([rootRef], () => update(false), isOpen);
  return (
    <div ref={mergeRefs(rootRef, ref)} className={sx("sx-split-button", className)} data-sx-open={isOpen || undefined}>
      <Button {...buttonProps}>{children}</Button>
      <IconButton
        ref={menuTriggerRef}
        variant={buttonProps.variant}
        size={buttonProps.size}
        tone={buttonProps.tone}
        disabled={buttonProps.disabled}
        label={menuLabel}
        icon={<span className="sx-icon sx-icon--chevron" />}
        aria-haspopup="menu"
        aria-expanded={isOpen}
        aria-controls={menuId}
        onClick={() => update(!isOpen)}
        onKeyDown={(event) => {
          if (event.key === "ArrowDown") {
            event.preventDefault();
            update(true);
          }
        }}
      />
      {isOpen ? (
        <div
          id={menuId}
          className="sx-split-button__menu"
          onKeyDownCapture={(event) => {
            if (event.key !== "Escape") return;
            event.preventDefault();
            event.stopPropagation();
            closeAndRestore();
          }}
        >
          {menu}
        </div>
      ) : null}
    </div>
  );
});

export interface ActionRowProps extends HTMLAttributes<HTMLDivElement> {
  align?: "start" | "end" | "between";
  reverseOnNarrow?: boolean;
}

export const ActionRow = forwardRef<HTMLDivElement, ActionRowProps>(function ActionRow(
  { align = "end", reverseOnNarrow = false, className, ...props },
  ref,
) {
  return <div ref={ref} className={sx("sx-action-row", className)} data-sx-align={align} data-sx-reverse-narrow={reverseOnNarrow || undefined} {...props} />;
});
