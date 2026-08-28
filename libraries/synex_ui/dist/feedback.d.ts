import { type HTMLAttributes, type ReactNode } from "react";
import { type ButtonProps } from "./actions.js";
import { type SynexSize, type SynexTone } from "./internal.js";
export interface SpinnerProps extends HTMLAttributes<HTMLSpanElement> {
    label?: string;
    size?: SynexSize;
}
export declare const Spinner: import("react").ForwardRefExoticComponent<SpinnerProps & import("react").RefAttributes<HTMLSpanElement>>;
export interface SkeletonProps extends HTMLAttributes<HTMLDivElement> {
    shape?: "text" | "rect" | "circle";
    lines?: number;
}
export declare const Skeleton: import("react").ForwardRefExoticComponent<SkeletonProps & import("react").RefAttributes<HTMLDivElement>>;
export interface ProgressBarProps extends HTMLAttributes<HTMLDivElement> {
    value?: number;
    maximum?: number;
    label: string;
    showValue?: boolean;
    indeterminate?: boolean;
    tone?: SynexTone;
    formatValue?: (value: number, maximum: number) => ReactNode;
}
export declare const ProgressBar: import("react").ForwardRefExoticComponent<ProgressBarProps & import("react").RefAttributes<HTMLDivElement>>;
export interface ProgressRingProps extends HTMLAttributes<HTMLDivElement> {
    value?: number;
    maximum?: number;
    label: string;
    size?: number;
    strokeWidth?: number;
    tone?: SynexTone;
    children?: ReactNode;
}
export declare const ProgressRing: import("react").ForwardRefExoticComponent<ProgressRingProps & import("react").RefAttributes<HTMLDivElement>>;
export interface LoadingOverlayProps extends HTMLAttributes<HTMLDivElement> {
    visible: boolean;
    label?: string;
    description?: ReactNode;
    blocking?: boolean;
}
export declare const LoadingOverlay: import("react").ForwardRefExoticComponent<LoadingOverlayProps & import("react").RefAttributes<HTMLDivElement>>;
export interface EmptyStateAction extends Omit<ButtonProps, "children"> {
    label: ReactNode;
}
export interface EmptyStateProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
    title: ReactNode;
    description?: ReactNode;
    icon?: ReactNode;
    primaryAction?: EmptyStateAction;
    secondaryAction?: EmptyStateAction;
}
export declare const EmptyState: import("react").ForwardRefExoticComponent<EmptyStateProps & import("react").RefAttributes<HTMLDivElement>>;
export interface ToastProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
    title: ReactNode;
    description?: ReactNode;
    tone?: SynexTone;
    action?: EmptyStateAction;
    onDismiss?: () => void;
    dismissLabel?: string;
}
export declare const Toast: import("react").ForwardRefExoticComponent<ToastProps & import("react").RefAttributes<HTMLDivElement>>;
