import {
  forwardRef,
  useRef,
  useState,
  type HTMLAttributes,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { styleVars, sx } from "../internal.js";

export interface DataGridRootProps extends HTMLAttributes<HTMLDivElement> {
  columns: number;
  label: string;
  rowCount?: number;
  columnTemplate?: string;
}

export const DataGridRoot = forwardRef<HTMLDivElement, DataGridRootProps>(function DataGridRoot(
  { columns, label, rowCount, columnTemplate, className, children, ...props },
  ref,
) {
  return <div ref={ref} role="grid" aria-label={label} aria-rowcount={rowCount} aria-colcount={columns} className={sx("sx-data-grid", className)} style={styleVars({ "--sx-data-grid-columns": columnTemplate ?? `repeat(${columns}, minmax(0, 1fr))` })} {...props}>{children}</div>;
});

export const DataGridHeader = forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(function DataGridHeader({ className, ...props }, ref) {
  return <div ref={ref} role="rowgroup" className={sx("sx-data-grid__header", className)} {...props} />;
});

export const DataGridBody = forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(function DataGridBody({ className, ...props }, ref) {
  return <div ref={ref} role="rowgroup" className={sx("sx-data-grid__body", className)} {...props} />;
});

export interface DataGridRowProps extends HTMLAttributes<HTMLDivElement> {
  rowIndex?: number;
  selected?: boolean;
}

export const DataGridRow = forwardRef<HTMLDivElement, DataGridRowProps>(function DataGridRow({ rowIndex, selected = false, className, ...props }, ref) {
  return <div ref={ref} role="row" aria-rowindex={rowIndex === undefined ? undefined : rowIndex + 1} aria-selected={selected || undefined} className={sx("sx-data-grid__row", className)} data-sx-selected={selected || undefined} {...props} />;
});

export interface DataGridCellProps extends HTMLAttributes<HTMLDivElement> {
  columnIndex?: number;
  header?: boolean;
  align?: "start" | "center" | "end";
  active?: boolean;
}

export const DataGridCell = forwardRef<HTMLDivElement, DataGridCellProps>(function DataGridCell({ columnIndex, header = false, align = "start", active = false, className, ...props }, ref) {
  return <div ref={ref} role={header ? "columnheader" : "gridcell"} aria-colindex={columnIndex === undefined ? undefined : columnIndex + 1} className={sx("sx-data-grid__cell", className)} data-sx-align={align} data-sx-active={active || undefined} {...props} />;
});

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
  sort?: { columnId: string; direction: "ascending" | "descending" };
  onSortChange?: (sort: { columnId: string; direction: "ascending" | "descending" }) => void;
  empty?: ReactNode;
}

export function DataGrid<Row>({ columns, rows, rowKey, label, selectedKeys, onRowActivate, sort, onSortChange, empty = "No records", className, ...props }: DataGridProps<Row>) {
  const [active, setActive] = useState({ row: 0, column: 0 });
  const refs = useRef<Array<Array<HTMLDivElement | null>>>([]);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const focus = (row: number, column: number) => {
    const next = { row: Math.max(0, Math.min(rows.length - 1, row)), column: Math.max(0, Math.min(columns.length - 1, column)) };
    setActive(next);
    refs.current[next.row]?.[next.column]?.focus();
  };
  const onCellKeyDown = (event: KeyboardEvent, row: number, column: number) => {
    if (event.key === "ArrowDown") { event.preventDefault(); focus(row + 1, column); }
    else if (event.key === "ArrowUp") { event.preventDefault(); focus(row - 1, column); }
    else if (event.key === "ArrowRight") { event.preventDefault(); focus(row, column + 1); }
    else if (event.key === "ArrowLeft") { event.preventDefault(); focus(row, column - 1); }
    else if (event.key === "Home") { event.preventDefault(); focus(row, 0); }
    else if (event.key === "End") { event.preventDefault(); focus(row, columns.length - 1); }
    else if (event.key === "PageDown" || event.key === "PageUp") {
      event.preventDefault();
      const rowHeight = refs.current[0]?.[0]?.parentElement?.getBoundingClientRect().height || 40;
      const page = Math.max(1, Math.floor((rootRef.current?.getBoundingClientRect().height || rowHeight) / rowHeight));
      focus(row + (event.key === "PageDown" ? page : -page), column);
    }
    else if ((event.key === "Enter" || event.key === " ") && rows[row]) { event.preventDefault(); onRowActivate?.(rows[row], row); }
  };
  const template = columns.map((column) => column.width ?? "minmax(0, 1fr)").join(" ");
  return (
    <DataGridRoot ref={rootRef} columns={columns.length} rowCount={Math.max(1, rows.length) + 1} label={label} columnTemplate={template} className={className} {...props}>
      <DataGridHeader><DataGridRow rowIndex={0}>{columns.map((column, index) => <DataGridCell key={column.id} header columnIndex={index} align={column.align} aria-sort={sort?.columnId === column.id ? sort.direction : undefined}>{column.sortable && onSortChange ? <button type="button" className="sx-data-grid__sort" onClick={() => onSortChange({ columnId: column.id, direction: sort?.columnId === column.id && sort.direction === "ascending" ? "descending" : "ascending" })}>{column.header}<span className="sx-data-grid__sort-icon" aria-hidden="true" /></button> : column.header}</DataGridCell>)}</DataGridRow></DataGridHeader>
      <DataGridBody>{rows.length === 0 ? <DataGridRow rowIndex={1}><DataGridCell columnIndex={0} aria-colspan={Math.max(1, columns.length)} tabIndex={0} className="sx-data-grid__empty">{empty}</DataGridCell></DataGridRow> : rows.map((row, rowIndex) => { const key = rowKey(row, rowIndex); return <DataGridRow key={key} rowIndex={rowIndex + 1} selected={selectedKeys?.has(key)}>{columns.map((column, columnIndex) => <DataGridCell key={column.id} ref={(node) => { const rowRefs = refs.current[rowIndex] ?? []; rowRefs[columnIndex] = node; refs.current[rowIndex] = rowRefs; }} columnIndex={columnIndex} align={column.align} active={active.row === rowIndex && active.column === columnIndex} tabIndex={active.row === rowIndex && active.column === columnIndex ? 0 : -1} onFocus={() => setActive({ row: rowIndex, column: columnIndex })} onKeyDown={(event) => onCellKeyDown(event, rowIndex, columnIndex)} onDoubleClick={() => onRowActivate?.(row, rowIndex)}>{column.cell(row, rowIndex)}</DataGridCell>)}</DataGridRow>; })}</DataGridBody>
    </DataGridRoot>
  );
}
