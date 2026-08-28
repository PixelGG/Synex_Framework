import { type HTMLAttributes, type ImgHTMLAttributes, type ReactNode, type TableHTMLAttributes } from "react";
import { type SynexSize, type SynexTone } from "./internal.js";
export interface TableColumn<Row> {
    id: string;
    header: ReactNode;
    cell: (row: Row, index: number) => ReactNode;
    align?: "start" | "center" | "end";
    width?: string | number;
    sortable?: boolean;
}
export interface TableProps<Row> extends Omit<TableHTMLAttributes<HTMLTableElement>, "children"> {
    columns: readonly TableColumn<Row>[];
    rows: readonly Row[];
    rowKey: (row: Row, index: number) => string;
    caption?: ReactNode;
    empty?: ReactNode;
    selectedKeys?: ReadonlySet<string>;
    onRowActivate?: (row: Row, index: number) => void;
    sort?: {
        columnId: string;
        direction: "ascending" | "descending";
    };
    onSortChange?: (sort: {
        columnId: string;
        direction: "ascending" | "descending";
    }) => void;
}
export declare function Table<Row>({ columns, rows, rowKey, caption, empty, selectedKeys, onRowActivate, sort, onSortChange, className, ...props }: TableProps<Row>): import("react").JSX.Element;
export interface DataListItem {
    id: string;
    primary: ReactNode;
    secondary?: ReactNode;
    leading?: ReactNode;
    trailing?: ReactNode;
    disabled?: boolean;
}
export interface DataListProps extends HTMLAttributes<HTMLUListElement> {
    items: readonly DataListItem[];
    onItemActivate?: (item: DataListItem) => void;
    empty?: ReactNode;
}
export declare const DataList: import("react").ForwardRefExoticComponent<DataListProps & import("react").RefAttributes<HTMLUListElement>>;
export interface KeyValueItem {
    key: string;
    label: ReactNode;
    value: ReactNode;
    copyable?: boolean;
}
export interface KeyValueListProps extends Omit<HTMLAttributes<HTMLDListElement>, "onCopy"> {
    items: readonly KeyValueItem[];
    onCopyValue?: (item: KeyValueItem) => void;
}
export declare const KeyValueList: import("react").ForwardRefExoticComponent<KeyValueListProps & import("react").RefAttributes<HTMLDListElement>>;
export interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
    tone?: SynexTone;
    variant?: "soft" | "outline" | "solid";
    size?: "sm" | "md";
}
export declare const Badge: import("react").ForwardRefExoticComponent<BadgeProps & import("react").RefAttributes<HTMLSpanElement>>;
export interface StatusBadgeProps extends Omit<BadgeProps, "tone"> {
    status: "online" | "offline" | "idle" | "busy" | "success" | "warning" | "error" | "unknown";
    pulse?: boolean;
}
export declare const StatusBadge: import("react").ForwardRefExoticComponent<StatusBadgeProps & import("react").RefAttributes<HTMLSpanElement>>;
export interface StatProps extends HTMLAttributes<HTMLDivElement> {
    label: ReactNode;
    value: ReactNode;
    detail?: ReactNode;
    trend?: "up" | "down" | "flat";
    tone?: SynexTone;
}
export declare const Stat: import("react").ForwardRefExoticComponent<StatProps & import("react").RefAttributes<HTMLDivElement>>;
export interface MetricProps extends StatProps {
    unit?: ReactNode;
    progress?: number;
}
export declare const Metric: import("react").ForwardRefExoticComponent<MetricProps & import("react").RefAttributes<HTMLDivElement>>;
export interface AvatarProps extends Omit<ImgHTMLAttributes<HTMLImageElement>, "size"> {
    name: string;
    size?: SynexSize | "xl";
    status?: StatusBadgeProps["status"];
}
export declare const Avatar: import("react").ForwardRefExoticComponent<AvatarProps & import("react").RefAttributes<HTMLSpanElement>>;
export interface ListItemProps extends HTMLAttributes<HTMLLIElement> {
    primary: ReactNode;
    secondary?: ReactNode;
    leading?: ReactNode;
    trailing?: ReactNode;
    disabled?: boolean;
    selected?: boolean;
    onActivate?: () => void;
}
export declare const ListItem: import("react").ForwardRefExoticComponent<ListItemProps & import("react").RefAttributes<HTMLLIElement>>;
