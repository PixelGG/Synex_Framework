import { type AriaAttributes, type FieldsetHTMLAttributes, type HTMLAttributes, type InputHTMLAttributes, type ReactNode, type TextareaHTMLAttributes } from "react";
import { type SynexSize } from "./internal.js";
export interface FieldProps extends HTMLAttributes<HTMLDivElement> {
    label: ReactNode;
    description?: ReactNode;
    validation?: ReactNode;
    invalid?: boolean;
    required?: boolean;
    disabled?: boolean;
    controlId?: string;
    optionalLabel?: string;
}
export declare const Field: import("react").ForwardRefExoticComponent<FieldProps & import("react").RefAttributes<HTMLDivElement>>;
export interface FieldGroupProps extends FieldsetHTMLAttributes<HTMLFieldSetElement> {
    legend: ReactNode;
    description?: ReactNode;
    orientation?: "horizontal" | "vertical";
}
export declare const FieldGroup: import("react").ForwardRefExoticComponent<FieldGroupProps & import("react").RefAttributes<HTMLFieldSetElement>>;
export declare const ValidationMessage: import("react").ForwardRefExoticComponent<HTMLAttributes<HTMLDivElement> & import("react").RefAttributes<HTMLDivElement>>;
export declare function useFieldControlProps<T extends {
    id?: string;
    disabled?: boolean;
    required?: boolean;
    "aria-invalid"?: AriaAttributes["aria-invalid"];
    "aria-describedby"?: string;
}>(props: T): T;
export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
    sizeVariant?: SynexSize;
    leading?: ReactNode;
    trailing?: ReactNode;
}
export declare const Input: import("react").ForwardRefExoticComponent<InputProps & import("react").RefAttributes<HTMLInputElement>>;
export type TextAreaProps = TextareaHTMLAttributes<HTMLTextAreaElement> & {
    resize?: "none" | "vertical" | "both";
};
export declare const TextArea: import("react").ForwardRefExoticComponent<TextareaHTMLAttributes<HTMLTextAreaElement> & {
    resize?: "none" | "vertical" | "both";
} & import("react").RefAttributes<HTMLTextAreaElement>>;
export interface NumberInputProps extends Omit<InputProps, "type" | "onChange" | "value" | "defaultValue"> {
    value?: number;
    defaultValue?: number;
    onValueChange?: (value: number) => void;
    minimum?: number;
    maximum?: number;
    step?: number;
}
export declare const NumberInput: import("react").ForwardRefExoticComponent<NumberInputProps & import("react").RefAttributes<HTMLInputElement>>;
export type SearchInputProps = Omit<InputProps, "type"> & {
    onClear?: () => void;
    clearLabel?: string;
};
export declare const SearchInput: import("react").ForwardRefExoticComponent<Omit<InputProps, "type"> & {
    onClear?: () => void;
    clearLabel?: string;
} & import("react").RefAttributes<HTMLInputElement>>;
export interface PasswordInputProps extends Omit<InputProps, "type"> {
    revealLabel?: string;
    concealLabel?: string;
}
export declare const PasswordInput: import("react").ForwardRefExoticComponent<PasswordInputProps & import("react").RefAttributes<HTMLInputElement>>;
export interface CheckboxProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "size"> {
    label?: ReactNode;
    description?: ReactNode;
    indeterminate?: boolean;
    size?: SynexSize;
}
export declare const Checkbox: import("react").ForwardRefExoticComponent<CheckboxProps & import("react").RefAttributes<HTMLInputElement>>;
export interface RadioProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "size"> {
    label?: ReactNode;
    description?: ReactNode;
    size?: SynexSize;
}
export declare const Radio: import("react").ForwardRefExoticComponent<RadioProps & import("react").RefAttributes<HTMLInputElement>>;
export interface SwitchProps extends Omit<HTMLAttributes<HTMLButtonElement>, "onChange"> {
    checked?: boolean;
    defaultChecked?: boolean;
    onCheckedChange?: (checked: boolean) => void;
    disabled?: boolean;
    required?: boolean;
    label: ReactNode;
    description?: ReactNode;
    name?: string;
    value?: string;
}
export declare const Switch: import("react").ForwardRefExoticComponent<SwitchProps & import("react").RefAttributes<HTMLButtonElement>>;
export interface SliderProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "value" | "defaultValue" | "onChange" | "size"> {
    value?: number;
    defaultValue?: number;
    onValueChange?: (value: number) => void;
    minimum?: number;
    maximum?: number;
    step?: number;
    showValue?: boolean;
    formatValue?: (value: number) => ReactNode;
}
export declare const Slider: import("react").ForwardRefExoticComponent<SliderProps & import("react").RefAttributes<HTMLInputElement>>;
