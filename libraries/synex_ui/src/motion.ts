export type MotionSpeed = "instant" | "fast" | "normal" | "slow";

export type MotionIntent =
  | "enter"
  | "exit"
  | "focus"
  | "selection"
  | "confirmation"
  | "loading"
  | "drag"
  | "error"
  | "success";

export type MotionProperty =
  | "opacity"
  | "transform"
  | "color"
  | "background-color"
  | "border-color"
  | "box-shadow"
  | "filter"
  | "stroke"
  | "stroke-dashoffset";

export const motionDurationMilliseconds: Readonly<Record<MotionSpeed, number>> = Object.freeze({
  instant: 0,
  fast: 110,
  normal: 180,
  slow: 280,
});

export const motionDurations: Readonly<Record<MotionSpeed, string>> = Object.freeze({
  instant: "var(--sx-motion-duration-instant)",
  fast: "var(--sx-motion-duration-fast)",
  normal: "var(--sx-motion-duration-normal)",
  slow: "var(--sx-motion-duration-slow)",
});

export const motionTokens: Readonly<Record<MotionIntent, string>> = Object.freeze({
  enter: "var(--sx-motion-enter)",
  exit: "var(--sx-motion-exit)",
  focus: "var(--sx-motion-focus)",
  selection: "var(--sx-motion-selection)",
  confirmation: "var(--sx-motion-confirmation)",
  loading: "var(--sx-motion-loading)",
  drag: "var(--sx-motion-drag)",
  error: "var(--sx-motion-error)",
  success: "var(--sx-motion-success)",
});

export const motionIntentSpeeds: Readonly<Record<MotionIntent, MotionSpeed>> = Object.freeze({
  enter: "normal",
  exit: "fast",
  focus: "fast",
  selection: "fast",
  confirmation: "normal",
  loading: "slow",
  drag: "fast",
  error: "normal",
  success: "normal",
});

/** Builds a transition list from a semantic intent without exposing raw timing values. */
export function motionTransition(
  intent: MotionIntent,
  properties: MotionProperty | readonly MotionProperty[],
): string {
  const list = typeof properties === "string" ? [properties] : properties;
  if (list.length === 0) throw new TypeError("Synex UI motion requires at least one transition property.");
  return list.map((property) => `${property} ${motionTokens[intent]}`).join(", ");
}
