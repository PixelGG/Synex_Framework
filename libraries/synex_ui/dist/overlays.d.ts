import { type HTMLAttributes, type MutableRefObject, type ReactNode } from "react";
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
export declare const Dialog: import("react").ForwardRefExoticComponent<DialogProps & import("react").RefAttributes<HTMLDivElement>>;
export interface AlertDialogProps extends Omit<DialogProps, "footer" | "onOpenChange"> {
    confirmLabel: string;
    cancelLabel?: string;
    onConfirm: () => void | Promise<void>;
    onCancel?: () => void;
    onOpenChange?: (open: boolean) => void;
    destructive?: boolean;
    busy?: boolean;
}
export declare function AlertDialog({ confirmLabel, cancelLabel, onConfirm, onCancel, onOpenChange, destructive, busy, ...props }: AlertDialogProps): import("react").JSX.Element;
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
export declare const Popover: import("react").ForwardRefExoticComponent<PopoverProps & import("react").RefAttributes<HTMLDivElement>>;
export interface DrawerProps extends DialogProps {
    side?: "left" | "right";
}
export declare function Drawer({ side, className, ...props }: DrawerProps): import("react").JSX.Element;
export interface SheetProps extends DialogProps {
    edge?: "top" | "right" | "bottom" | "left";
}
export declare function Sheet({ edge, className, ...props }: SheetProps): import("react").JSX.Element;
export type ModalProps = DialogProps;
export declare function Modal(props: ModalProps): import("react").JSX.Element;
