import { type HTMLAttributes, type ReactNode } from "react";
export interface CommandItem {
    id: string;
    label: ReactNode;
    description?: ReactNode;
    group?: string;
    icon?: ReactNode;
    keywords?: readonly string[];
    shortcut?: readonly string[];
    disabled?: boolean;
    onSelect: () => void | Promise<void>;
}
export interface CommandPaletteProps extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
    commands: readonly CommandItem[];
    open?: boolean;
    defaultOpen?: boolean;
    onOpenChange?: (open: boolean) => void;
    title?: string;
    placeholder?: string;
    empty?: ReactNode;
    query?: string;
    defaultQuery?: string;
    onQueryChange?: (query: string) => void;
    onCommandError?: (command: CommandItem, error: unknown) => void;
}
export declare function CommandPalette({ commands, open, defaultOpen, onOpenChange, title, placeholder, empty, query, defaultQuery, onQueryChange, onCommandError, className, ...props }: CommandPaletteProps): import("react").JSX.Element;
export interface SearchListItem {
    id: string;
    label: ReactNode;
    description?: ReactNode;
    keywords?: readonly string[];
    disabled?: boolean;
}
export interface SearchListProps extends Omit<HTMLAttributes<HTMLDivElement>, "onSelect"> {
    items: readonly SearchListItem[];
    onSelect: (item: SearchListItem) => void;
    label?: string;
    placeholder?: string;
    empty?: ReactNode;
    renderItem?: (item: SearchListItem, active: boolean) => ReactNode;
}
export declare function SearchList({ items, onSelect, label, placeholder, empty, renderItem, className, ...props }: SearchListProps): import("react").JSX.Element;
