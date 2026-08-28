import { type HTMLAttributes, type ReactNode } from "react";
import { type Orientation } from "./internal.js";
export interface TabItem<Value extends string = string> {
    value: Value;
    label: ReactNode;
    content: ReactNode;
    disabled?: boolean;
    badge?: ReactNode;
}
export interface TabsProps<Value extends string = string> extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
    items: readonly TabItem<Value>[];
    value?: Value;
    defaultValue?: Value;
    onValueChange?: (value: Value) => void;
    orientation?: Orientation;
    activation?: "automatic" | "manual";
    label?: string;
}
export declare function Tabs<Value extends string = string>({ items, value, defaultValue, onValueChange, orientation, activation, label, className, ...props }: TabsProps<Value>): import("react").JSX.Element;
export interface BreadcrumbItem {
    label: ReactNode;
    href?: string;
    onClick?: () => void;
}
export interface BreadcrumbProps extends HTMLAttributes<HTMLElement> {
    items: readonly BreadcrumbItem[];
    label?: string;
    separator?: ReactNode;
}
export declare const Breadcrumb: import("react").ForwardRefExoticComponent<BreadcrumbProps & import("react").RefAttributes<HTMLElement>>;
export interface PaginationProps extends HTMLAttributes<HTMLElement> {
    page: number;
    pageCount: number;
    onPageChange: (page: number) => void;
    siblingCount?: number;
    label?: string;
}
export declare const Pagination: import("react").ForwardRefExoticComponent<PaginationProps & import("react").RefAttributes<HTMLElement>>;
export interface StepItem<Value extends string = string> {
    value: Value;
    label: ReactNode;
    description?: ReactNode;
    optional?: boolean;
    disabled?: boolean;
}
export interface StepperProps<Value extends string = string> extends Omit<HTMLAttributes<HTMLOListElement>, "onChange"> {
    steps: readonly StepItem<Value>[];
    value: Value;
    completed?: readonly Value[];
    onValueChange?: (value: Value) => void;
    orientation?: Orientation;
}
export declare function Stepper<Value extends string = string>({ steps, value, completed, onValueChange, orientation, className, ...props }: StepperProps<Value>): import("react").JSX.Element;
export interface SideNavItem {
    id: string;
    label: ReactNode;
    icon?: ReactNode;
    href?: string;
    disabled?: boolean;
    badge?: ReactNode;
    children?: readonly SideNavItem[];
}
export interface SideNavProps extends HTMLAttributes<HTMLElement> {
    items: readonly SideNavItem[];
    activeId?: string;
    onNavigate?: (item: SideNavItem) => void;
    label?: string;
    collapsed?: boolean;
}
export declare const SideNav: import("react").ForwardRefExoticComponent<SideNavProps & import("react").RefAttributes<HTMLElement>>;
