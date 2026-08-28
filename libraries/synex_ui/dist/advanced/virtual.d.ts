import { type CSSProperties, type HTMLAttributes, type ReactNode } from "react";
export interface VirtualListRenderContext {
    index: number;
    style: CSSProperties;
}
export interface VirtualListProps<Item> extends Omit<HTMLAttributes<HTMLDivElement>, "children"> {
    items: readonly Item[];
    itemKey: (item: Item, index: number) => string;
    renderItem: (item: Item, context: VirtualListRenderContext) => ReactNode;
    itemSize: number;
    height: number | string;
    overscan?: number;
    ariaLabel: string;
    initialScrollOffset?: number;
    onVisibleRangeChange?: (range: {
        start: number;
        end: number;
    }) => void;
}
export declare function VirtualList<Item>({ items, itemKey, renderItem, itemSize, height, overscan, ariaLabel, initialScrollOffset, onVisibleRangeChange, className, style, onScroll, onKeyDown, tabIndex, ...props }: VirtualListProps<Item>): import("react").JSX.Element;
export interface VirtualGridRenderContext {
    index: number;
    row: number;
    column: number;
    style: CSSProperties;
}
export interface VirtualGridProps<Item> extends Omit<HTMLAttributes<HTMLDivElement>, "children"> {
    items: readonly Item[];
    itemKey: (item: Item, index: number) => string;
    renderItem: (item: Item, context: VirtualGridRenderContext) => ReactNode;
    minimumColumnWidth: number;
    rowHeight: number;
    height: number | string;
    columnGap?: number;
    rowGap?: number;
    overscanRows?: number;
    ariaLabel: string;
    onItemActivate?: (item: Item, index: number) => void;
}
export declare function VirtualGrid<Item>({ items, itemKey, renderItem, minimumColumnWidth, rowHeight, height, columnGap, rowGap, overscanRows, ariaLabel, onItemActivate, className, style, onScroll, onKeyDown, ...props }: VirtualGridProps<Item>): import("react").JSX.Element;
