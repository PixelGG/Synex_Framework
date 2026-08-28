import { type HTMLAttributes, type ReactNode, type SVGAttributes } from "react";
import { type SynexSize, type SynexTone } from "./internal.js";
export interface TooltipProps extends Omit<HTMLAttributes<HTMLSpanElement>, "content"> {
    content: ReactNode;
    placement?: "top" | "right" | "bottom" | "left";
    delay?: number;
    disabled?: boolean;
}
export declare const Tooltip: import("react").ForwardRefExoticComponent<TooltipProps & import("react").RefAttributes<HTMLSpanElement>>;
export declare const KeyHint: import("react").ForwardRefExoticComponent<HTMLAttributes<HTMLElement> & import("react").RefAttributes<HTMLElement>>;
export interface ShortcutProps extends HTMLAttributes<HTMLSpanElement> {
    keys: readonly string[];
    separator?: ReactNode;
    label?: string;
}
export declare const Shortcut: import("react").ForwardRefExoticComponent<ShortcutProps & import("react").RefAttributes<HTMLSpanElement>>;
export type SynexIconName = "check" | "close" | "chevron-down" | "chevron-right" | "arrow-left" | "arrow-right" | "search" | "plus" | "minus" | "more" | "copy" | "eye" | "eye-off" | "info" | "warning" | "error" | "success" | "menu" | "command" | "signal";
export interface IconProps extends SVGAttributes<SVGSVGElement> {
    name: SynexIconName;
    label?: string;
    size?: SynexSize | number;
    tone?: SynexTone;
}
export declare const Icon: import("react").ForwardRefExoticComponent<IconProps & import("react").RefAttributes<SVGSVGElement>>;
export declare const SynexIcon: import("react").ForwardRefExoticComponent<IconProps & import("react").RefAttributes<SVGSVGElement>>;
export declare const VisuallyHidden: import("react").ForwardRefExoticComponent<HTMLAttributes<HTMLSpanElement> & import("react").RefAttributes<HTMLSpanElement>>;
