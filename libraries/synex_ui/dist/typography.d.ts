import { type HTMLAttributes } from "react";
export type TypographyVariant = "display" | "heading-1" | "heading-2" | "heading-3" | "body" | "body-small" | "caption" | "label" | "numeric" | "code" | "monospace";
export type TypographyElement = "span" | "p" | "div" | "h1" | "h2" | "h3" | "h4" | "label" | "code" | "pre" | "output" | "strong" | "small";
export interface TypographyProps extends HTMLAttributes<HTMLElement> {
    as?: TypographyElement;
    variant?: TypographyVariant;
    truncate?: boolean;
}
export declare const Typography: import("react").ForwardRefExoticComponent<TypographyProps & import("react").RefAttributes<HTMLElement>>;
