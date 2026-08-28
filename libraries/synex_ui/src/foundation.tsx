import {
  forwardRef,
  type CSSProperties,
  type HTMLAttributes,
  type ReactNode,
} from "react";
import { spacingValue, styleVars, sx, type Orientation, type SynexDensity, type SynexSpacing } from "./internal.js";

export type SurfaceMaterial =
  | "solid"
  | "elevated"
  | "translucent"
  | "glass"
  | "frosted"
  | "acrylic"
  | "floating"
  | "immersive";

export type SurfaceIntensity = "subtle" | "soft" | "medium" | "strong";
export type SurfaceTone = "neutral" | "accent" | "success" | "warning" | "danger";
export type SurfaceElevation = 0 | 1 | 2 | 3 | 4 | "flat" | "raised" | "floating" | "overlay";

export interface SurfaceProps extends HTMLAttributes<HTMLDivElement> {
  material?: SurfaceMaterial;
  variant?: SurfaceMaterial;
  intensity?: SurfaceIntensity;
  elevation?: SurfaceElevation;
  tone?: SurfaceTone;
  inset?: boolean;
  interactive?: boolean;
}

export const Surface = forwardRef<HTMLDivElement, SurfaceProps>(function Surface(
  {
    material = "solid",
    variant,
    intensity = "soft",
    elevation = 0,
    tone = "neutral",
    inset = false,
    interactive = false,
    className,
    ...props
  },
  ref,
) {
  return (
    <div
      ref={ref}
      className={sx("sx-surface", className)}
      data-sx-material={variant ?? material}
      data-sx-intensity={intensity}
      data-sx-elevation={elevation}
      data-sx-tone={tone}
      data-sx-inset={inset || undefined}
      data-sx-interactive={interactive || undefined}
      {...props}
    />
  );
});

export interface StackProps extends HTMLAttributes<HTMLDivElement> {
  gap?: SynexSpacing;
  align?: CSSProperties["alignItems"];
  justify?: CSSProperties["justifyContent"];
  density?: SynexDensity;
}

export const Stack = forwardRef<HTMLDivElement, StackProps>(function Stack(
  { gap, align, justify, density, className, style, ...props },
  ref,
) {
  return (
    <div
      ref={ref}
      className={sx("sx-stack", className)}
      data-sx-density={density}
      style={{ ...styleVars({ "--sx-stack-gap": spacingValue(gap) }), alignItems: align, justifyContent: justify, ...style }}
      {...props}
    />
  );
});

export interface InlineProps extends StackProps {
  wrap?: boolean;
}

export const Inline = forwardRef<HTMLDivElement, InlineProps>(function Inline(
  { wrap = false, className, style, ...props },
  ref,
) {
  return <Stack ref={ref} className={sx("sx-inline", className)} style={{ flexWrap: wrap ? "wrap" : "nowrap", ...style }} {...props} />;
});

export interface GridProps extends HTMLAttributes<HTMLDivElement> {
  columns?: number | string;
  minColumnWidth?: number | string;
  gap?: SynexSpacing;
}

export const Grid = forwardRef<HTMLDivElement, GridProps>(function Grid(
  { columns, minColumnWidth, gap, className, style, ...props },
  ref,
) {
  const template = typeof columns === "number"
    ? `repeat(${columns}, minmax(0, 1fr))`
    : columns ?? (minColumnWidth !== undefined
      ? `repeat(auto-fit, minmax(${typeof minColumnWidth === "number" ? `${minColumnWidth}px` : minColumnWidth}, 1fr))`
      : undefined);
  return (
    <div
      ref={ref}
      className={sx("sx-grid", className)}
      style={{
        ...styleVars({ "--sx-grid-gap": spacingValue(gap) }),
        gridTemplateColumns: template,
        ...style,
      }}
      {...props}
    />
  );
});

export interface ContainerProps extends HTMLAttributes<HTMLDivElement> {
  size?: "sm" | "md" | "lg" | "xl" | "full";
  centered?: boolean;
}

export const Container = forwardRef<HTMLDivElement, ContainerProps>(function Container(
  { size = "lg", centered = true, className, ...props },
  ref,
) {
  return <div ref={ref} className={sx("sx-container", className)} data-sx-size={size} data-sx-centered={centered || undefined} {...props} />;
});

export interface DividerProps extends HTMLAttributes<HTMLHRElement> {
  orientation?: Orientation;
  decorative?: boolean;
}

export const Divider = forwardRef<HTMLHRElement, DividerProps>(function Divider(
  { orientation = "horizontal", decorative = true, className, ...props },
  ref,
) {
  return <hr ref={ref} className={sx("sx-divider", className)} data-sx-orientation={orientation} aria-orientation={orientation} aria-hidden={decorative || undefined} {...props} />;
});

export interface ScrollAreaProps extends HTMLAttributes<HTMLDivElement> {
  orientation?: Orientation | "both";
  viewportClassName?: string;
  viewportProps?: HTMLAttributes<HTMLDivElement>;
}

export const ScrollArea = forwardRef<HTMLDivElement, ScrollAreaProps>(function ScrollArea(
  { orientation = "vertical", viewportClassName, viewportProps, children, className, ...props },
  ref,
) {
  return (
    <div ref={ref} className={sx("sx-scroll-area", className)} data-sx-orientation={orientation} {...props}>
      <div {...viewportProps} className={sx("sx-scroll-area__viewport", viewportClassName, viewportProps?.className)}>{children}</div>
    </div>
  );
});

export interface SpacerProps extends HTMLAttributes<HTMLDivElement> {
  size?: number | string;
  axis?: Orientation | "both";
}

export const Spacer = forwardRef<HTMLDivElement, SpacerProps>(function Spacer(
  { size = "var(--sx-space-4)", axis = "vertical", style, className, ...props },
  ref,
) {
  const value = typeof size === "number" ? `${size}px` : size;
  return (
    <div
      ref={ref}
      aria-hidden="true"
      className={sx("sx-spacer", className)}
      data-sx-axis={axis}
      style={{ width: axis === "vertical" ? undefined : value, height: axis === "horizontal" ? undefined : value, ...style }}
      {...props}
    />
  );
});

export interface AspectBoxProps extends HTMLAttributes<HTMLDivElement> {
  ratio?: number;
  children?: ReactNode;
}

export const AspectBox = forwardRef<HTMLDivElement, AspectBoxProps>(function AspectBox(
  { ratio = 16 / 9, className, style, ...props },
  ref,
) {
  return <div ref={ref} className={sx("sx-aspect-box", className)} style={{ aspectRatio: ratio, ...style }} {...props} />;
});
