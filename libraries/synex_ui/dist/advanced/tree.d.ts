import { type HTMLAttributes, type ReactNode } from "react";
export interface TreeNode {
    id: string;
    label: ReactNode;
    icon?: ReactNode;
    disabled?: boolean;
    children?: readonly TreeNode[];
}
export interface TreeProps extends Omit<HTMLAttributes<HTMLDivElement>, "onSelect"> {
    nodes: readonly TreeNode[];
    selectedId?: string;
    defaultSelectedId?: string;
    onSelectedIdChange?: (id: string) => void;
    expandedIds?: ReadonlySet<string>;
    defaultExpandedIds?: ReadonlySet<string>;
    onExpandedIdsChange?: (ids: ReadonlySet<string>) => void;
    label: string;
}
export declare function Tree({ nodes, selectedId, defaultSelectedId, onSelectedIdChange, expandedIds, defaultExpandedIds, onExpandedIdsChange, label, className, ...props }: TreeProps): import("react").JSX.Element;
