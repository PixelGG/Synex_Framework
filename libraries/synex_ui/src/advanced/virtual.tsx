import {
  useMemo,
  useState,
  type CSSProperties,
  type HTMLAttributes,
  type ReactNode,
  type UIEvent,
} from "react";
import { clamp, styleVars, sx, useObservedSize } from "../internal.js";

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
  onVisibleRangeChange?: (range: { start: number; end: number }) => void;
}

export function VirtualList<Item>({
  items,
  itemKey,
  renderItem,
  itemSize,
  height,
  overscan = 4,
  ariaLabel,
  initialScrollOffset = 0,
  onVisibleRangeChange,
  className,
  style,
  onScroll,
  onKeyDown,
  tabIndex,
  ...props
}: VirtualListProps<Item>) {
  const [scrollTop, setScrollTop] = useState(initialScrollOffset);
  const { ref, height: measuredHeight } = useObservedSize<HTMLDivElement>();
  const viewportHeight = measuredHeight || (typeof height === "number" ? height : 0);
  const start = clamp(Math.floor(scrollTop / itemSize) - overscan, 0, Math.max(0, items.length - 1));
  const visibleCount = Math.ceil(viewportHeight / itemSize) + overscan * 2;
  const end = clamp(start + visibleCount, 0, items.length);
  const visible = useMemo(() => items.slice(start, end), [end, items, start]);
  const updateOffset = (next: number) => {
    const maximum = Math.max(0, items.length * itemSize - viewportHeight);
    const bounded = clamp(next, 0, maximum);
    if (ref.current) ref.current.scrollTop = bounded;
    setScrollTop(bounded);
    const nextStart = clamp(Math.floor(bounded / itemSize) - overscan, 0, Math.max(0, items.length - 1));
    onVisibleRangeChange?.({ start: nextStart, end: clamp(nextStart + visibleCount, 0, items.length) });
  };
  const handleScroll = (event: UIEvent<HTMLDivElement>) => {
    const next = event.currentTarget.scrollTop;
    const nextStart = clamp(Math.floor(next / itemSize) - overscan, 0, Math.max(0, items.length - 1));
    const nextEnd = clamp(nextStart + visibleCount, 0, items.length);
    setScrollTop(next);
    onVisibleRangeChange?.({ start: nextStart, end: nextEnd });
    onScroll?.(event);
  };
  return (
    <div ref={ref} role="list" aria-label={ariaLabel} tabIndex={tabIndex ?? 0} className={sx("sx-virtual-list", className)} style={{ height, ...style }} onScroll={handleScroll} onKeyDown={(event) => {
      onKeyDown?.(event);
      if (event.defaultPrevented) return;
      if (event.key === "PageDown" || event.key === "PageUp") {
        event.preventDefault();
        updateOffset(scrollTop + (event.key === "PageDown" ? viewportHeight : -viewportHeight));
      } else if (event.key === "Home" || event.key === "End") {
        event.preventDefault();
        updateOffset(event.key === "Home" ? 0 : Number.POSITIVE_INFINITY);
      }
    }} {...props}>
      <div className="sx-virtual-list__track" style={styleVars({ "--sx-virtual-total": `${items.length * itemSize}px` })}>
        {visible.map((item, visibleIndex) => {
          const index = start + visibleIndex;
          const itemStyle: CSSProperties = { position: "absolute", insetInline: 0, height: itemSize, transform: `translateY(${index * itemSize}px)` };
          return <div key={itemKey(item, index)} role="listitem" className="sx-virtual-list__item" style={itemStyle}>{renderItem(item, { index, style: itemStyle })}</div>;
        })}
      </div>
    </div>
  );
}

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

export function VirtualGrid<Item>({
  items,
  itemKey,
  renderItem,
  minimumColumnWidth,
  rowHeight,
  height,
  columnGap = 12,
  rowGap = 12,
  overscanRows = 2,
  ariaLabel,
  onItemActivate,
  className,
  style,
  onScroll,
  onKeyDown,
  ...props
}: VirtualGridProps<Item>) {
  const [scrollTop, setScrollTop] = useState(0);
  const [activeIndex, setActiveIndex] = useState(0);
  const { ref, width, height: measuredHeight } = useObservedSize<HTMLDivElement>();
  const columns = Math.max(1, Math.floor((width + columnGap) / (minimumColumnWidth + columnGap)));
  const columnWidth = width > 0 ? (width - columnGap * (columns - 1)) / columns : minimumColumnWidth;
  const stride = rowHeight + rowGap;
  const rows = Math.ceil(items.length / columns);
  const totalHeight = Math.max(0, rows * stride - rowGap);
  const viewportHeight = measuredHeight || (typeof height === "number" ? height : 0);
  const startRow = clamp(Math.floor(scrollTop / stride) - overscanRows, 0, Math.max(0, rows - 1));
  const endRow = clamp(startRow + Math.ceil(viewportHeight / stride) + overscanRows * 2, 0, rows);
  const focusIndex = (candidate: number) => {
    if (items.length === 0) return;
    const next = clamp(candidate, 0, items.length - 1);
    setActiveIndex(next);
    const row = Math.floor(next / columns);
    const rowTop = row * stride;
    let nextScroll = scrollTop;
    if (rowTop < scrollTop) nextScroll = rowTop;
    else if (rowTop + rowHeight > scrollTop + viewportHeight) nextScroll = rowTop + rowHeight - viewportHeight;
    if (nextScroll !== scrollTop) {
      const bounded = clamp(nextScroll, 0, Math.max(0, rows * stride - rowGap - viewportHeight));
      if (ref.current) ref.current.scrollTop = bounded;
      setScrollTop(bounded);
    }
    queueMicrotask(() => ref.current?.querySelector<HTMLElement>(`[data-sx-virtual-index="${next}"]`)?.focus());
  };
  return (
    <div ref={ref} role="grid" aria-label={ariaLabel} aria-rowcount={rows} aria-colcount={columns} className={sx("sx-virtual-grid", className)} style={{ height, ...style }} onScroll={(event) => { setScrollTop(event.currentTarget.scrollTop); onScroll?.(event); }} onKeyDown={(event) => { onKeyDown?.(event); }} {...props}>
      <div role="rowgroup" className="sx-virtual-grid__track" style={styleVars({ "--sx-virtual-total": `${totalHeight}px` })}>
        {Array.from({ length: Math.max(0, endRow - startRow) }, (_, visibleRowIndex) => {
          const row = startRow + visibleRowIndex;
          const rowStart = row * columns;
          const rowEnd = Math.min(items.length, rowStart + columns);
          if (rowStart >= rowEnd) return null;
          const rowStyle: CSSProperties = { position: "absolute", insetInline: 0, height: rowHeight, transform: `translateY(${row * stride}px)` };
          return (
            <div key={`row-${row}`} role="row" aria-rowindex={row + 1} className="sx-virtual-grid__row" style={rowStyle}>
              {items.slice(rowStart, rowEnd).map((item, column) => {
                const index = rowStart + column;
                const itemStyle: CSSProperties = { position: "absolute", width: columnWidth, height: rowHeight, transform: `translateX(${column * (columnWidth + columnGap)}px)` };
                const renderStyle: CSSProperties = { ...itemStyle, transform: `translate(${column * (columnWidth + columnGap)}px, ${row * stride}px)` };
                return <div
                  key={itemKey(item, index)}
                  role="gridcell"
                  aria-colindex={column + 1}
                  tabIndex={index === activeIndex ? 0 : -1}
                  data-sx-roving-item
                  data-sx-virtual-index={index}
                  className="sx-virtual-grid__item"
                  style={itemStyle}
                  onFocus={() => setActiveIndex(index)}
                  onClick={() => onItemActivate?.(item, index)}
                  onKeyDown={(event) => {
                    if (event.key === "ArrowDown") { event.preventDefault(); focusIndex(index + columns); }
                    else if (event.key === "ArrowUp") { event.preventDefault(); focusIndex(index - columns); }
                    else if (event.key === "ArrowRight") { event.preventDefault(); focusIndex(index + 1); }
                    else if (event.key === "ArrowLeft") { event.preventDefault(); focusIndex(index - 1); }
                    else if (event.key === "PageDown" || event.key === "PageUp") {
                      event.preventDefault();
                      const rowsPerPage = Math.max(1, Math.floor(viewportHeight / stride));
                      focusIndex(index + (event.key === "PageDown" ? rowsPerPage * columns : -rowsPerPage * columns));
                    } else if (event.key === "Home" || event.key === "End") {
                      event.preventDefault();
                      focusIndex(event.key === "Home" ? 0 : items.length - 1);
                    } else if ((event.key === "Enter" || event.key === " ") && onItemActivate) {
                      event.preventDefault();
                      onItemActivate(item, index);
                    }
                  }}
                >{renderItem(item, { index, row, column, style: renderStyle })}</div>;
              })}
            </div>
          );
        })}
      </div>
    </div>
  );
}
