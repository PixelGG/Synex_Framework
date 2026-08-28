import { useMemo, useRef, useState, type HTMLAttributes, type KeyboardEvent, type ReactNode } from "react";
import { Dialog } from "../overlays.js";
import { SearchInput } from "../forms.js";
import { KeyHint } from "../utilities.js";
import { normalizedText, rovingKey, sx, useControllableState, useStableId } from "../internal.js";

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

export function CommandPalette({
  commands,
  open,
  defaultOpen = false,
  onOpenChange,
  title = "Command palette",
  placeholder = "Type a command",
  empty = "No commands found",
  query,
  defaultQuery = "",
  onQueryChange,
  onCommandError,
  className,
  ...props
}: CommandPaletteProps) {
  const [visible, setVisible] = useControllableState({ value: open, defaultValue: defaultOpen, onChange: onOpenChange });
  const [search, setSearch] = useControllableState({ value: query, defaultValue: defaultQuery, onChange: onQueryChange });
  const [active, setActive] = useState(0);
  const refs = useRef<Array<HTMLButtonElement | null>>([]);
  const filtered = useMemo(() => {
    const needle = search.trim().toLocaleLowerCase();
    if (!needle) return commands;
    return commands.filter((command) => [normalizedText(command.label), normalizedText(command.description), command.group?.toLocaleLowerCase() ?? "", ...(command.keywords ?? []).map((keyword) => keyword.toLocaleLowerCase())].some((value) => value.includes(needle)));
  }, [commands, search]);
  const choose = (command: CommandItem) => {
    if (command.disabled) return;
    void Promise.resolve()
      .then(command.onSelect)
      .then(() => setVisible(false))
      .catch((error: unknown) => onCommandError?.(command, error));
  };
  const onKeyDown = (event: KeyboardEvent) => {
    const next = rovingKey(event, { current: active, length: filtered.length, orientation: "vertical", isDisabled: (index) => filtered[index]?.disabled === true });
    if (next !== null) {
      setActive(next);
      refs.current[next]?.scrollIntoView({ block: "nearest" });
    } else if (event.key === "Enter") {
      const command = filtered[active];
      if (command) { event.preventDefault(); choose(command); }
    }
  };
  let lastGroup: string | undefined;
  return (
    <Dialog open={visible} onOpenChange={setVisible} title={title} size="lg" className={sx("sx-command-palette", className)} {...props}>
      <SearchInput autoFocus value={search} placeholder={placeholder} aria-label={placeholder} onChange={(event) => { setSearch(event.currentTarget.value); setActive(0); }} onClear={() => setSearch("")} onKeyDown={onKeyDown} />
      <div className="sx-command-palette__results" role="listbox" aria-label="Commands" onKeyDown={onKeyDown}>
        {filtered.length === 0 ? <div className="sx-command-palette__empty">{empty}</div> : filtered.map((command, index) => {
          const showGroup = command.group && command.group !== lastGroup;
          lastGroup = command.group;
          return <div key={command.id} className="sx-command-palette__entry">{showGroup ? <div className="sx-command-palette__group">{command.group}</div> : null}<button ref={(node) => { refs.current[index] = node; }} type="button" role="option" tabIndex={-1} className="sx-command-palette__command" aria-selected={active === index} disabled={command.disabled} onPointerMove={() => setActive(index)} onClick={() => choose(command)}>{command.icon ? <span className="sx-command-palette__icon" aria-hidden="true">{command.icon}</span> : null}<span className="sx-command-palette__copy"><span className="sx-command-palette__label">{command.label}</span>{command.description ? <span className="sx-command-palette__description">{command.description}</span> : null}</span>{command.shortcut ? <span className="sx-command-palette__shortcut">{command.shortcut.map((key) => <KeyHint key={key}>{key}</KeyHint>)}</span> : null}</button></div>;
        })}
      </div>
    </Dialog>
  );
}

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

export function SearchList({ items, onSelect, label = "Search list", placeholder = "Search", empty = "No results", renderItem, className, ...props }: SearchListProps) {
  const id = useStableId(undefined, "sx-search-list");
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const visible = items.filter((item) => [normalizedText(item.label), normalizedText(item.description), ...(item.keywords ?? [])].join(" ").toLocaleLowerCase().includes(query.toLocaleLowerCase()));
  const choose = (item: SearchListItem | undefined) => { if (item && !item.disabled) onSelect(item); };
  return <div className={sx("sx-search-list", className)} {...props}><SearchInput value={query} role="combobox" aria-label={label} aria-controls={`${id}-results`} aria-expanded="true" aria-activedescendant={visible[active] ? `${id}-option-${active}` : undefined} placeholder={placeholder} onChange={(event) => { setQuery(event.currentTarget.value); setActive(0); }} onClear={() => setQuery("")} onKeyDown={(event) => { const next = rovingKey(event, { current: active, length: visible.length, orientation: "vertical", isDisabled: (index) => visible[index]?.disabled === true }); if (next !== null) setActive(next); else if (event.key === "Enter") choose(visible[active]); }} /><div id={`${id}-results`} role="listbox" aria-label={label} className="sx-search-list__results">{visible.length === 0 ? <div className="sx-search-list__empty">{empty}</div> : visible.map((item, index) => <button key={item.id} id={`${id}-option-${index}`} type="button" role="option" aria-selected={active === index} className="sx-search-list__item" disabled={item.disabled} tabIndex={-1} onPointerMove={() => setActive(index)} onClick={() => choose(item)}>{renderItem ? renderItem(item, active === index) : <><span className="sx-search-list__label">{item.label}</span>{item.description ? <span className="sx-search-list__description">{item.description}</span> : null}</>}</button>)}</div></div>;
}
