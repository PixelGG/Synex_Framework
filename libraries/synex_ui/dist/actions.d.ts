import { type ButtonHTMLAttributes, type HTMLAttributes, type ReactNode } from "react";
import { type SynexSize, type SynexTone } from "./internal.js";
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
export declare const Button: import("react").ForwardRefExoticComponent<ButtonProps & import("react").RefAttributes<HTMLButtonElement>>;
export interface IconButtonProps extends Omit<ButtonProps, "children" | "leading" | "trailing"> {
    label: string;
    icon: ReactNode;
}
export declare const IconButton: import("react").ForwardRefExoticComponent<IconButtonProps & import("react").RefAttributes<HTMLButtonElement>>;
export interface SplitButtonProps extends Omit<ButtonProps, "trailing"> {
    menuLabel?: string;
    menu: ReactNode;
    open?: boolean;
    defaultOpen?: boolean;
    onOpenChange?: (open: boolean) => void;
}
export declare const SplitButton: import("react").ForwardRefExoticComponent<SplitButtonProps & import("react").RefAttributes<HTMLDivElement>>;
export interface ActionRowProps extends HTMLAttributes<HTMLDivElement> {
    align?: "start" | "end" | "between";
    reverseOnNarrow?: boolean;
}
export declare const ActionRow: import("react").ForwardRefExoticComponent<ActionRowProps & import("react").RefAttributes<HTMLDivElement>>;
