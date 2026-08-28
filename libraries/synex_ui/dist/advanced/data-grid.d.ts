import { type HTMLAttributes, type ReactNode } from "react";
export interface DataGridRootProps extends HTMLAttributes<HTMLDivElement> {
    columns: number;
    label: string;
    rowCount?: number;
    columnTemplate?: string;
}
export declare const DataGridRoot: import("react").ForwardRefExoticComponent<DataGridRootProps & import("react").RefAttributes<HTMLDivElement>>;
export declare const DataGridHeader: import("react").ForwardRefExoticComponent<HTMLAttributes<HTMLDivElement> & import("react").RefAttributes<HTMLDivElement>>;
export declare const DataGridBody: import("react").ForwardRefExoticComponent<HTMLAttributes<HTMLDivElement> & import("react").RefAttributes<HTMLDivElement>>;
export interface DataGridRowProps extends HTMLAttributes<HTMLDivElement> {
    rowIndex?: number;
    selected?: boolean;
}
export declare const DataGridRow: import("react").ForwardRefExoticComponent<DataGridRowProps & import("react").RefAttributes<HTMLDivElement>>;
export interface DataGridCellProps extends HTMLAttributes<HTMLDivElement> {
    columnIndex?: number;
    header?: boolean;
    align?: "start" | "center" | "end";
    active?: boolean;
}
export declare const DataGridCell: import("react").ForwardRefExoticComponent<DataGridCellProps & import("react").RefAttributes<HTMLDivElement>>;
export interface DataGridColumn<Row> {
    id: string;
    header: ReactNode;
    cell: (row: Row, rowIndex: number) => ReactNode;
    width?: string;
    align?: "start" | "center" | "end";
    sortable?: boolean;
}
export interface DataGridProps<Row> extends Omit<HTMLAttributes<HTMLDivElement>, "children"> {
    columns: readonly DataGridColumn<Row>[];
    rows: readonly Row[];
    rowKey: (row: Row, index: number) => string;
    label: string;
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
    empty?: ReactNode;
}
export declare function DataGrid<Row>({ columns, rows, rowKey, label, selectedKeys, onRowActivate, sort, onSortChange, empty, className, ...props }: DataGridProps<Row>): import("react").JSX.Element;
