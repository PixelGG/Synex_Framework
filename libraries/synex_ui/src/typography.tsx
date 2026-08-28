import {
  createElement,
  forwardRef,
  type HTMLAttributes,
} from "react";
import { sx } from "./internal.js";

export type TypographyVariant =
  | "display"
  | "heading-1"
  | "heading-2"
  | "heading-3"
  | "body"
  | "body-small"
  | "caption"
  | "label"
  | "numeric"
  | "code"
  | "monospace";

export type TypographyElement =
  | "span"
  | "p"
  | "div"
  | "h1"
  | "h2"
  | "h3"
  | "h4"
  | "label"
  | "code"
  | "pre"
  | "output"
  | "strong"
  | "small";

export interface TypographyProps extends HTMLAttributes<HTMLElement> {
  as?: TypographyElement;
  variant?: TypographyVariant;
  truncate?: boolean;
}

const defaultElements: Record<TypographyVariant, TypographyElement> = {
  display: "h1",
  "heading-1": "h1",
  "heading-2": "h2",
  "heading-3": "h3",
  body: "p",
  "body-small": "p",
  caption: "span",
  label: "span",
  numeric: "span",
  code: "code",
  monospace: "span",
};

export const Typography = forwardRef<HTMLElement, TypographyProps>(function Typography(
  { as, variant = "body", truncate = false, className, ...props },
  ref,
) {
  return createElement(as ?? defaultElements[variant], {
    ...props,
    ref,
    className: sx("sx-typography", `sx-type-${variant}`, className),
    "data-sx-typography": variant,
    "data-sx-truncate": truncate || undefined,
  });
});
