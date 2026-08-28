import { type CSSProperties, type HTMLAttributes, type KeyboardEvent, type MutableRefObject, type ReactElement, type ReactNode, type MouseEvent as ReactMouseEvent, type Ref } from "react";
export type SynexSize = "sm" | "md" | "lg";
export type SynexTone = "neutral" | "accent" | "positive" | "warning" | "danger" | "info";
export type SynexDensity = "compact" | "comfortable" | "spacious";
export type Orientation = "horizontal" | "vertical";
export type SynexSpacing = "2xs" | "xs" | "sm" | "md" | "lg" | "xl" | number | (string & {});
export declare function spacingValue(value: SynexSpacing | undefined): string | undefined;
export declare function sx(...values: Array<string | false | null | undefined>): string;
export declare function composeIds(...ids: Array<string | undefined>): string | undefined;
export declare function useStableId(explicit: string | undefined, prefix: string): string;
export declare function useControllableState<T>(options: {
    value?: T;
    defaultValue: T;
    onChange?: (value: T) => void;
}): [T, (value: T | ((current: T) => T)) => void];
export declare function useLatest<T>(value: T): MutableRefObject<T>;
export declare function useOutsidePointer(refs: Array<MutableRefObject<HTMLElement | null>>, handler: (event: PointerEvent) => void, enabled?: boolean): void;
export declare function focusableElements(container: HTMLElement): HTMLElement[];
export declare function useFocusTrap(containerRef: MutableRefObject<HTMLElement | null>, active: boolean, options?: {
    initialFocusRef?: MutableRefObject<HTMLElement | null>;
    restore?: boolean;
}): void;
export declare function nextEnabledIndex(current: number, direction: 1 | -1, length: number, isDisabled: (index: number) => boolean, loop?: boolean): number;
export declare function rovingKey(event: KeyboardEvent, options: {
    current: number;
    length: number;
    orientation?: Orientation;
    isDisabled?: (index: number) => boolean;
    loop?: boolean;
}): number | null;
export declare function styleVars(values: Record<`--${string}`, string | number | undefined>): CSSProperties;
export declare function mergeRefs<T>(...refs: Array<Ref<T> | undefined>): (value: T | null) => void;
export declare function Slot({ children, ...props }: HTMLAttributes<HTMLElement> & {
    children: ReactNode;
}): ReactElement | null;
interface InteractiveTriggerElementProps {
    onClick?: (event: ReactMouseEvent<HTMLElement>) => void;
    "aria-haspopup"?: "menu" | "listbox" | "tree" | "grid" | "dialog" | true | false;
    "aria-expanded"?: boolean;
    "aria-controls"?: string;
}
export declare function InteractiveTrigger({ children, popup, expanded, controls, onActivate, className, }: {
    children: ReactNode;
    popup: InteractiveTriggerElementProps["aria-haspopup"];
    expanded: boolean;
    controls?: string;
    onActivate: () => void;
    className?: string;
}): ReactElement;
export declare function clamp(value: number, minimum: number, maximum: number): number;
export declare function normalizedText(value: ReactNode): string;
export declare function useDebouncedValue<T>(value: T, delay: number): T;
export declare function useObservedSize<T extends HTMLElement>(): {
    ref: MutableRefObject<T | null>;
    width: number;
    height: number;
};
export {};
