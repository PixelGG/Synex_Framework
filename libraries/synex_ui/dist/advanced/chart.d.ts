export declare const chartTokens: {
    readonly categorical: readonly ["var(--sx-chart-categorical-1)", "var(--sx-chart-categorical-2)", "var(--sx-chart-categorical-3)", "var(--sx-chart-categorical-4)", "var(--sx-chart-categorical-5)", "var(--sx-chart-categorical-6)"];
    readonly positive: "var(--sx-chart-positive)";
    readonly negative: "var(--sx-chart-negative)";
    readonly warning: "var(--sx-chart-warning)";
    readonly grid: "var(--sx-chart-grid)";
    readonly axis: "var(--sx-chart-axis)";
    readonly label: "var(--sx-chart-label)";
    readonly tooltipBackground: "var(--sx-chart-tooltip-bg)";
    readonly tooltipBorder: "var(--sx-chart-tooltip-border)";
};
export type ChartTokenName = keyof typeof chartTokens;
export interface ChartSeriesStyle {
    color: string;
    mutedColor: string;
    lineWidth: number;
    pointRadius: number;
}
export declare function chartSeriesStyle(index: number): ChartSeriesStyle;
