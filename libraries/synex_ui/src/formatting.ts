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

function assertFinite(value: NumericFormatValue): void {
  if (typeof value === "number" && !Number.isFinite(value)) {
    throw new TypeError("Synex UI formatting requires a finite numeric value.");
  }
}

function validDate(value: Date | number): Date {
  const date = value instanceof Date ? new Date(value.getTime()) : new Date(value);
  if (!Number.isFinite(date.getTime())) {
    throw new TypeError("Synex UI formatting requires a valid Date or epoch value.");
  }
  return date;
}

function hasDatePresentation(options: Intl.DateTimeFormatOptions): boolean {
  return options.dateStyle !== undefined
    || options.weekday !== undefined
    || options.era !== undefined
    || options.year !== undefined
    || options.month !== undefined
    || options.day !== undefined;
}

function hasTimePresentation(options: Intl.DateTimeFormatOptions): boolean {
  return options.timeStyle !== undefined
    || options.dayPeriod !== undefined
    || options.hour !== undefined
    || options.minute !== undefined
    || options.second !== undefined
    || options.fractionalSecondDigits !== undefined
    || options.timeZoneName !== undefined;
}

/** Formats a finite number using an explicitly selected locale. */
export function formatNumber(value: NumericFormatValue, config: NumberFormatConfig): string {
  assertFinite(value);
  const { locale, ...options } = config;
  return new Intl.NumberFormat(locale, options).format(value);
}

/** Formats a finite monetary value. Currency is always explicit and cannot be overridden by options. */
export function formatCurrency(value: NumericFormatValue, config: CurrencyFormatConfig): string {
  assertFinite(value);
  const { locale, currency, ...options } = config;
  return new Intl.NumberFormat(locale, { ...options, style: "currency", currency }).format(value);
}

/** Formats a fractional ratio as a percentage using an explicitly selected locale. */
export function formatPercent(value: NumericFormatValue, config: PercentFormatConfig): string {
  assertFinite(value);
  const { locale, ...options } = config;
  return new Intl.NumberFormat(locale, { ...options, style: "percent" }).format(value);
}

/** Formats a valid Date or epoch value with explicit locale and time zone. */
export function formatDate(value: Date | number, config: DateTimeFormatConfig): string {
  const { locale, timeZone, ...options } = config;
  const presentation: Intl.DateTimeFormatOptions = hasDatePresentation(options)
    ? options
    : { ...options, year: "numeric", month: "2-digit", day: "2-digit" };
  return new Intl.DateTimeFormat(locale, { ...presentation, timeZone }).format(validDate(value));
}

/** Formats a valid Date or epoch value as time with explicit locale and time zone. */
export function formatTime(value: Date | number, config: DateTimeFormatConfig): string {
  const { locale, timeZone, ...options } = config;
  const presentation: Intl.DateTimeFormatOptions = hasTimePresentation(options)
    ? options
    : { ...options, hour: "2-digit", minute: "2-digit", second: "2-digit" };
  return new Intl.DateTimeFormat(locale, { ...presentation, timeZone }).format(validDate(value));
}
