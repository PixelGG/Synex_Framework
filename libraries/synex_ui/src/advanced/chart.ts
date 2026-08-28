export const chartTokens = {
  categorical: [
    "var(--sx-chart-categorical-1)",
    "var(--sx-chart-categorical-2)",
    "var(--sx-chart-categorical-3)",
    "var(--sx-chart-categorical-4)",
    "var(--sx-chart-categorical-5)",
    "var(--sx-chart-categorical-6)",
  ],
  positive: "var(--sx-chart-positive)",
  negative: "var(--sx-chart-negative)",
  warning: "var(--sx-chart-warning)",
  grid: "var(--sx-chart-grid)",
  axis: "var(--sx-chart-axis)",
  label: "var(--sx-chart-label)",
  tooltipBackground: "var(--sx-chart-tooltip-bg)",
  tooltipBorder: "var(--sx-chart-tooltip-border)",
} as const;

export type ChartTokenName = keyof typeof chartTokens;

export interface ChartSeriesStyle {
  color: string;
  mutedColor: string;
  lineWidth: number;
  pointRadius: number;
}

export function chartSeriesStyle(index: number): ChartSeriesStyle {
  const palette = chartTokens.categorical;
  const normalized = ((index % palette.length) + palette.length) % palette.length;
  const color = palette[normalized] ?? palette[0];
  return { color, mutedColor: `var(--sx-chart-categorical-${normalized + 1}-muted)`, lineWidth: 2, pointRadius: 3 };
}
