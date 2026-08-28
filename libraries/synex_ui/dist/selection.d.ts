import { type HTMLAttributes, type ReactNode, type SelectHTMLAttributes } from "react";
export interface SelectOption<Value extends string = string> {
    value: Value;
    label: ReactNode;
    disabled?: boolean;
    description?: ReactNode;
    keywords?: readonly string[];
    textValue?: string;
}
export interface SelectProps<Value extends string = string> extends Omit<SelectHTMLAttributes<HTMLSelectElement>, "value" | "defaultValue" | "onChange" | "size"> {
    options: readonly SelectOption<Value>[];
    value?: Value;
    defaultValue?: Value;
    onValueChange?: (value: Value) => void;
    placeholder?: string;
}
export declare function Select<Value extends string = string>({ options, value, defaultValue, onValueChange, placeholder, className, ...props }: SelectProps<Value>): import("react").JSX.Element;
export interface ComboboxProps<Value extends string = string> extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
    options: readonly SelectOption<Value>[];
    value?: Value;
    defaultValue?: Value;
    onValueChange?: (value: Value) => void;
    query?: string;
    defaultQuery?: string;
    onQueryChange?: (query: string) => void;
    placeholder?: string;
    noResults?: ReactNode;
    filter?: (option: SelectOption<Value>, query: string) => boolean;
    disabled?: boolean;
    required?: boolean;
}
export declare function Combobox<Value extends string = string>({ options, value, defaultValue, onValueChange, query, defaultQuery, onQueryChange, placeholder, noResults, filter, disabled, required, className, id: explicitId, "aria-label": ariaLabel, "aria-labelledby": ariaLabelledBy, "aria-invalid": ariaInvalid, "aria-describedby": ariaDescribedBy, ...props }: ComboboxProps<Value>): import("react").JSX.Element;
export type SearchSelectProps<Value extends string = string> = ComboboxProps<Value> & {
    minimumQueryLength?: number;
};
export declare function SearchSelect<Value extends string = string>({ minimumQueryLength, filter, ...props }: SearchSelectProps<Value>): import("react").JSX.Element;
export interface MultiSelectProps<Value extends string = string> extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
    options: readonly SelectOption<Value>[];
    value?: readonly Value[];
    defaultValue?: readonly Value[];
    onValueChange?: (values: readonly Value[]) => void;
    placeholder?: string;
    searchPlaceholder?: string;
    disabled?: boolean;
    required?: boolean;
}
export declare function MultiSelect<Value extends string = string>({ options, value, defaultValue, onValueChange, placeholder, searchPlaceholder, disabled, required, className, id: explicitId, "aria-label": ariaLabel, "aria-labelledby": ariaLabelledBy, "aria-invalid": ariaInvalid, "aria-describedby": ariaDescribedBy, onKeyDown: onRootKeyDown, ...props }: MultiSelectProps<Value>): import("react").JSX.Element;
export interface SegmentOption<Value extends string = string> {
    value: Value;
    label: ReactNode;
    disabled?: boolean;
    icon?: ReactNode;
}
export interface SegmentedControlProps<Value extends string = string> extends Omit<HTMLAttributes<HTMLDivElement>, "onChange"> {
    options: readonly SegmentOption<Value>[];
    value?: Value;
    defaultValue?: Value;
    onValueChange?: (value: Value) => void;
    label: string;
}
export declare function SegmentedControl<Value extends string = string>({ options, value, defaultValue, onValueChange, label, className, ...props }: SegmentedControlProps<Value>): import("react").JSX.Element;
