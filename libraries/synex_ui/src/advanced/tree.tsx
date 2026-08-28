import { useMemo, useRef, useState, type HTMLAttributes, type ReactNode } from "react";
import { styleVars, sx, useControllableState } from "../internal.js";

export interface TreeNode {
  id: string;
  label: ReactNode;
  icon?: ReactNode;
  disabled?: boolean;
  children?: readonly TreeNode[];
}

interface FlatNode {
  node: TreeNode;
  depth: number;
  parentId?: string;
}

function flatten(nodes: readonly TreeNode[], expanded: ReadonlySet<string>, depth = 1, parentId?: string): FlatNode[] {
  const output: FlatNode[] = [];
  for (const node of nodes) {
    output.push({ node, depth, ...(parentId ? { parentId } : {}) });
    if (node.children?.length && expanded.has(node.id)) output.push(...flatten(node.children, expanded, depth + 1, node.id));
  }
  return output;
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

export function Tree({ nodes, selectedId, defaultSelectedId = "", onSelectedIdChange, expandedIds, defaultExpandedIds = new Set(), onExpandedIdsChange, label, className, ...props }: TreeProps) {
  const [selected, setSelected] = useControllableState({ value: selectedId, defaultValue: defaultSelectedId, onChange: onSelectedIdChange });
  const [expanded, setExpanded] = useControllableState<ReadonlySet<string>>({ value: expandedIds, defaultValue: defaultExpandedIds, onChange: onExpandedIdsChange });
  const flat = useMemo(() => flatten(nodes, expanded), [expanded, nodes]);
  const [focused, setFocused] = useState(0);
  const refs = useRef<Array<HTMLButtonElement | null>>([]);
  const toggle = (id: string) => setExpanded((current) => { const next = new Set(current); if (next.has(id)) next.delete(id); else next.add(id); return next; });
  const move = (index: number, direction = index >= focused ? 1 : -1) => {
    if (flat.length === 0) return;
    let next = Math.min(flat.length - 1, Math.max(0, index));
    while (flat[next]?.node.disabled && next + direction >= 0 && next + direction < flat.length) next += direction;
    if (flat[next]?.node.disabled) {
      const fallback = flat.findIndex((entry) => !entry.node.disabled);
      if (fallback < 0) return;
      next = fallback;
    }
    setFocused(next);
    refs.current[next]?.focus();
  };
  return (
    <div role="tree" aria-label={label} className={sx("sx-tree", className)} {...props}>
      {flat.map(({ node, depth, parentId }, index) => {
        const branch = Boolean(node.children?.length);
        const open = branch && expanded.has(node.id);
        return <div key={node.id} role="treeitem" aria-level={depth} aria-selected={selected === node.id} aria-expanded={branch ? open : undefined} aria-disabled={node.disabled || undefined} className="sx-tree__item" data-sx-depth={depth} style={styleVars({ "--sx-tree-indent": `${(depth - 1) * 16}px` })}><button ref={(element) => { refs.current[index] = element; }} type="button" className="sx-tree__row" disabled={node.disabled} tabIndex={focused === index ? 0 : -1} onFocus={() => setFocused(index)} onClick={() => { setSelected(node.id); if (branch) toggle(node.id); }} onKeyDown={(event) => { if (event.key === "ArrowDown") { event.preventDefault(); move(index + 1); } else if (event.key === "ArrowUp") { event.preventDefault(); move(index - 1); } else if (event.key === "ArrowRight") { event.preventDefault(); if (branch && !open) toggle(node.id); else if (open) move(index + 1); } else if (event.key === "ArrowLeft") { event.preventDefault(); if (open) toggle(node.id); else if (parentId) { const parent = flat.findIndex((entry) => entry.node.id === parentId); if (parent >= 0) move(parent); } } else if (event.key === "Home") { event.preventDefault(); move(0); } else if (event.key === "End") { event.preventDefault(); move(flat.length - 1); } }}><span className="sx-tree__indent" aria-hidden="true" /><span className="sx-tree__disclosure" aria-hidden="true">{branch ? <span className="sx-icon sx-icon--chevron" /> : null}</span>{node.icon ? <span className="sx-tree__icon" aria-hidden="true">{node.icon}</span> : null}<span className="sx-tree__label">{node.label}</span></button></div>;
      })}
    </div>
  );
}
