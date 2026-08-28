import { useState } from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import {
  AlertDialog,
  Button,
  DataGrid,
  Dialog,
  LoadingOverlay,
  Menu,
  MultiSelect,
  ProgressBar,
  ReorderList,
  SegmentedControl,
  Spacer,
  SplitButton,
  Switch,
  Tabs,
  VirtualList,
  VirtualGrid,
} from '../src/index';

describe('component interaction contracts', () => {
  it('uses roving focus and automatic activation for tabs', async () => {
    const user = userEvent.setup();
    render(<Tabs label="Runtime state" items={[
      { value: 'leases', label: 'Leases', content: 'Lease content' },
      { value: 'surfaces', label: 'Surfaces', content: 'Surface content' },
      { value: 'disabled', label: 'Disabled', content: 'Hidden', disabled: true },
    ]} />);
    const leases = screen.getByRole('tab', { name: 'Leases' });
    leases.focus();
    await user.keyboard('{ArrowRight}');
    expect(screen.getByRole('tab', { name: 'Surfaces' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('tabpanel')).toHaveTextContent('Surface content');
  });

  it('changes a segmented value through arrow-key navigation', async () => {
    const user = userEvent.setup();
    render(<SegmentedControl label="Focus mode" defaultValue="passive" options={[
      { value: 'passive', label: 'Passive' },
      { value: 'keyboard', label: 'Keyboard' },
      { value: 'exclusive', label: 'Exclusive' },
    ]} />);
    const passive = screen.getByRole('radio', { name: 'Passive' });
    passive.focus();
    await user.keyboard('{ArrowRight}');
    expect(screen.getByRole('radio', { name: 'Keyboard' })).toHaveAttribute('aria-checked', 'true');
  });

  it('closes a modal with Escape and restores focus to its trigger', async () => {
    const user = userEvent.setup();
    function Fixture() {
      const [open, setOpen] = useState(false);
      return <><Button onClick={() => setOpen(true)}>Open lease</Button><Dialog open={open} onOpenChange={setOpen} title="Lease"><Button>Inside</Button></Dialog></>;
    }
    render(<Fixture />);
    const trigger = screen.getByRole('button', { name: 'Open lease' });
    await user.click(trigger);
    expect(screen.getByRole('dialog', { name: 'Lease' })).toBeInTheDocument();
    await user.keyboard('{Escape}');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });

  it('places initial dialog focus inside and traps Tab in both directions', async () => {
    const user = userEvent.setup();
    render(<Dialog open title="Focus boundary"><Button>First action</Button><Button>Last action</Button></Dialog>);
    const first = screen.getByRole('button', { name: 'Close dialog' });
    const last = screen.getByRole('button', { name: 'Last action' });
    await waitFor(() => expect(first).toHaveFocus());

    last.focus();
    await user.tab();
    expect(first).toHaveFocus();
    await user.tab({ shift: true });
    expect(last).toHaveFocus();
  });

  it('gives a destructive alert a safe cancel-first focus target', async () => {
    render(
      <AlertDialog
        open
        title="Delete runtime state?"
        description="This cannot be undone."
        confirmLabel="Delete"
        cancelLabel="Keep state"
        destructive
        onConfirm={() => undefined}
      />,
    );
    await waitFor(() => expect(screen.getByRole('button', { name: 'Keep state' })).toHaveFocus());
  });

  it('closes only the topmost nested dialog for each Escape press', async () => {
    const user = userEvent.setup();
    function Fixture() {
      const [outerOpen, setOuterOpen] = useState(false);
      const [innerOpen, setInnerOpen] = useState(false);
      return <>
        <Button onClick={() => setOuterOpen(true)}>Open outer</Button>
        <Dialog open={outerOpen} onOpenChange={setOuterOpen} title="Outer dialog">
          <Button onClick={() => setInnerOpen(true)}>Open inner</Button>
          <Dialog open={innerOpen} onOpenChange={setInnerOpen} title="Inner dialog"><Button>Inner action</Button></Dialog>
        </Dialog>
      </>;
    }
    render(<Fixture />);
    const outerTrigger = screen.getByRole('button', { name: 'Open outer' });
    await user.click(outerTrigger);
    const innerTrigger = screen.getByRole('button', { name: 'Open inner' });
    await user.click(innerTrigger);
    expect(screen.getAllByRole('dialog')).toHaveLength(2);

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('dialog', { name: 'Inner dialog' })).not.toBeInTheDocument();
    expect(screen.getByRole('dialog', { name: 'Outer dialog' })).toBeInTheDocument();
    expect(innerTrigger).toHaveFocus();

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(outerTrigger).toHaveFocus();
  });

  it('derives an accessible switch name and description from visible copy', () => {
    render(<Switch label="Enable diagnostics" description="Adds bounded client telemetry." />);
    expect(screen.getByRole('switch', { name: 'Enable diagnostics' })).toHaveAccessibleDescription('Adds bounded client telemetry.');
  });

  it('contains submenu keyboard events and restores focus to the parent trigger', async () => {
    const user = userEvent.setup();
    const onRootClose = vi.fn();
    render(<Menu label="Root actions" onClose={onRootClose} items={[
      {
        type: 'submenu',
        id: 'tools',
        label: 'Tools',
        items: [
          { id: 'inspect', label: 'Inspect', onSelect: vi.fn() },
          { id: 'repair', label: 'Repair', onSelect: vi.fn() },
        ],
      },
      { id: 'exit', label: 'Exit', onSelect: vi.fn() },
    ]} />);

    const parentTrigger = screen.getByRole('menuitem', { name: 'Tools' });
    await user.click(parentTrigger);
    expect(screen.getByRole('menu', { name: 'Root actions submenu' })).toBeInTheDocument();
    expect(screen.getByRole('menuitem', { name: 'Inspect' })).toHaveFocus();

    await user.keyboard('{ArrowDown}');
    expect(screen.getByRole('menuitem', { name: 'Repair' })).toHaveFocus();
    expect(screen.getByRole('menuitem', { name: 'Exit' })).not.toHaveFocus();

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('menu', { name: 'Root actions submenu' })).not.toBeInTheDocument();
    expect(screen.getByRole('menu', { name: 'Root actions' })).toBeInTheDocument();
    expect(onRootClose).not.toHaveBeenCalled();
    expect(parentTrigger).toHaveFocus();
  });

  it('closes a submenu before its containing dialog', async () => {
    const user = userEvent.setup();
    function Fixture() {
      const [open, setOpen] = useState(false);
      return <>
        <Button onClick={() => setOpen(true)}>Open menu surface</Button>
        <Dialog open={open} onOpenChange={setOpen} title="Menu surface">
          <Menu label="Surface actions" items={[{
            type: 'submenu',
            id: 'tools',
            label: 'Tools',
            items: [{ id: 'inspect', label: 'Inspect', onSelect: vi.fn() }],
          }]} />
        </Dialog>
      </>;
    }
    render(<Fixture />);
    await user.click(screen.getByRole('button', { name: 'Open menu surface' }));
    await user.click(screen.getByRole('menuitem', { name: 'Tools' }));
    expect(screen.getByRole('menu', { name: 'Surface actions submenu' })).toBeInTheDocument();

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('menu', { name: 'Surface actions submenu' })).not.toBeInTheDocument();
    expect(screen.getByRole('dialog', { name: 'Menu surface' })).toBeInTheDocument();

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('dialog', { name: 'Menu surface' })).not.toBeInTheDocument();
  });

  it('closes a split-button menu with Escape and restores its menu trigger focus', async () => {
    const user = userEvent.setup();
    render(
      <SplitButton
        menuLabel="Open deployment actions"
        menu={<Menu label="Deployment actions" items={[{ id: 'inspect', label: 'Inspect', onSelect: vi.fn() }]} />}
      >
        Deploy
      </SplitButton>,
    );

    const menuTrigger = screen.getByRole('button', { name: 'Open deployment actions' });
    await user.click(menuTrigger);
    expect(screen.getByRole('menu', { name: 'Deployment actions' })).toBeInTheDocument();
    expect(screen.getByRole('menuitem', { name: 'Inspect' })).toHaveFocus();

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('menu', { name: 'Deployment actions' })).not.toBeInTheDocument();
    expect(menuTrigger).toHaveFocus();
  });

  it('preserves the Spacer base class when a consumer class is provided', () => {
    render(<Spacer data-testid="spacer" className="consumer-spacer" size={24} />);
    expect(screen.getByTestId('spacer')).toHaveClass('sx-spacer', 'consumer-spacer');
  });

  it('exposes a checkbox-dialog pattern for multi-select and restores focus on Escape', async () => {
    const user = userEvent.setup();
    render(<MultiSelect aria-label="Runtime owners" options={[
      { value: 'alpha', label: 'Alpha owner' },
      { value: 'bravo', label: 'Bravo owner' },
    ]} />);

    const trigger = screen.getByRole('button', { name: 'Runtime owners' });
    expect(trigger).toHaveAttribute('aria-haspopup', 'dialog');
    await user.click(trigger);
    expect(screen.getByRole('dialog', { name: 'Runtime owners' })).toBeInTheDocument();
    expect(screen.getByRole('searchbox', { name: 'Filter options' })).toHaveFocus();
    expect(screen.getByRole('group', { name: 'Options' })).toBeInTheDocument();

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('dialog', { name: 'Runtime owners' })).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });

  it('supports keyboard reordering with an announced result', () => {
    const onReorder = vi.fn();
    render(<ReorderList label="Input order" items={[
      { id: 'pointer', content: 'Pointer' },
      { id: 'keyboard', content: 'Keyboard' },
    ]} onReorder={onReorder} />);
    const handles = screen.getAllByRole('button', { name: 'Drag to reorder' });
    fireEvent.keyDown(handles[1]!, { key: 'ArrowUp', altKey: true });
    expect(onReorder).toHaveBeenCalledWith(expect.arrayContaining([
      expect.objectContaining({ id: 'keyboard' }),
      expect.objectContaining({ id: 'pointer' }),
    ]));
    expect(screen.getByText('keyboard moved to position 1')).toBeInTheDocument();
  });

  it('renders only a bounded subset of a virtual list', () => {
    const items = Array.from({ length: 500 }, (_, index) => ({ id: String(index), label: `Row ${index}` }));
    render(<VirtualList items={items} itemKey={(item) => item.id} itemSize={40} height={200} ariaLabel="Large list" renderItem={(item) => item.label} />);
    expect(screen.getByRole('list', { name: 'Large list' })).toBeInTheDocument();
    expect(screen.getAllByRole('listitem').length).toBeLessThan(30);
  });

  it('owns virtual grid cells through rows, keeps the empty track non-negative, and preserves arrow focus', async () => {
    const user = userEvent.setup();
    const view = render(<VirtualGrid items={[]} itemKey={(item: { id: string }) => item.id} minimumColumnWidth={160} rowHeight={40} height={120} ariaLabel="Virtual owners" renderItem={(item) => item.id} />);
    const emptyGrid = screen.getByRole('grid', { name: 'Virtual owners' });
    expect(emptyGrid).toHaveAttribute('aria-rowcount', '0');
    expect(emptyGrid.querySelector<HTMLElement>('.sx-virtual-grid__track')?.style.getPropertyValue('--sx-virtual-total')).toBe('0px');
    expect(screen.queryByRole('gridcell')).not.toBeInTheDocument();

    const items = [{ id: 'alpha' }, { id: 'bravo' }, { id: 'charlie' }];
    view.rerender(<VirtualGrid items={items} itemKey={(item) => item.id} minimumColumnWidth={160} rowHeight={40} height={120} ariaLabel="Virtual owners" renderItem={(item) => item.id} />);
    const cells = screen.getAllByRole('gridcell');
    expect(cells).toHaveLength(3);
    for (const cell of cells) expect(cell.parentElement).toHaveAttribute('role', 'row');
    cells[0]?.focus();
    await user.keyboard('{ArrowDown}');
    expect(cells[1]).toHaveFocus();
  });

  it('represents an empty data grid as a row with one spanning, focusable grid cell', () => {
    render(<DataGrid<{ owner: string; mode: string }>
      columns={[
        { id: 'owner', header: 'Owner', cell: (row) => row.owner },
        { id: 'mode', header: 'Mode', cell: (row) => row.mode },
      ]}
      rows={[]}
      rowKey={(_row, index) => String(index)}
      label="Focus leases"
      empty="No focus leases"
    />);
    const grid = screen.getByRole('grid', { name: 'Focus leases' });
    const emptyCell = screen.getByRole('gridcell', { name: 'No focus leases' });
    expect(grid).toHaveAttribute('aria-rowcount', '2');
    expect(emptyCell.parentElement).toHaveAttribute('role', 'row');
    expect(emptyCell.parentElement).toHaveAttribute('aria-rowindex', '2');
    expect(emptyCell).toHaveAttribute('aria-colspan', '2');
    expect(emptyCell).toHaveAttribute('tabindex', '0');
    expect(emptyCell.querySelector('.sx-data-grid__content')).toHaveTextContent('No focus leases');
  });

  it('unmounts a closed loading overlay completely', () => {
    const { container } = render(<LoadingOverlay visible={false} label="Loading" />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders determinate progress with a compositor-safe scale transform', () => {
    render(<ProgressBar label="Migration progress" value={25} maximum={50} />);
    const fill = document.querySelector<HTMLElement>('.sx-progress__fill');
    expect(fill?.style.getPropertyValue('--sx-progress-ratio')).toBe('0.5');
    expect(fill?.style.width).toBe('');
  });
});
