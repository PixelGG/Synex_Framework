import {
  forwardRef,
  type HTMLAttributes,
  type ImgHTMLAttributes,
  type ReactNode,
  type TableHTMLAttributes,
} from "react";
import { sx, type SynexSize, type SynexTone } from "./internal.js";

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
  sort?: { columnId: string; direction: "ascending" | "descending" };
  onSortChange?: (sort: { columnId: string; direction: "ascending" | "descending" }) => void;
}

export function Table<Row>({ columns, rows, rowKey, caption, empty = "No records", selectedKeys, onRowActivate, sort, onSortChange, className, ...props }: TableProps<Row>) {
  return (
    <div className="sx-table-frame">
      <table className={sx("sx-table", className)} {...props}>
        {caption ? <caption>{caption}</caption> : null}
        <thead><tr>{columns.map((column) => (
          <th key={column.id} scope="col" data-sx-align={column.align} style={column.width === undefined ? undefined : { width: column.width }} aria-sort={sort?.columnId === column.id ? sort.direction : undefined}>
            {column.sortable && onSortChange ? <button type="button" className="sx-table__sort" onClick={() => onSortChange({ columnId: column.id, direction: sort?.columnId === column.id && sort.direction === "ascending" ? "descending" : "ascending" })}>{column.header}<span className="sx-table__sort-indicator" aria-hidden="true" /></button> : column.header}
          </th>
        ))}</tr></thead>
        <tbody>{rows.length === 0 ? <tr><td colSpan={columns.length} className="sx-table__empty">{empty}</td></tr> : rows.map((row, rowIndex) => {
          const key = rowKey(row, rowIndex);
          return <tr key={key} data-sx-selected={selectedKeys?.has(key) || undefined} tabIndex={onRowActivate ? 0 : undefined} onClick={() => onRowActivate?.(row, rowIndex)} onKeyDown={(event) => { if (onRowActivate && (event.key === "Enter" || event.key === " ")) { event.preventDefault(); onRowActivate(row, rowIndex); } }}>{columns.map((column) => <td key={column.id} data-sx-align={column.align}>{column.cell(row, rowIndex)}</td>)}</tr>;
        })}</tbody>
      </table>
    </div>
  );
}

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

export const DataList = forwardRef<HTMLUListElement, DataListProps>(function DataList(
  { items, onItemActivate, empty = "No items", className, ...props },
  ref,
) {
  return <ul ref={ref} className={sx("sx-data-list", className)} {...props}>{items.length === 0 ? <li className="sx-data-list__empty">{empty}</li> : items.map((item) => <ListItem key={item.id} {...item} onActivate={onItemActivate ? () => onItemActivate(item) : undefined} />)}</ul>;
});

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

export const KeyValueList = forwardRef<HTMLDListElement, KeyValueListProps>(function KeyValueList(
  { items, onCopyValue, className, ...props },
  ref,
) {
  return <dl ref={ref} className={sx("sx-key-value-list", className)} {...props}>{items.map((item) => <div key={item.key} className="sx-key-value-list__item"><dt>{item.label}</dt><dd>{item.value}{item.copyable && onCopyValue ? <button type="button" className="sx-key-value-list__copy" aria-label={`Copy ${typeof item.label === "string" ? item.label : "value"}`} onClick={() => onCopyValue(item)}><span className="sx-icon sx-icon--copy" aria-hidden="true" /></button> : null}</dd></div>)}</dl>;
});

export interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: SynexTone;
  variant?: "soft" | "outline" | "solid";
  size?: "sm" | "md";
}

export const Badge = forwardRef<HTMLSpanElement, BadgeProps>(function Badge(
  { tone = "neutral", variant = "soft", size = "md", className, ...props },
  ref,
) {
  return <span ref={ref} className={sx("sx-badge", className)} data-sx-tone={tone} data-sx-variant={variant} data-sx-size={size} {...props} />;
});

export interface StatusBadgeProps extends Omit<BadgeProps, "tone"> {
  status: "online" | "offline" | "idle" | "busy" | "success" | "warning" | "error" | "unknown";
  pulse?: boolean;
}

const statusTone: Record<StatusBadgeProps["status"], SynexTone> = {
  online: "positive",
  offline: "neutral",
  idle: "warning",
  busy: "danger",
  success: "positive",
  warning: "warning",
  error: "danger",
  unknown: "neutral",
};

export const StatusBadge = forwardRef<HTMLSpanElement, StatusBadgeProps>(function StatusBadge(
  { status, pulse = false, children, className, ...props },
  ref,
) {
  return <Badge ref={ref} className={sx("sx-status-badge", className)} tone={statusTone[status]} data-sx-status={status} data-sx-pulse={pulse || undefined} {...props}><span className="sx-status-badge__dot" aria-hidden="true" />{children ?? status}</Badge>;
});

export interface StatProps extends HTMLAttributes<HTMLDivElement> {
  label: ReactNode;
  value: ReactNode;
  detail?: ReactNode;
  trend?: "up" | "down" | "flat";
  tone?: SynexTone;
}

export const Stat = forwardRef<HTMLDivElement, StatProps>(function Stat(
  { label, value, detail, trend, tone = "neutral", className, ...props },
  ref,
) {
  return <div ref={ref} className={sx("sx-stat", className)} data-sx-tone={tone} {...props}><span className="sx-stat__label">{label}</span><strong className="sx-stat__value">{value}</strong>{detail ? <span className="sx-stat__detail" data-sx-trend={trend}>{detail}</span> : null}</div>;
});

export interface MetricProps extends StatProps {
  unit?: ReactNode;
  progress?: number;
}

export const Metric = forwardRef<HTMLDivElement, MetricProps>(function Metric(
  { value, unit, progress, className, ...props },
  ref,
) {
  return <Stat ref={ref} className={sx("sx-metric", className)} value={<>{value}{unit ? <span className="sx-metric__unit">{unit}</span> : null}</>} data-sx-progress={progress} {...props} />;
});

export interface AvatarProps extends Omit<ImgHTMLAttributes<HTMLImageElement>, "size"> {
  name: string;
  size?: SynexSize | "xl";
  status?: StatusBadgeProps["status"];
}

export const Avatar = forwardRef<HTMLSpanElement, AvatarProps>(function Avatar(
  { name, src, alt, size = "md", status, className, ...imgProps },
  ref,
) {
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toLocaleUpperCase()).join("");
  return <span ref={ref} className={sx("sx-avatar", className)} data-sx-size={size} aria-label={name}>{src ? <img src={src} alt={alt ?? ""} {...imgProps} /> : <span className="sx-avatar__fallback" aria-hidden="true">{initials}</span>}{status ? <span className="sx-avatar__status" data-sx-status={status} aria-label={status} /> : null}</span>;
});

export interface ListItemProps extends HTMLAttributes<HTMLLIElement> {
  primary: ReactNode;
  secondary?: ReactNode;
  leading?: ReactNode;
  trailing?: ReactNode;
  disabled?: boolean;
  selected?: boolean;
  onActivate?: () => void;
}

export const ListItem = forwardRef<HTMLLIElement, ListItemProps>(function ListItem(
  { primary, secondary, leading, trailing, disabled = false, selected = false, onActivate, className, ...props },
  ref,
) {
  return (
    <li ref={ref} className={sx("sx-list-item", className)} data-sx-disabled={disabled || undefined} data-sx-selected={selected || undefined} {...props}>
      <div role={onActivate ? "button" : undefined} tabIndex={onActivate && !disabled ? 0 : undefined} className="sx-list-item__content" onClick={() => { if (!disabled) onActivate?.(); }} onKeyDown={(event) => { if (!disabled && onActivate && (event.key === "Enter" || event.key === " ")) { event.preventDefault(); onActivate(); } }}>
        {leading ? <span className="sx-list-item__leading">{leading}</span> : null}
        <span className="sx-list-item__copy"><span className="sx-list-item__primary">{primary}</span>{secondary ? <span className="sx-list-item__secondary">{secondary}</span> : null}</span>
        {trailing ? <span className="sx-list-item__trailing">{trailing}</span> : null}
      </div>
    </li>
  );
});
