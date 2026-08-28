import {
  forwardRef,
  useState,
  type ButtonHTMLAttributes,
  type DragEvent,
  type HTMLAttributes,
  type ReactNode,
} from "react";
import { sx } from "../internal.js";

const SYNEX_DRAG_MIME = "application/x-synex-ui-drag";

export interface DragPayload {
  type: string;
  id: string;
}

function isDragPayload(value: unknown): value is DragPayload {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Record<string, unknown>;
  return typeof candidate.type === "string" && candidate.type.length > 0 && candidate.type.length <= 64 && typeof candidate.id === "string" && candidate.id.length > 0 && candidate.id.length <= 256;
}

export interface DragSourceOptions {
  disabled?: boolean;
  effectAllowed?: DataTransfer["effectAllowed"];
  onDragStateChange?: (dragging: boolean) => void;
}

export function useDragSource(payload: DragPayload, options: DragSourceOptions = {}) {
  const disabled = options.disabled ?? false;
  const [dragging, setDragging] = useState(false);
  const update = (next: boolean) => {
    setDragging(next);
    options.onDragStateChange?.(next);
  };
  return {
    draggable: !disabled,
    "data-sx-dragging": dragging || undefined,
    onDragStart(event: DragEvent<HTMLElement>) {
      if (disabled) { event.preventDefault(); return; }
      event.dataTransfer.effectAllowed = options.effectAllowed ?? "move";
      event.dataTransfer.setData(SYNEX_DRAG_MIME, JSON.stringify(payload));
      update(true);
    },
    onDragEnd() { update(false); },
  };
}

export interface DropTargetOptions {
  accepts: readonly string[];
  disabled?: boolean;
  dropEffect?: DataTransfer["dropEffect"];
  onDrop: (payload: DragPayload) => void;
  onHoverChange?: (hovering: boolean) => void;
}

export function useDropTarget(options: DropTargetOptions) {
  const [hovering, setHovering] = useState(false);
  const updateHover = (next: boolean) => { setHovering(next); options.onHoverChange?.(next); };
  const read = (event: DragEvent<HTMLElement>): DragPayload | null => {
    try {
      const parsed: unknown = JSON.parse(event.dataTransfer.getData(SYNEX_DRAG_MIME));
      return isDragPayload(parsed) && options.accepts.includes(parsed.type) ? parsed : null;
    } catch { return null; }
  };
  return {
    "data-sx-drop-active": hovering || undefined,
    onDragOver(event: DragEvent<HTMLElement>) {
      if (options.disabled) return;
      if (!event.dataTransfer.types.includes(SYNEX_DRAG_MIME)) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = options.dropEffect ?? "move";
      if (!hovering) updateHover(true);
    },
    onDragLeave(event: DragEvent<HTMLElement>) {
      if (!event.currentTarget.contains(event.relatedTarget as Node | null)) updateHover(false);
    },
    onDrop(event: DragEvent<HTMLElement>) {
      event.preventDefault();
      updateHover(false);
      const payload = read(event);
      if (payload) options.onDrop(payload);
    },
  };
}

export interface DragHandleProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  label?: string;
}

export const DragHandle = forwardRef<HTMLButtonElement, DragHandleProps>(function DragHandle(
  { label = "Drag to reorder", className, ...props },
  ref,
) {
  return <button ref={ref} type="button" className={sx("sx-drag-handle", className)} aria-label={label} {...props}><span className="sx-drag-handle__grip" aria-hidden="true" /></button>;
});

export const DragPreview = forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(function DragPreview(
  { className, ...props },
  ref,
) {
  return <div ref={ref} className={sx("sx-drag-preview", className)} aria-hidden="true" {...props} />;
});

export interface ReorderItem {
  id: string;
  content: ReactNode;
  disabled?: boolean;
}

export interface ReorderListProps extends Omit<HTMLAttributes<HTMLUListElement>, "onChange"> {
  items: readonly ReorderItem[];
  onReorder: (items: readonly ReorderItem[]) => void;
  label: string;
  announcement?: (item: ReorderItem, from: number, to: number) => string;
}

interface ReorderListItemProps {
  item: ReorderItem;
  index: number;
  findIndex: (id: string) => number;
  move: (from: number, to: number) => void;
}

function ReorderListItem({ item, index, findIndex, move }: ReorderListItemProps) {
  const source = useDragSource({ type: "reorder-item", id: item.id }, { disabled: item.disabled });
  const target = useDropTarget({
    accepts: ["reorder-item"],
    onDrop: (payload) => move(findIndex(payload.id), index),
  });
  return (
    <li className="sx-reorder-list__item" {...source} {...target}>
      <DragHandle
        disabled={item.disabled}
        onKeyDown={(event) => {
          if (event.altKey && event.key === "ArrowUp") {
            event.preventDefault();
            move(index, index - 1);
          } else if (event.altKey && event.key === "ArrowDown") {
            event.preventDefault();
            move(index, index + 1);
          }
        }}
      />
      <div className="sx-reorder-list__content">{item.content}</div>
    </li>
  );
}

export function ReorderList({ items, onReorder, label, announcement = (item, _from, to) => `${item.id} moved to position ${to + 1}`, className, ...props }: ReorderListProps) {
  const [message, setMessage] = useState("");
  const move = (from: number, to: number) => {
    if (from === to || to < 0 || to >= items.length || items[from]?.disabled) return;
    const next = [...items];
    const [item] = next.splice(from, 1);
    if (!item) return;
    next.splice(to, 0, item);
    onReorder(next);
    setMessage(announcement(item, from, to));
  };
  return <><ul className={sx("sx-reorder-list", className)} aria-label={label} {...props}>{items.map((item, index) => <ReorderListItem key={item.id} item={item} index={index} findIndex={(id) => items.findIndex((entry) => entry.id === id)} move={move} />)}</ul><div className="sx-visually-hidden" aria-live="polite">{message}</div></>;
}
