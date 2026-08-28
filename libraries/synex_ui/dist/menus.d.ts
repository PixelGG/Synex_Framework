import { type HTMLAttributes, type ReactNode } from "react";
export type MenuItem = {
    type?: "action";
    id: string;
    label: ReactNode;
    icon?: ReactNode;
    hint?: string;
    disabled?: boolean;
    danger?: boolean;
    onSelect: () => void;
} | {
    type: "checkbox";
    id: string;
    label: ReactNode;
    checked: boolean;
    disabled?: boolean;
    onCheckedChange: (checked: boolean) => void;
} | {
    type: "radio";
    id: string;
    label: ReactNode;
    value: string;
    selectedValue: string;
    disabled?: boolean;
    onValueChange: (value: string) => void;
} | {
    type: "label";
    id: string;
    label: ReactNode;
} | {
    type: "separator";
    id: string;
} | {
    type: "submenu";
    id: string;
    label: ReactNode;
    icon?: ReactNode;
    disabled?: boolean;
    items: readonly MenuItem[];
};
export interface MenuProps extends HTMLAttributes<HTMLDivElement> {
    items: readonly MenuItem[];
    label?: string;
    onClose?: () => void;
    initialActiveId?: string;
    autoFocus?: boolean;
}
export declare const Menu: import("react").ForwardRefExoticComponent<MenuProps & import("react").RefAttributes<HTMLDivElement>>;
export interface SubmenuProps extends MenuProps {
    placement?: "right-start" | "left-start";
}
export declare const Submenu: import("react").ForwardRefExoticComponent<SubmenuProps & import("react").RefAttributes<HTMLDivElement>>;
export interface DropdownProps extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
    trigger: ReactNode;
    items: readonly MenuItem[];
    label?: string;
    open?: boolean;
    defaultOpen?: boolean;
    onOpenChange?: (open: boolean) => void;
    align?: "start" | "end";
}
export declare const Dropdown: import("react").ForwardRefExoticComponent<DropdownProps & import("react").RefAttributes<HTMLDivElement>>;
export interface ContextMenuProps extends Omit<HTMLAttributes<HTMLDivElement>, "onContextMenu"> {
    items: readonly MenuItem[];
    label?: string;
}
export declare const ContextMenu: import("react").ForwardRefExoticComponent<ContextMenuProps & import("react").RefAttributes<HTMLDivElement>>;
export interface ActionMenuProps extends Omit<DropdownProps, "trigger"> {
    triggerLabel?: string;
    trigger?: ReactNode;
}
export declare function ActionMenu({ triggerLabel, trigger, ...props }: ActionMenuProps): import("react").JSX.Element;
