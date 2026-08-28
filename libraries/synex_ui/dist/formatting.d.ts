export type FormatLocale = string | readonly string[];
export type NumericFormatValue = number | bigint;
export interface NumberFormatConfig extends Intl.NumberFormatOptions {
    locale: FormatLocale;
}
export interface CurrencyFormatConfig extends Omit<Intl.NumberFormatOptions, "currency" | "style"> {
    locale: FormatLocale;
    currency: string;
}
export interface PercentFormatConfig extends Omit<Intl.NumberFormatOptions, "style"> {
    locale: FormatLocale;
}
export interface DateTimeFormatConfig extends Intl.DateTimeFormatOptions {
    locale: FormatLocale;
    timeZone: string;
}
/** Formats a finite number using an explicitly selected locale. */
export declare function formatNumber(value: NumericFormatValue, config: NumberFormatConfig): string;
/** Formats a finite monetary value. Currency is always explicit and cannot be overridden by options. */
export declare function formatCurrency(value: NumericFormatValue, config: CurrencyFormatConfig): string;
/** Formats a fractional ratio as a percentage using an explicitly selected locale. */
export declare function formatPercent(value: NumericFormatValue, config: PercentFormatConfig): string;
/** Formats a valid Date or epoch value with explicit locale and time zone. */
export declare function formatDate(value: Date | number, config: DateTimeFormatConfig): string;
/** Formats a valid Date or epoch value as time with explicit locale and time zone. */
export declare function formatTime(value: Date | number, config: DateTimeFormatConfig): string;
