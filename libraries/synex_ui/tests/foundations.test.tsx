import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import {
  Typography,
  formatCurrency,
  formatDate,
  formatNumber,
  formatPercent,
  formatTime,
  motionDurationMilliseconds,
  motionDurations,
  motionIntentSpeeds,
  motionTokens,
  motionTransition,
} from '../src/index';

const styles = readFileSync(resolve(process.cwd(), 'src/styles.css'), 'utf8');

describe('design token foundation', () => {
  it('publishes the opacity scale through semantic and component aliases', () => {
    for (const token of ['0', '1', '58', '65', '70', '72', '80', '100']) {
      expect(styles).toContain(`--sx-p-opacity-${token}:`);
    }
    expect(styles).toContain('--sx-opacity-disabled: var(--sx-p-opacity-65);');
    expect(styles).toContain('--sx-button-disabled-opacity: var(--sx-opacity-disabled-strong);');
    expect(styles).not.toMatch(/(?:^|[;{]\s*)opacity:\s*(?:0(?:\.\d+)?|1(?:\.0+)?)\s*[;}]/m);
  });

  it('keeps resting action hierarchy neutral and reserves route color for state', () => {
    expect(styles).toContain('--sx-button-bg: var(--sx-p-white);');
    expect(styles).toContain('--sx-button-hover: var(--sx-p-graphite-100);');
    expect(styles).toContain('.sx-button[data-sx-variant="outline"] { color: var(--sx-color-text-secondary);');
    expect(styles).toContain('.sx-select__control { width: 100%;');
    expect(styles).toContain('color: var(--sx-color-text); background: var(--sx-input-bg); color-scheme: dark;');
    expect(styles).not.toContain('--sx-button-bg: var(--sx-color-route');
  });
});

describe('formatting foundation', () => {
  it('formats numeric values with explicit locale and presentation', () => {
    expect(formatNumber(12_345.67, {
      locale: 'en-US',
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
      useGrouping: true,
    })).toBe('12,345.67');
    expect(formatPercent(0.1234, { locale: 'en-US', maximumFractionDigits: 1 })).toBe('12.3%');
  });

  it('keeps currency explicit and locale-aware', () => {
    expect(formatCurrency(1234.5, {
      locale: 'de-DE',
      currency: 'EUR',
      currencyDisplay: 'code',
      minimumFractionDigits: 2,
    })).toBe('1.234,50\u00a0EUR');
  });

  it('formats date and time against an explicit time zone', () => {
    const epoch = Date.UTC(2026, 7, 24, 16, 5, 9);
    expect(formatDate(epoch, {
      locale: 'en-GB',
      timeZone: 'UTC',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    })).toBe('24/08/2026');
    expect(formatTime(epoch, {
      locale: 'en-GB',
      timeZone: 'UTC',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false,
    })).toBe('16:05:09');
  });

  it('rejects non-finite numbers and invalid date values', () => {
    expect(() => formatNumber(Number.NaN, { locale: 'en-US' })).toThrow(TypeError);
    expect(() => formatDate(Number.NaN, { locale: 'en-US', timeZone: 'UTC' })).toThrow(TypeError);
  });
});

describe('typography foundation', () => {
  it('maps semantic variants to useful native elements and preserves consumer classes', () => {
    render(<>
      <Typography variant="heading-2">Runtime health</Typography>
      <Typography as="output" variant="numeric" className="telemetry-value">128</Typography>
    </>);
    expect(screen.getByRole('heading', { level: 2, name: 'Runtime health' })).toHaveClass('sx-typography', 'sx-type-heading-2');
    expect(screen.getByText('128')).toHaveClass('sx-typography', 'sx-type-numeric', 'telemetry-value');
    expect(screen.getByText('128').tagName).toBe('OUTPUT');
  });

  it('exposes the complete semantic typography role set', () => {
    const variants = ['display', 'heading-1', 'heading-2', 'heading-3', 'body', 'body-small', 'caption', 'label', 'numeric', 'code', 'monospace'] as const;
    const { container } = render(<>{variants.map((variant) => <Typography key={variant} variant={variant}>{variant}</Typography>)}</>);
    for (const variant of variants) {
      expect(container.querySelector(`[data-sx-typography="${variant}"]`)).toHaveClass(`sx-type-${variant}`);
    }
  });
});

describe('motion foundation', () => {
  it('publishes stable speed and semantic intent contracts', () => {
    expect(motionDurationMilliseconds).toEqual({ instant: 0, fast: 110, normal: 180, slow: 280 });
    expect(motionDurations.normal).toBe('var(--sx-motion-duration-normal)');
    expect(Object.keys(motionTokens)).toEqual(['enter', 'exit', 'focus', 'selection', 'confirmation', 'loading', 'drag', 'error', 'success']);
    expect(motionIntentSpeeds.loading).toBe('slow');
  });

  it('builds a semantic transition without raw timing duplication', () => {
    expect(motionTransition('enter', ['opacity', 'transform']))
      .toBe('opacity var(--sx-motion-enter), transform var(--sx-motion-enter)');
    expect(() => motionTransition('focus', [])).toThrow(TypeError);
  });
});
