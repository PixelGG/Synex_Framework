import { type ButtonHTMLAttributes, type DragEvent, type HTMLAttributes, type ReactNode } from "react";
export interface DragPayload {
    type: string;
    id: string;
}
export interface DragSourceOptions {
    disabled?: boolean;
    effectAllowed?: DataTransfer["effectAllowed"];
    onDragStateChange?: (dragging: boolean) => void;
}
export declare function useDragSource(payload: DragPayload, options?: DragSourceOptions): {
    draggable: boolean;
    "data-sx-dragging": true | undefined;
    onDragStart(event: DragEvent<HTMLElement>): void;
    onDragEnd(): void;
};
export interface DropTargetOptions {
    accepts: readonly string[];
    disabled?: boolean;
    dropEffect?: DataTransfer["dropEffect"];
    onDrop: (payload: DragPayload) => void;
    onHoverChange?: (hovering: boolean) => void;
}
export declare function useDropTarget(options: DropTargetOptions): {
    "data-sx-drop-active": true | undefined;
    onDragOver(event: DragEvent<HTMLElement>): void;
    onDragLeave(event: DragEvent<HTMLElement>): void;
    onDrop(event: DragEvent<HTMLElement>): void;
};
export interface DragHandleProps extends ButtonHTMLAttributes<HTMLButtonElement> {
    label?: string;
}
export declare const DragHandle: import("react").ForwardRefExoticComponent<DragHandleProps & import("react").RefAttributes<HTMLButtonElement>>;
export declare const DragPreview: import("react").ForwardRefExoticComponent<HTMLAttributes<HTMLDivElement> & import("react").RefAttributes<HTMLDivElement>>;
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
export declare function ReorderList({ items, onReorder, label, announcement, className, ...props }: ReorderListProps): import("react").JSX.Element;
