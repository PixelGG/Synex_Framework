export type MotionSpeed = "instant" | "fast" | "normal" | "slow";
export type MotionIntent = "enter" | "exit" | "focus" | "selection" | "confirmation" | "loading" | "drag" | "error" | "success";
export type MotionProperty = "opacity" | "transform" | "color" | "background-color" | "border-color" | "box-shadow" | "filter" | "stroke" | "stroke-dashoffset";
export declare const motionDurationMilliseconds: Readonly<Record<MotionSpeed, number>>;
export declare const motionDurations: Readonly<Record<MotionSpeed, string>>;
export declare const motionTokens: Readonly<Record<MotionIntent, string>>;
export declare const motionIntentSpeeds: Readonly<Record<MotionIntent, MotionSpeed>>;
/** Builds a transition list from a semantic intent without exposing raw timing values. */
export declare function motionTransition(intent: MotionIntent, properties: MotionProperty | readonly MotionProperty[]): string;
