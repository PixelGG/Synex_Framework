import {
  forwardRef,
  useEffect,
  useRef,
  type HTMLAttributes,
  type MutableRefObject,
  type ReactNode,
} from "react";
import { ActionRow, Button, IconButton } from "./actions.js";
import { InteractiveTrigger, mergeRefs, sx, useControllableState, useFocusTrap, useOutsidePointer, useStableId } from "./internal.js";

export interface DialogProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  open?: boolean;
  defaultOpen?: boolean;
  onOpenChange?: (open: boolean) => void;
  title: ReactNode;
  description?: ReactNode;
  closeLabel?: string;
  footer?: ReactNode;
  initialFocusRef?: MutableRefObject<HTMLElement | null>;
  closeOnEscape?: boolean;
  closeOnBackdrop?: boolean;
  showCloseButton?: boolean;
  modal?: boolean;
  size?: "sm" | "md" | "lg" | "xl" | "fullscreen";
  dialogRole?: "dialog" | "alertdialog";
}

export const Dialog = forwardRef<HTMLDivElement, DialogProps>(function Dialog(
  {
    open,
    defaultOpen = false,
    onOpenChange,
    title,
    description,
    closeLabel = "Close dialog",
    footer,
    initialFocusRef,
    closeOnEscape = true,
    closeOnBackdrop = true,
    showCloseButton,
    modal = true,
    size = "md",
    dialogRole = "dialog",
    className,
    children,
    ...props
  },
  forwardedRef,
) {
  const [visible, setVisible] = useControllableState({ value: open, defaultValue: defaultOpen, onChange: onOpenChange });
  const canShowClose = showCloseButton ?? (closeOnEscape || closeOnBackdrop);
  const panelRef = useRef<HTMLDivElement | null>(null);
  const titleId = useStableId(undefined, "sx-dialog-title");
  const descriptionId = `${titleId}-description`;
  useFocusTrap(panelRef, visible && modal, { ...(initialFocusRef ? { initialFocusRef } : {}) });
  useEffect(() => {
    if (!visible || !modal) return;
    const previous = document.documentElement.style.overflow;
    document.documentElement.style.overflow = "hidden";
    return () => { document.documentElement.style.overflow = previous; };
  }, [modal, visible]);
  useEffect(() => {
    if (!visible || !closeOnEscape) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        const openDialogs = document.querySelectorAll<HTMLElement>(".sx-dialog");
        if (openDialogs.item(openDialogs.length - 1) !== panelRef.current) return;
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
        setVisible(false);
      }
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [closeOnEscape, setVisible, visible]);
  if (!visible) return null;
  return (
    <div
      className="sx-dialog-layer"
      data-sx-modal={modal || undefined}
      onMouseDown={(event) => {
        if (closeOnBackdrop && event.target === event.currentTarget) setVisible(false);
      }}
    >
      <div
        {...props}
        ref={mergeRefs(panelRef, forwardedRef)}
        role={dialogRole}
        aria-modal={modal || undefined}
        aria-labelledby={titleId}
        aria-describedby={description ? descriptionId : undefined}
        tabIndex={-1}
        className={sx("sx-dialog", className)}
        data-sx-size={size}
      >
        <header className="sx-dialog__header">
          <div className="sx-dialog__heading">
            <h2 id={titleId} className="sx-dialog__title">{title}</h2>
            {description ? <p id={descriptionId} className="sx-dialog__description">{description}</p> : null}
          </div>
          {canShowClose ? <IconButton label={closeLabel} variant="quiet" icon={<span className="sx-icon sx-icon--close" />} onClick={() => setVisible(false)} /> : null}
        </header>
        <div className="sx-dialog__body">{children}</div>
        {footer ? <footer className="sx-dialog__footer">{footer}</footer> : null}
      </div>
    </div>
  );
});

export interface AlertDialogProps extends Omit<DialogProps, "footer" | "onOpenChange"> {
  confirmLabel: string;
  cancelLabel?: string;
  onConfirm: () => void | Promise<void>;
  onCancel?: () => void;
  onOpenChange?: (open: boolean) => void;
  destructive?: boolean;
  busy?: boolean;
}

export function AlertDialog({
  confirmLabel,
  cancelLabel = "Cancel",
  onConfirm,
  onCancel,
  onOpenChange,
  destructive = false,
  busy = false,
  ...props
}: AlertDialogProps) {
  const cancelRef = useRef<HTMLButtonElement | null>(null);
  const close = () => {
    onCancel?.();
    onOpenChange?.(false);
  };
  return (
    <Dialog
      {...props}
      onOpenChange={onOpenChange}
      initialFocusRef={cancelRef}
      closeOnBackdrop={!busy}
      closeOnEscape={!busy}
      dialogRole="alertdialog"
      footer={
        <ActionRow>
          <Button ref={cancelRef} variant="secondary" disabled={busy} onClick={close}>{cancelLabel}</Button>
          <Button variant={destructive ? "danger" : "primary"} loading={busy} onClick={() => void onConfirm()}>{confirmLabel}</Button>
        </ActionRow>
      }
    />
  );
}

export interface PopoverProps extends Omit<HTMLAttributes<HTMLDivElement>, "content"> {
  trigger: ReactNode;
  content: ReactNode;
  open?: boolean;
  defaultOpen?: boolean;
  onOpenChange?: (open: boolean) => void;
  placement?: "top" | "right" | "bottom" | "left";
  align?: "start" | "center" | "end";
  label?: string;
}

export const Popover = forwardRef<HTMLDivElement, PopoverProps>(function Popover(
  { trigger, content, open, defaultOpen = false, onOpenChange, placement = "bottom", align = "start", label = "Popover", className, ...props },
  ref,
) {
  const [visible, setVisible] = useControllableState({ value: open, defaultValue: defaultOpen, onChange: onOpenChange });
  const rootRef = useRef<HTMLDivElement | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);
  const contentId = useStableId(undefined, "sx-popover");
  const refs = [rootRef, panelRef];
  useOutsidePointer(refs, () => setVisible(false), visible);
  const closeAndRestore = () => {
    setVisible(false);
    queueMicrotask(() => rootRef.current?.querySelector<HTMLElement>(`[aria-controls="${contentId}"]`)?.focus());
  };
  return (
    <div ref={mergeRefs(rootRef, ref)} className={sx("sx-popover", className)} data-sx-open={visible || undefined} {...props}>
      <InteractiveTrigger className="sx-popover__anchor" popup="dialog" expanded={visible} controls={contentId} onActivate={() => setVisible(!visible)}>{trigger}</InteractiveTrigger>
      {visible ? (
        <div id={contentId} ref={panelRef} role="dialog" aria-label={label} className="sx-popover__content" data-sx-placement={placement} data-sx-align={align} onKeyDown={(event) => { if (event.key === "Escape") { event.preventDefault(); closeAndRestore(); } }}>
          {content}
        </div>
      ) : null}
    </div>
  );
});

export interface DrawerProps extends DialogProps {
  side?: "left" | "right";
}

export function Drawer({ side = "right", className, ...props }: DrawerProps) {
  return <Dialog {...props} className={sx("sx-drawer", className)} data-sx-side={side} size="lg" />;
}

export interface SheetProps extends DialogProps {
  edge?: "top" | "right" | "bottom" | "left";
}

export function Sheet({ edge = "bottom", className, ...props }: SheetProps) {
  return <Dialog {...props} className={sx("sx-sheet", className)} data-sx-edge={edge} size="lg" />;
}

export type ModalProps = DialogProps;

export function Modal(props: ModalProps) {
  return <Dialog {...props} modal />;
}
