import { type CSSProperties, type HTMLAttributes, type ReactNode } from "react";
import { type Orientation, type SynexDensity, type SynexSpacing } from "./internal.js";
export type SurfaceMaterial = "solid" | "elevated" | "translucent" | "glass" | "frosted" | "acrylic" | "floating" | "immersive";
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
export declare const Surface: import("react").ForwardRefExoticComponent<SurfaceProps & import("react").RefAttributes<HTMLDivElement>>;
export interface StackProps extends HTMLAttributes<HTMLDivElement> {
    gap?: SynexSpacing;
    align?: CSSProperties["alignItems"];
    justify?: CSSProperties["justifyContent"];
    density?: SynexDensity;
}
export declare const Stack: import("react").ForwardRefExoticComponent<StackProps & import("react").RefAttributes<HTMLDivElement>>;
export interface InlineProps extends StackProps {
    wrap?: boolean;
}
export declare const Inline: import("react").ForwardRefExoticComponent<InlineProps & import("react").RefAttributes<HTMLDivElement>>;
export interface GridProps extends HTMLAttributes<HTMLDivElement> {
    columns?: number | string;
    minColumnWidth?: number | string;
    gap?: SynexSpacing;
}
export declare const Grid: import("react").ForwardRefExoticComponent<GridProps & import("react").RefAttributes<HTMLDivElement>>;
export interface ContainerProps extends HTMLAttributes<HTMLDivElement> {
    size?: "sm" | "md" | "lg" | "xl" | "full";
    centered?: boolean;
}
export declare const Container: import("react").ForwardRefExoticComponent<ContainerProps & import("react").RefAttributes<HTMLDivElement>>;
export interface DividerProps extends HTMLAttributes<HTMLHRElement> {
    orientation?: Orientation;
    decorative?: boolean;
}
export declare const Divider: import("react").ForwardRefExoticComponent<DividerProps & import("react").RefAttributes<HTMLHRElement>>;
export interface ScrollAreaProps extends HTMLAttributes<HTMLDivElement> {
    orientation?: Orientation | "both";
    viewportClassName?: string;
    viewportProps?: HTMLAttributes<HTMLDivElement>;
}
export declare const ScrollArea: import("react").ForwardRefExoticComponent<ScrollAreaProps & import("react").RefAttributes<HTMLDivElement>>;
export interface SpacerProps extends HTMLAttributes<HTMLDivElement> {
    size?: number | string;
    axis?: Orientation | "both";
}
export declare const Spacer: import("react").ForwardRefExoticComponent<SpacerProps & import("react").RefAttributes<HTMLDivElement>>;
export interface AspectBoxProps extends HTMLAttributes<HTMLDivElement> {
    ratio?: number;
    children?: ReactNode;
}
export declare const AspectBox: import("react").ForwardRefExoticComponent<AspectBoxProps & import("react").RefAttributes<HTMLDivElement>>;
