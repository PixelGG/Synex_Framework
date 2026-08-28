import { cloneElement as e, createContext as t, createElement as n, forwardRef as r, isValidElement as i, useCallback as a, useContext as o, useEffect as s, useId as c, useLayoutEffect as l, useMemo as u, useRef as d, useState as f } from "react";
import { Fragment as p, jsx as m, jsxs as h } from "react/jsx-runtime";
//#region src/formatting.ts
function g(e) {
	if (typeof e == "number" && !Number.isFinite(e)) throw TypeError("Synex UI formatting requires a finite numeric value.");
}
function _(e) {
	let t = e instanceof Date ? new Date(e.getTime()) : new Date(e);
	if (!Number.isFinite(t.getTime())) throw TypeError("Synex UI formatting requires a valid Date or epoch value.");
	return t;
}
function v(e) {
	return e.dateStyle !== void 0 || e.weekday !== void 0 || e.era !== void 0 || e.year !== void 0 || e.month !== void 0 || e.day !== void 0;
}
function y(e) {
	return e.timeStyle !== void 0 || e.dayPeriod !== void 0 || e.hour !== void 0 || e.minute !== void 0 || e.second !== void 0 || e.fractionalSecondDigits !== void 0 || e.timeZoneName !== void 0;
}
function b(e, t) {
	g(e);
	let { locale: n, ...r } = t;
	return new Intl.NumberFormat(n, r).format(e);
}
function x(e, t) {
	g(e);
	let { locale: n, currency: r, ...i } = t;
	return new Intl.NumberFormat(n, {
		...i,
		style: "currency",
		currency: r
	}).format(e);
}
function S(e, t) {
	g(e);
	let { locale: n, ...r } = t;
	return new Intl.NumberFormat(n, {
		...r,
		style: "percent"
	}).format(e);
}
function C(e, t) {
	let { locale: n, timeZone: r, ...i } = t, a = v(i) ? i : {
		...i,
		year: "numeric",
		month: "2-digit",
		day: "2-digit"
	};
	return new Intl.DateTimeFormat(n, {
		...a,
		timeZone: r
	}).format(_(e));
}
function w(e, t) {
	let { locale: n, timeZone: r, ...i } = t, a = y(i) ? i : {
		...i,
		hour: "2-digit",
		minute: "2-digit",
		second: "2-digit"
	};
	return new Intl.DateTimeFormat(n, {
		...a,
		timeZone: r
	}).format(_(e));
}
//#endregion
//#region src/internal.tsx
var T = {
	"2xs": "var(--sx-space-1)",
	xs: "var(--sx-space-2)",
	sm: "var(--sx-space-3)",
	md: "var(--sx-space-4)",
	lg: "var(--sx-space-6)",
	xl: "var(--sx-space-8)"
};
function E(e) {
	if (typeof e == "number") return `${e}px`;
	if (e !== void 0) return T[e] ?? e;
}
function D(...e) {
	return e.filter(Boolean).join(" ");
}
function O(...e) {
	let t = e.filter(Boolean).join(" ");
	return t.length > 0 ? t : void 0;
}
function k(e, t) {
	let n = c();
	return e ?? `${t}-${n.replaceAll(":", "")}`;
}
function A(e) {
	let { value: t, defaultValue: n, onChange: r } = e, [i, o] = f(n), s = t !== void 0, c = s ? t : i;
	return [c, a((e) => {
		let t = typeof e == "function" ? e(c) : e;
		s || o(t), Object.is(t, c) || r?.(t);
	}, [
		s,
		c,
		r
	])];
}
function j(e) {
	let t = d(e);
	return l(() => {
		t.current = e;
	}, [e]), t;
}
function M(e, t, n = !0) {
	let r = j(t), i = j(e);
	s(() => {
		if (!n) return;
		let e = (e) => {
			let t = e.target;
			t instanceof Node && (i.current.some((e) => e.current?.contains(t)) || r.current(e));
		};
		return document.addEventListener("pointerdown", e, !0), () => document.removeEventListener("pointerdown", e, !0);
	}, [
		n,
		r,
		i
	]);
}
var N = [
	"a[href]",
	"button:not([disabled])",
	"input:not([disabled]):not([type='hidden'])",
	"select:not([disabled])",
	"textarea:not([disabled])",
	"[tabindex]:not([tabindex='-1'])"
].join(",");
function P(e) {
	return Array.from(e.querySelectorAll(N)).filter((e) => !e.hidden && e.getAttribute("aria-hidden") !== "true");
}
function F(e, t, n = {}) {
	let r = n.initialFocusRef, i = n.restore ?? !0;
	s(() => {
		if (!t) return;
		let n = document.activeElement instanceof HTMLElement ? document.activeElement : null, a = e.current;
		if (!a) return;
		let o = r?.current ?? P(a)[0] ?? a;
		queueMicrotask(() => o.focus({ preventScroll: !0 }));
		let s = (e) => {
			if (e.key !== "Tab") return;
			let t = P(a);
			if (t.length === 0) {
				e.preventDefault(), a.focus();
				return;
			}
			let n = t[0], r = t.at(-1);
			e.shiftKey && document.activeElement === n ? (e.preventDefault(), r?.focus()) : !e.shiftKey && document.activeElement === r && (e.preventDefault(), n?.focus());
		};
		return a.addEventListener("keydown", s), () => {
			a.removeEventListener("keydown", s), i && n?.isConnected && n.focus({ preventScroll: !0 });
		};
	}, [
		t,
		e,
		r,
		i
	]);
}
function I(e, t, n, r, i = !0) {
	if (n === 0) return -1;
	let a = e;
	for (let o = 0; o < n; o += 1) {
		if (a += t, i) a = (a + n) % n;
		else if (a < 0 || a >= n) return e;
		if (!r(a)) return a;
	}
	return e;
}
function L(e, t) {
	let { current: n, length: r, orientation: i = "horizontal", isDisabled: a = () => !1, loop: o = !0 } = t, s = i === "horizontal" ? ["ArrowLeft"] : ["ArrowUp"], c = i === "horizontal" ? ["ArrowRight"] : ["ArrowDown"];
	if (s.includes(e.key)) return e.preventDefault(), I(n, -1, r, a, o);
	if (c.includes(e.key)) return e.preventDefault(), I(n, 1, r, a, o);
	if (e.key === "Home") {
		e.preventDefault();
		for (let e = 0; e < r; e += 1) if (!a(e)) return e;
	}
	if (e.key === "End") {
		e.preventDefault();
		for (let e = r - 1; e >= 0; --e) if (!a(e)) return e;
	}
	return null;
}
function R(e) {
	let t = {};
	for (let [n, r] of Object.entries(e)) r !== void 0 && (t[n] = r);
	return t;
}
function z(...e) {
	return (t) => {
		for (let n of e) typeof n == "function" ? n(t) : n && (n.current = t);
	};
}
function B({ children: t, popup: n, expanded: r, controls: a, onActivate: o, className: s }) {
	if (i(t)) {
		let i = t.props.onClick;
		return e(t, {
			"aria-haspopup": n,
			"aria-expanded": r,
			"aria-controls": a,
			className: D(s, t.props.className),
			onClick: (e) => {
				i?.(e), e.defaultPrevented || o();
			}
		});
	}
	return /* @__PURE__ */ m("button", {
		type: "button",
		className: s,
		"aria-haspopup": n,
		"aria-expanded": r,
		"aria-controls": a,
		onClick: o,
		children: t
	});
}
function V(e, t, n) {
	return Math.min(n, Math.max(t, e));
}
function H(e) {
	return typeof e == "string" || typeof e == "number" ? String(e).toLocaleLowerCase() : "";
}
function U() {
	let e = d(null), [t, n] = f({
		width: 0,
		height: 0
	});
	return s(() => {
		let t = e.current;
		if (!t) return;
		let r = () => n({
			width: t.clientWidth,
			height: t.clientHeight
		});
		if (r(), typeof ResizeObserver > "u") return window.addEventListener("resize", r), () => window.removeEventListener("resize", r);
		let i = new ResizeObserver(r);
		return i.observe(t), () => i.disconnect();
	}, []), u(() => ({
		ref: e,
		...t
	}), [t]);
}
//#endregion
//#region src/typography.tsx
var ee = {
	display: "h1",
	"heading-1": "h1",
	"heading-2": "h2",
	"heading-3": "h3",
	body: "p",
	"body-small": "p",
	caption: "span",
	label: "span",
	numeric: "span",
	code: "code",
	monospace: "span"
}, te = r(function({ as: e, variant: t = "body", truncate: r = !1, className: i, ...a }, o) {
	return n(e ?? ee[t], {
		...a,
		ref: o,
		className: D("sx-typography", `sx-type-${t}`, i),
		"data-sx-typography": t,
		"data-sx-truncate": r || void 0
	});
}), ne = Object.freeze({
	instant: 0,
	fast: 110,
	normal: 180,
	slow: 280
}), re = Object.freeze({
	instant: "var(--sx-motion-duration-instant)",
	fast: "var(--sx-motion-duration-fast)",
	normal: "var(--sx-motion-duration-normal)",
	slow: "var(--sx-motion-duration-slow)"
}), ie = Object.freeze({
	enter: "var(--sx-motion-enter)",
	exit: "var(--sx-motion-exit)",
	focus: "var(--sx-motion-focus)",
	selection: "var(--sx-motion-selection)",
	confirmation: "var(--sx-motion-confirmation)",
	loading: "var(--sx-motion-loading)",
	drag: "var(--sx-motion-drag)",
	error: "var(--sx-motion-error)",
	success: "var(--sx-motion-success)"
}), ae = Object.freeze({
	enter: "normal",
	exit: "fast",
	focus: "fast",
	selection: "fast",
	confirmation: "normal",
	loading: "slow",
	drag: "fast",
	error: "normal",
	success: "normal"
});
function oe(e, t) {
	let n = typeof t == "string" ? [t] : t;
	if (n.length === 0) throw TypeError("Synex UI motion requires at least one transition property.");
	return n.map((t) => `${t} ${ie[e]}`).join(", ");
}
//#endregion
//#region src/foundation.tsx
var se = r(function({ material: e = "solid", variant: t, intensity: n = "soft", elevation: r = 0, tone: i = "neutral", inset: a = !1, interactive: o = !1, className: s, ...c }, l) {
	return /* @__PURE__ */ m("div", {
		ref: l,
		className: D("sx-surface", s),
		"data-sx-material": t ?? e,
		"data-sx-intensity": n,
		"data-sx-elevation": r,
		"data-sx-tone": i,
		"data-sx-inset": a || void 0,
		"data-sx-interactive": o || void 0,
		...c
	});
}), ce = r(function({ gap: e, align: t, justify: n, density: r, className: i, style: a, ...o }, s) {
	return /* @__PURE__ */ m("div", {
		ref: s,
		className: D("sx-stack", i),
		"data-sx-density": r,
		style: {
			...R({ "--sx-stack-gap": E(e) }),
			alignItems: t,
			justifyContent: n,
			...a
		},
		...o
	});
}), le = r(function({ wrap: e = !1, className: t, style: n, ...r }, i) {
	return /* @__PURE__ */ m(ce, {
		ref: i,
		className: D("sx-inline", t),
		style: {
			flexWrap: e ? "wrap" : "nowrap",
			...n
		},
		...r
	});
}), ue = r(function({ columns: e, minColumnWidth: t, gap: n, className: r, style: i, ...a }, o) {
	let s = typeof e == "number" ? `repeat(${e}, minmax(0, 1fr))` : e ?? (t === void 0 ? void 0 : `repeat(auto-fit, minmax(${typeof t == "number" ? `${t}px` : t}, 1fr))`);
	return /* @__PURE__ */ m("div", {
		ref: o,
		className: D("sx-grid", r),
		style: {
			...R({ "--sx-grid-gap": E(n) }),
			gridTemplateColumns: s,
			...i
		},
		...a
	});
}), de = r(function({ size: e = "lg", centered: t = !0, className: n, ...r }, i) {
	return /* @__PURE__ */ m("div", {
		ref: i,
		className: D("sx-container", n),
		"data-sx-size": e,
		"data-sx-centered": t || void 0,
		...r
	});
}), fe = r(function({ orientation: e = "horizontal", decorative: t = !0, className: n, ...r }, i) {
	return /* @__PURE__ */ m("hr", {
		ref: i,
		className: D("sx-divider", n),
		"data-sx-orientation": e,
		"aria-orientation": e,
		"aria-hidden": t || void 0,
		...r
	});
}), pe = r(function({ orientation: e = "vertical", viewportClassName: t, viewportProps: n, children: r, className: i, ...a }, o) {
	return /* @__PURE__ */ m("div", {
		ref: o,
		className: D("sx-scroll-area", i),
		"data-sx-orientation": e,
		...a,
		children: /* @__PURE__ */ m("div", {
			...n,
			className: D("sx-scroll-area__viewport", t, n?.className),
			children: r
		})
	});
}), me = r(function({ size: e = "var(--sx-space-4)", axis: t = "vertical", style: n, className: r, ...i }, a) {
	let o = typeof e == "number" ? `${e}px` : e;
	return /* @__PURE__ */ m("div", {
		ref: a,
		"aria-hidden": "true",
		className: D("sx-spacer", r),
		"data-sx-axis": t,
		style: {
			width: t === "vertical" ? void 0 : o,
			height: t === "horizontal" ? void 0 : o,
			...n
		},
		...i
	});
}), he = r(function({ ratio: e = 16 / 9, className: t, style: n, ...r }, i) {
	return /* @__PURE__ */ m("div", {
		ref: i,
		className: D("sx-aspect-box", t),
		style: {
			aspectRatio: e,
			...n
		},
		...r
	});
}), W = r(function({ variant: e = "primary", size: t = "md", tone: n, loading: r = !1, leading: i, trailing: a, fullWidth: o = !1, disabled: s, type: c = "button", className: l, children: u, ...d }, f) {
	return /* @__PURE__ */ h("button", {
		ref: f,
		type: c,
		className: D("sx-button", l),
		"data-sx-variant": e,
		"data-sx-size": t,
		"data-sx-tone": n,
		"data-sx-loading": r || void 0,
		"data-sx-full-width": o || void 0,
		disabled: s || r,
		"aria-busy": r || void 0,
		...d,
		children: [
			r ? /* @__PURE__ */ m("span", {
				className: "sx-button__spinner",
				"aria-hidden": "true"
			}) : i ? /* @__PURE__ */ m("span", {
				className: "sx-button__leading",
				"aria-hidden": "true",
				children: i
			}) : null,
			/* @__PURE__ */ m("span", {
				className: "sx-button__label",
				children: u
			}),
			a ? /* @__PURE__ */ m("span", {
				className: "sx-button__trailing",
				"aria-hidden": "true",
				children: a
			}) : null
		]
	});
}), G = r(function({ label: e, icon: t, className: n, ...r }, i) {
	return /* @__PURE__ */ m(W, {
		ref: i,
		className: D("sx-icon-button", n),
		"aria-label": e,
		title: e,
		...r,
		children: /* @__PURE__ */ m("span", {
			"aria-hidden": "true",
			className: "sx-icon-button__icon",
			children: t
		})
	});
}), ge = r(function({ menu: e, menuLabel: t = "More actions", open: n, defaultOpen: r = !1, onOpenChange: i, className: a, children: o, ...s }, l) {
	let u = `sx-split-menu-${c().replaceAll(":", "")}`, p = d(null), g = d(null), [_, v] = f(r), y = n ?? _, b = (e) => {
		n === void 0 && v(e), i?.(e);
	}, x = () => {
		b(!1), queueMicrotask(() => g.current?.focus());
	};
	return M([p], () => b(!1), y), /* @__PURE__ */ h("div", {
		ref: z(p, l),
		className: D("sx-split-button", a),
		"data-sx-open": y || void 0,
		children: [
			/* @__PURE__ */ m(W, {
				...s,
				children: o
			}),
			/* @__PURE__ */ m(G, {
				ref: g,
				variant: s.variant,
				size: s.size,
				tone: s.tone,
				disabled: s.disabled,
				label: t,
				icon: /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--chevron" }),
				"aria-haspopup": "menu",
				"aria-expanded": y,
				"aria-controls": u,
				onClick: () => b(!y),
				onKeyDown: (e) => {
					e.key === "ArrowDown" && (e.preventDefault(), b(!0));
				}
			}),
			y ? /* @__PURE__ */ m("div", {
				id: u,
				className: "sx-split-button__menu",
				onKeyDownCapture: (e) => {
					e.key === "Escape" && (e.preventDefault(), e.stopPropagation(), x());
				},
				children: e
			}) : null
		]
	});
}), _e = r(function({ align: e = "end", reverseOnNarrow: t = !1, className: n, ...r }, i) {
	return /* @__PURE__ */ m("div", {
		ref: i,
		className: D("sx-action-row", n),
		"data-sx-align": e,
		"data-sx-reverse-narrow": t || void 0,
		...r
	});
}), ve = t(null), ye = r(function({ label: e, description: t, validation: n, invalid: r = n !== void 0, required: i = !1, disabled: a = !1, controlId: o, optionalLabel: s = "Optional", className: c, children: l, ...d }, f) {
	let p = k(o, "sx-field"), g = t === void 0 ? void 0 : `${p}-description`, _ = n === void 0 ? void 0 : `${p}-validation`, v = u(() => ({
		controlId: p,
		...g ? { descriptionId: g } : {},
		..._ ? { validationId: _ } : {},
		invalid: r,
		required: i,
		disabled: a
	}), [
		p,
		g,
		a,
		r,
		i,
		_
	]);
	return /* @__PURE__ */ m(ve.Provider, {
		value: v,
		children: /* @__PURE__ */ h("div", {
			ref: f,
			className: D("sx-field", c),
			"data-sx-invalid": r || void 0,
			"data-sx-disabled": a || void 0,
			...d,
			children: [
				/* @__PURE__ */ h("div", {
					className: "sx-field__heading",
					children: [/* @__PURE__ */ m("label", {
						className: "sx-field__label",
						htmlFor: p,
						children: e
					}), i ? null : /* @__PURE__ */ m("span", {
						className: "sx-field__optional",
						children: s
					})]
				}),
				t === void 0 ? null : /* @__PURE__ */ m("div", {
					id: g,
					className: "sx-field__description",
					children: t
				}),
				/* @__PURE__ */ m("div", {
					className: "sx-field__control",
					children: l
				}),
				n === void 0 ? null : /* @__PURE__ */ m(xe, {
					id: _,
					children: n
				})
			]
		})
	});
}), be = r(function({ legend: e, description: t, orientation: n = "vertical", className: r, children: i, ...a }, o) {
	return /* @__PURE__ */ h("fieldset", {
		ref: o,
		className: D("sx-field-group", r),
		"data-sx-orientation": n,
		...a,
		children: [
			/* @__PURE__ */ m("legend", {
				className: "sx-field-group__legend",
				children: e
			}),
			t ? /* @__PURE__ */ m("p", {
				className: "sx-field-group__description",
				children: t
			}) : null,
			/* @__PURE__ */ m("div", {
				className: "sx-field-group__content",
				children: i
			})
		]
	});
}), xe = r(function({ className: e, ...t }, n) {
	return /* @__PURE__ */ m("div", {
		ref: n,
		className: D("sx-validation-message", e),
		role: "alert",
		"aria-live": "polite",
		...t
	});
});
function K(e) {
	let t = o(ve);
	return t ? {
		...e,
		id: e.id ?? t.controlId,
		disabled: e.disabled ?? t.disabled,
		required: e.required ?? t.required,
		"aria-invalid": e["aria-invalid"] ?? (t.invalid || void 0),
		"aria-describedby": O(e["aria-describedby"], t.descriptionId, t.validationId)
	} : e;
}
var q = r(function({ sizeVariant: e = "md", leading: t, trailing: n, className: r, ...i }, a) {
	let o = K(i);
	return /* @__PURE__ */ h("div", {
		className: D("sx-input-frame", r),
		"data-sx-size": e,
		"data-sx-disabled": o.disabled || void 0,
		"data-sx-invalid": o["aria-invalid"] === !0 || o["aria-invalid"] === "true" || void 0,
		children: [
			t ? /* @__PURE__ */ m("span", {
				className: "sx-input-frame__leading",
				"aria-hidden": "true",
				children: t
			}) : null,
			/* @__PURE__ */ m("input", {
				ref: a,
				className: "sx-input",
				...o
			}),
			n ? /* @__PURE__ */ m("span", {
				className: "sx-input-frame__trailing",
				children: n
			}) : null
		]
	});
}), Se = r(function({ resize: e = "vertical", className: t, ...n }, r) {
	let i = K(n);
	return /* @__PURE__ */ m("textarea", {
		ref: r,
		className: D("sx-textarea", t),
		"data-sx-resize": e,
		...i
	});
}), Ce = r(function({ value: e, defaultValue: t = 0, onValueChange: n, minimum: r = -Infinity, maximum: i = Infinity, step: a = 1, className: o, disabled: s, ...c }, l) {
	let [u, d] = A({
		value: e,
		defaultValue: t,
		onChange: n
	}), f = (e) => d(V(e, r, i));
	return /* @__PURE__ */ h("div", {
		className: D("sx-number-input", o),
		children: [/* @__PURE__ */ m(q, {
			...c,
			ref: l,
			type: "number",
			value: u,
			min: Number.isFinite(r) ? r : void 0,
			max: Number.isFinite(i) ? i : void 0,
			step: a,
			disabled: s,
			"aria-valuenow": u,
			onChange: (e) => {
				let t = e.currentTarget.valueAsNumber;
				Number.isNaN(t) || f(t);
			}
		}), /* @__PURE__ */ h("div", {
			className: "sx-number-input__steppers",
			children: [/* @__PURE__ */ m(G, {
				label: "Increase value",
				size: "sm",
				variant: "quiet",
				icon: /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--plus" }),
				disabled: s || u >= i,
				onClick: () => f(u + a)
			}), /* @__PURE__ */ m(G, {
				label: "Decrease value",
				size: "sm",
				variant: "quiet",
				icon: /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--minus" }),
				disabled: s || u <= r,
				onClick: () => f(u - a)
			})]
		})]
	});
}), J = r(function({ onClear: e, clearLabel: t = "Clear search", value: n, defaultValue: r, onChange: i, ...a }, o) {
	let [s, c] = f(String(r ?? "")), l = n === void 0 ? s : String(n);
	return /* @__PURE__ */ m(q, {
		ref: o,
		type: "search",
		leading: /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--search" }),
		value: l,
		onChange: (e) => {
			n === void 0 && c(e.currentTarget.value), i?.(e);
		},
		trailing: e && l.length > 0 ? /* @__PURE__ */ m(G, {
			label: t,
			variant: "quiet",
			size: "sm",
			icon: /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--close" }),
			onClick: () => {
				n === void 0 && c(""), e();
			}
		}) : void 0,
		...a
	});
}), we = r(function({ revealLabel: e = "Show password", concealLabel: t = "Hide password", ...n }, r) {
	let [i, a] = A({ defaultValue: !1 });
	return /* @__PURE__ */ m(q, {
		ref: r,
		type: i ? "text" : "password",
		trailing: /* @__PURE__ */ m(G, {
			label: i ? t : e,
			variant: "quiet",
			size: "sm",
			icon: /* @__PURE__ */ m("span", { className: D("sx-icon", i ? "sx-icon--eye-off" : "sx-icon--eye") }),
			onClick: () => a(!i)
		}),
		...n
	});
}), Te = r(function({ label: e, description: t, indeterminate: n = !1, size: r = "md", className: i, ...a }, o) {
	let s = K(a);
	return /* @__PURE__ */ h("label", {
		className: D("sx-checkbox", i),
		"data-sx-size": r,
		"data-sx-indeterminate": n || void 0,
		children: [
			/* @__PURE__ */ m("input", {
				ref: z(o, (e) => {
					e && (e.indeterminate = n);
				}),
				type: "checkbox",
				className: "sx-checkbox__input",
				"aria-checked": n ? "mixed" : void 0,
				...s
			}),
			/* @__PURE__ */ m("span", {
				className: "sx-checkbox__control",
				"aria-hidden": "true"
			}),
			e || t ? /* @__PURE__ */ h("span", {
				className: "sx-checkbox__copy",
				children: [/* @__PURE__ */ m("span", {
					className: "sx-checkbox__label",
					children: e
				}), t ? /* @__PURE__ */ m("span", {
					className: "sx-checkbox__description",
					children: t
				}) : null]
			}) : null
		]
	});
}), Ee = r(function({ label: e, description: t, size: n = "md", className: r, ...i }, a) {
	let o = K(i);
	return /* @__PURE__ */ h("label", {
		className: D("sx-radio", r),
		"data-sx-size": n,
		children: [
			/* @__PURE__ */ m("input", {
				ref: a,
				type: "radio",
				className: "sx-radio__input",
				...o
			}),
			/* @__PURE__ */ m("span", {
				className: "sx-radio__control",
				"aria-hidden": "true"
			}),
			e || t ? /* @__PURE__ */ h("span", {
				className: "sx-radio__copy",
				children: [/* @__PURE__ */ m("span", {
					className: "sx-radio__label",
					children: e
				}), t ? /* @__PURE__ */ m("span", {
					className: "sx-radio__description",
					children: t
				}) : null]
			}) : null
		]
	});
}), De = r(function({ checked: e, defaultChecked: t = !1, onCheckedChange: n, disabled: r = !1, required: i = !1, label: a, description: o, name: s, value: c = "on", className: l, onClick: u, ...d }, f) {
	let [p, g] = A({
		value: e,
		defaultValue: t,
		onChange: n
	}), _ = k(void 0, "sx-switch-label"), v = `${_}-description`;
	return /* @__PURE__ */ h("div", {
		className: D("sx-switch-row", l),
		"data-sx-disabled": r || void 0,
		children: [
			/* @__PURE__ */ h("span", {
				className: "sx-switch-row__copy",
				children: [/* @__PURE__ */ m("span", {
					id: _,
					className: "sx-switch-row__label",
					children: a
				}), o ? /* @__PURE__ */ m("span", {
					id: v,
					className: "sx-switch-row__description",
					children: o
				}) : null]
			}),
			/* @__PURE__ */ m("button", {
				...d,
				ref: f,
				type: "button",
				role: "switch",
				className: "sx-switch",
				"aria-checked": p,
				"aria-labelledby": d["aria-labelledby"] ?? (d["aria-label"] ? void 0 : _),
				"aria-describedby": O(d["aria-describedby"], o ? v : void 0),
				"aria-required": i || void 0,
				disabled: r,
				onClick: (e) => {
					u?.(e), e.defaultPrevented || g(!p);
				},
				children: /* @__PURE__ */ m("span", {
					className: "sx-switch__thumb",
					"aria-hidden": "true"
				})
			}),
			s ? /* @__PURE__ */ m("input", {
				type: "hidden",
				name: s,
				value: c,
				disabled: !p
			}) : null
		]
	});
}), Oe = r(function({ value: e, defaultValue: t = 0, onValueChange: n, minimum: r = 0, maximum: i = 100, step: a = 1, showValue: o = !1, formatValue: s = String, className: c, ...l }, u) {
	let [d, f] = A({
		value: e,
		defaultValue: V(t, r, i),
		onChange: n
	}), p = i === r ? 0 : (d - r) / (i - r) * 100, g = K(l);
	return /* @__PURE__ */ h("div", {
		className: D("sx-slider", c),
		style: { "--sx-slider-value": `${p}%` },
		children: [/* @__PURE__ */ m("input", {
			ref: u,
			type: "range",
			className: "sx-slider__input",
			min: r,
			max: i,
			step: a,
			value: d,
			onChange: (e) => f(e.currentTarget.valueAsNumber),
			...g
		}), o ? /* @__PURE__ */ m("output", {
			className: "sx-slider__value",
			children: s(d)
		}) : null]
	});
});
//#endregion
//#region src/selection.tsx
function ke(e) {
	return e.textValue ? e.textValue : typeof e.label == "string" || typeof e.label == "number" ? String(e.label) : e.value;
}
function Ae({ options: e, value: t, defaultValue: n, onValueChange: r, placeholder: i, className: a, ...o }) {
	let s = K(o);
	return /* @__PURE__ */ h("div", {
		className: D("sx-select", a),
		"data-sx-invalid": s["aria-invalid"] === !0 || s["aria-invalid"] === "true" || void 0,
		children: [/* @__PURE__ */ h("select", {
			className: "sx-select__control",
			value: t,
			defaultValue: n,
			onChange: (e) => r?.(e.currentTarget.value),
			...s,
			children: [i ? /* @__PURE__ */ m("option", {
				value: "",
				disabled: !0,
				children: i
			}) : null, e.map((e) => /* @__PURE__ */ m("option", {
				value: e.value,
				disabled: e.disabled,
				children: ke(e)
			}, e.value))]
		}), /* @__PURE__ */ m("span", {
			className: "sx-select__indicator sx-icon sx-icon--chevron",
			"aria-hidden": "true"
		})]
	});
}
function je({ options: e, value: t, defaultValue: n, onValueChange: r, query: i, defaultQuery: a = "", onQueryChange: o, placeholder: s = "Search", noResults: c = "No matching options", filter: l, disabled: p = !1, required: g = !1, className: _, id: v, "aria-label": y, "aria-labelledby": b, "aria-invalid": x, "aria-describedby": S, ...C }) {
	let w = k(v, "sx-combobox"), T = K({
		id: w,
		disabled: p,
		required: g,
		"aria-label": y,
		"aria-labelledby": b,
		"aria-invalid": x,
		"aria-describedby": S
	}), [E, O] = A({
		value: t,
		defaultValue: n ?? "",
		onChange: r
	}), [j, N] = A({
		value: i,
		defaultValue: a,
		onChange: o
	}), [P, F] = f(!1), [I, R] = f(0), z = d(null), B = d(null);
	M([B], () => F(!1), P);
	let V = u(() => {
		let t = j.trim().toLocaleLowerCase();
		return t ? e.filter((e) => l?.(e, j) ?? [
			H(e.label),
			e.value.toLocaleLowerCase(),
			...(e.keywords ?? []).map((e) => e.toLocaleLowerCase())
		].some((e) => e.includes(t))) : e;
	}, [
		l,
		e,
		j
	]), U = (e) => {
		e.disabled || (O(e.value), N(ke(e)), F(!1), z.current?.focus());
	}, ee = (e) => {
		if (e.key === "ArrowDown" || e.key === "ArrowUp") {
			e.preventDefault(), F(!0);
			let t = e.key === "ArrowDown" ? 1 : -1, n = L(e, {
				current: I,
				length: V.length,
				orientation: "vertical",
				isDisabled: (e) => V[e]?.disabled === !0
			});
			n === null ? V.length > 0 && R(t === 1 ? 0 : V.length - 1) : R(n);
		} else if (e.key === "Enter" && P) {
			e.preventDefault();
			let t = V[I];
			t && U(t);
		} else e.key === "Escape" && (e.preventDefault(), F(!1));
	};
	return /* @__PURE__ */ h("div", {
		ref: B,
		className: D("sx-combobox", _),
		"data-sx-open": P || void 0,
		"data-sx-invalid": T["aria-invalid"] === !0 || T["aria-invalid"] === "true" || void 0,
		...C,
		children: [
			/* @__PURE__ */ m(q, {
				ref: z,
				role: "combobox",
				"aria-autocomplete": "list",
				"aria-expanded": P,
				"aria-controls": `${w}-listbox`,
				"aria-activedescendant": P && V[I] ? `${w}-option-${I}` : void 0,
				value: j,
				placeholder: s,
				...T,
				onFocus: () => F(!0),
				onChange: (e) => {
					N(e.currentTarget.value), F(!0), R(0);
				},
				onKeyDown: ee
			}),
			/* @__PURE__ */ m("input", {
				type: "hidden",
				value: E,
				readOnly: !0
			}),
			P ? /* @__PURE__ */ m("div", {
				id: `${w}-listbox`,
				className: "sx-combobox__list",
				role: "listbox",
				children: V.length === 0 ? /* @__PURE__ */ m("div", {
					className: "sx-combobox__empty",
					children: c
				}) : V.map((e, t) => /* @__PURE__ */ h("button", {
					id: `${w}-option-${t}`,
					type: "button",
					role: "option",
					tabIndex: -1,
					className: "sx-combobox__option",
					"aria-selected": E === e.value,
					"data-sx-active": I === t || void 0,
					disabled: e.disabled,
					onPointerMove: () => R(t),
					onMouseDown: (e) => e.preventDefault(),
					onClick: () => U(e),
					children: [/* @__PURE__ */ m("span", {
						className: "sx-combobox__option-label",
						children: e.label
					}), e.description ? /* @__PURE__ */ m("span", {
						className: "sx-combobox__option-description",
						children: e.description
					}) : null]
				}, e.value))
			}) : null
		]
	});
}
function Me({ minimumQueryLength: e = 0, filter: t, ...n }) {
	return /* @__PURE__ */ m(je, {
		...n,
		filter: (n, r) => r.length >= e && (t?.(n, r) ?? [
			H(n.label),
			n.value.toLocaleLowerCase(),
			...n.keywords ?? []
		].join(" ").includes(r.toLocaleLowerCase()))
	});
}
function Ne({ options: e, value: t, defaultValue: n = [], onValueChange: r, placeholder: i = "Select options", searchPlaceholder: a = "Filter options", disabled: o = !1, required: c = !1, className: l, id: u, "aria-label": p, "aria-labelledby": g, "aria-invalid": _, "aria-describedby": v, onKeyDown: y, ...b }) {
	let x = k(u, "sx-multiselect"), S = K({
		id: x,
		disabled: o,
		required: c,
		"aria-invalid": _,
		"aria-describedby": v
	}), [C, w] = A({
		value: t,
		defaultValue: n,
		onChange: r
	}), [T, E] = f(""), [O, j] = f(!1), N = d(null), P = d(null), F = d(null);
	M([N], () => j(!1), O), s(() => {
		O && F.current?.focus();
	}, [O]);
	let I = e.filter((e) => [
		H(e.label),
		e.value,
		...e.keywords ?? []
	].join(" ").toLocaleLowerCase().includes(T.toLocaleLowerCase())), L = (e) => {
		e.disabled || w(C.includes(e.value) ? C.filter((t) => t !== e.value) : [...C, e.value]);
	};
	return /* @__PURE__ */ h("div", {
		ref: N,
		className: D("sx-multi-select", l),
		"data-sx-open": O || void 0,
		"data-sx-invalid": S["aria-invalid"] === !0 || S["aria-invalid"] === "true" || void 0,
		...b,
		onKeyDown: (e) => {
			y?.(e), !(e.defaultPrevented || e.key !== "Escape" || !O) && (e.preventDefault(), e.stopPropagation(), j(!1), queueMicrotask(() => P.current?.focus()));
		},
		children: [/* @__PURE__ */ h("button", {
			ref: P,
			type: "button",
			id: S.id,
			className: "sx-multi-select__trigger",
			"aria-label": p,
			"aria-labelledby": g,
			"aria-haspopup": "dialog",
			"aria-expanded": O,
			"aria-controls": `${x}-popover`,
			"aria-describedby": S["aria-describedby"],
			"aria-invalid": S["aria-invalid"],
			"aria-required": S.required || void 0,
			disabled: S.disabled,
			onClick: () => j(!O),
			children: [/* @__PURE__ */ m("span", {
				className: "sx-multi-select__summary",
				children: C.length === 0 ? i : `${C.length} selected`
			}), /* @__PURE__ */ m("span", {
				className: "sx-icon sx-icon--chevron",
				"aria-hidden": "true"
			})]
		}), O ? /* @__PURE__ */ h("div", {
			id: `${x}-popover`,
			className: "sx-multi-select__popover",
			role: "dialog",
			"aria-label": p ?? i,
			"aria-labelledby": g,
			children: [/* @__PURE__ */ m(J, {
				ref: F,
				value: T,
				placeholder: a,
				"aria-label": a,
				onChange: (e) => E(e.currentTarget.value),
				onClear: () => E("")
			}), /* @__PURE__ */ m("div", {
				className: "sx-multi-select__list",
				role: "group",
				"aria-label": "Options",
				children: I.map((e) => /* @__PURE__ */ m(Te, {
					label: e.label,
					description: e.description,
					checked: C.includes(e.value),
					disabled: e.disabled,
					onChange: () => L(e)
				}, e.value))
			})]
		}) : null]
	});
}
function Pe({ options: e, value: t, defaultValue: n, onValueChange: r, label: i, className: a, ...o }) {
	let [s, c] = A({
		value: t,
		defaultValue: n ?? e.find((e) => !e.disabled)?.value ?? "",
		onChange: r
	}), l = d([]), u = Math.max(0, e.findIndex((e) => e.value === s)), f = (t) => {
		let n = e[t];
		!n || n.disabled || (c(n.value), l.current[t]?.focus());
	};
	return /* @__PURE__ */ m("div", {
		className: D("sx-segmented-control", a),
		role: "radiogroup",
		"aria-label": i,
		...o,
		children: e.map((t, n) => /* @__PURE__ */ h("button", {
			ref: (e) => {
				l.current[n] = e;
			},
			type: "button",
			role: "radio",
			className: "sx-segmented-control__item",
			"aria-checked": t.value === s,
			disabled: t.disabled,
			tabIndex: n === u ? 0 : -1,
			onClick: () => f(n),
			onKeyDown: (t) => {
				let r = L(t, {
					current: n,
					length: e.length,
					isDisabled: (t) => e[t]?.disabled === !0
				});
				r !== null && f(r);
			},
			children: [t.icon ? /* @__PURE__ */ m("span", {
				className: "sx-segmented-control__icon",
				"aria-hidden": "true",
				children: t.icon
			}) : null, /* @__PURE__ */ m("span", { children: t.label })]
		}, t.value))
	});
}
//#endregion
//#region src/navigation.tsx
function Fe({ items: e, value: t, defaultValue: n, onValueChange: r, orientation: i = "horizontal", activation: a = "automatic", label: o, className: s, ...c }) {
	let l = k(void 0, "sx-tabs"), [u, f] = A({
		value: t,
		defaultValue: n ?? e.find((e) => !e.disabled)?.value ?? "",
		onChange: r
	}), p = d([]), g = Math.max(0, e.findIndex((e) => e.value === u)), _ = (t, n) => {
		let r = e[t];
		!r || r.disabled || (p.current[t]?.focus(), n && f(r.value));
	}, v = e.find((e) => e.value === u);
	return /* @__PURE__ */ h("div", {
		className: D("sx-tabs", s),
		"data-sx-orientation": i,
		...c,
		children: [/* @__PURE__ */ m("div", {
			role: "tablist",
			className: "sx-tabs__list",
			"aria-label": o,
			"aria-orientation": i,
			children: e.map((t, n) => /* @__PURE__ */ h("button", {
				ref: (e) => {
					p.current[n] = e;
				},
				id: `${l}-tab-${n}`,
				type: "button",
				role: "tab",
				className: "sx-tabs__tab",
				"aria-selected": u === t.value,
				"aria-controls": `${l}-panel-${n}`,
				disabled: t.disabled,
				tabIndex: n === g ? 0 : -1,
				onClick: () => f(t.value),
				onKeyDown: (r) => {
					let o = L(r, {
						current: n,
						length: e.length,
						orientation: i,
						isDisabled: (t) => e[t]?.disabled === !0
					});
					o !== null && _(o, a === "automatic"), (r.key === "Enter" || r.key === " ") && a === "manual" && (r.preventDefault(), f(t.value));
				},
				children: [/* @__PURE__ */ m("span", { children: t.label }), t.badge ? /* @__PURE__ */ m("span", {
					className: "sx-tabs__badge",
					children: t.badge
				}) : null]
			}, t.value))
		}), v ? /* @__PURE__ */ m("div", {
			id: `${l}-panel-${g}`,
			role: "tabpanel",
			className: "sx-tabs__panel",
			"aria-labelledby": `${l}-tab-${g}`,
			tabIndex: 0,
			children: v.content
		}) : null]
	});
}
var Ie = r(function({ items: e, label: t = "Breadcrumb", separator: n = /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--chevron" }), className: r, ...i }, a) {
	return /* @__PURE__ */ m("nav", {
		ref: a,
		className: D("sx-breadcrumb", r),
		"aria-label": t,
		...i,
		children: /* @__PURE__ */ m("ol", {
			className: "sx-breadcrumb__list",
			children: e.map((t, r) => {
				let i = r === e.length - 1;
				return /* @__PURE__ */ h("li", {
					className: "sx-breadcrumb__item",
					children: [r > 0 ? /* @__PURE__ */ m("span", {
						className: "sx-breadcrumb__separator",
						"aria-hidden": "true",
						children: n
					}) : null, i ? /* @__PURE__ */ m("span", {
						"aria-current": "page",
						children: t.label
					}) : t.href ? /* @__PURE__ */ m("a", {
						href: t.href,
						onClick: t.onClick,
						children: t.label
					}) : /* @__PURE__ */ m("button", {
						type: "button",
						onClick: t.onClick,
						children: t.label
					})]
				}, r);
			})
		})
	});
}), Le = r(function({ page: e, pageCount: t, onPageChange: n, siblingCount: r = 1, label: i = "Pagination", className: a, ...o }, s) {
	let c = Math.min(t, Math.max(1, e)), l = Array.from({ length: t }, (e, t) => t + 1).filter((e) => e === 1 || e === t || Math.abs(e - c) <= r), u = [];
	for (let e of l) {
		let t = u.at(-1);
		typeof t == "number" && e - t > 1 && u.push("ellipsis"), u.push(e);
	}
	return /* @__PURE__ */ h("nav", {
		ref: s,
		className: D("sx-pagination", a),
		"aria-label": i,
		...o,
		children: [
			/* @__PURE__ */ m(G, {
				label: "Previous page",
				variant: "quiet",
				icon: /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--previous" }),
				disabled: c <= 1,
				onClick: () => n(c - 1)
			}),
			/* @__PURE__ */ m("ol", {
				className: "sx-pagination__pages",
				children: u.map((e, t) => e === "ellipsis" ? /* @__PURE__ */ m("li", {
					className: "sx-pagination__ellipsis",
					"aria-hidden": "true",
					children: "…"
				}, `ellipsis-${t}`) : /* @__PURE__ */ m("li", { children: /* @__PURE__ */ m(W, {
					variant: e === c ? "primary" : "quiet",
					"aria-current": e === c ? "page" : void 0,
					"aria-label": `Page ${e}`,
					onClick: () => n(e),
					children: e
				}) }, e))
			}),
			/* @__PURE__ */ m(G, {
				label: "Next page",
				variant: "quiet",
				icon: /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--next" }),
				disabled: c >= t,
				onClick: () => n(c + 1)
			})
		]
	});
});
function Re({ steps: e, value: t, completed: n = [], onValueChange: r, orientation: i = "horizontal", className: a, ...o }) {
	return /* @__PURE__ */ m("ol", {
		className: D("sx-stepper", a),
		"data-sx-orientation": i,
		...o,
		children: e.map((e, i) => {
			let a = t === e.value, o = n.includes(e.value);
			return /* @__PURE__ */ m("li", {
				className: "sx-stepper__step",
				"data-sx-state": a ? "current" : o ? "complete" : "pending",
				children: /* @__PURE__ */ h("button", {
					type: "button",
					className: "sx-stepper__trigger",
					"aria-current": a ? "step" : void 0,
					disabled: e.disabled || !r,
					onClick: () => r?.(e.value),
					children: [/* @__PURE__ */ m("span", {
						className: "sx-stepper__index",
						"aria-hidden": "true",
						children: o ? /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--check" }) : i + 1
					}), /* @__PURE__ */ h("span", {
						className: "sx-stepper__copy",
						children: [/* @__PURE__ */ h("span", {
							className: "sx-stepper__label",
							children: [e.label, e.optional ? /* @__PURE__ */ m("span", {
								className: "sx-stepper__optional",
								children: " Optional"
							}) : null]
						}), e.description ? /* @__PURE__ */ m("span", {
							className: "sx-stepper__description",
							children: e.description
						}) : null]
					})]
				})
			}, e.value);
		})
	});
}
function ze({ item: e, activeId: t, onNavigate: n, depth: r }) {
	let i = e.id === t, a = /* @__PURE__ */ h(p, { children: [
		/* @__PURE__ */ m("span", {
			className: "sx-side-nav__icon",
			"aria-hidden": "true",
			children: e.icon
		}),
		/* @__PURE__ */ m("span", {
			className: "sx-side-nav__label",
			children: e.label
		}),
		e.badge ? /* @__PURE__ */ m("span", {
			className: "sx-side-nav__badge",
			children: e.badge
		}) : null
	] }), o = {
		disabled: e.disabled,
		"aria-current": i ? "page" : void 0
	};
	return /* @__PURE__ */ h("li", {
		className: "sx-side-nav__item",
		"data-sx-depth": r,
		children: [e.href ? /* @__PURE__ */ m("a", {
			className: "sx-side-nav__link",
			href: e.href,
			"aria-current": i ? "page" : void 0,
			"aria-disabled": e.disabled || void 0,
			onClick: (t) => {
				e.disabled ? t.preventDefault() : n?.(e);
			},
			children: a
		}) : /* @__PURE__ */ m("button", {
			...o,
			type: "button",
			className: "sx-side-nav__link",
			onClick: () => n?.(e),
			children: a
		}), e.children?.length ? /* @__PURE__ */ m("ul", {
			className: "sx-side-nav__group",
			children: e.children.map((e) => /* @__PURE__ */ m(ze, {
				item: e,
				activeId: t,
				onNavigate: n,
				depth: r + 1
			}, e.id))
		}) : null]
	});
}
var Be = r(function({ items: e, activeId: t, onNavigate: n, label: r = "Navigation", collapsed: i = !1, className: a, ...o }, s) {
	return /* @__PURE__ */ m("nav", {
		ref: s,
		className: D("sx-side-nav", a),
		"aria-label": r,
		"data-sx-collapsed": i || void 0,
		...o,
		children: /* @__PURE__ */ m("ul", {
			className: "sx-side-nav__list",
			children: e.map((e) => /* @__PURE__ */ m(ze, {
				item: e,
				activeId: t,
				onNavigate: n,
				depth: 0
			}, e.id))
		})
	});
}), Y = r(function({ open: e, defaultOpen: t = !1, onOpenChange: n, title: r, description: i, closeLabel: a = "Close dialog", footer: o, initialFocusRef: c, closeOnEscape: l = !0, closeOnBackdrop: u = !0, showCloseButton: f, modal: p = !0, size: g = "md", dialogRole: _ = "dialog", className: v, children: y, ...b }, x) {
	let [S, C] = A({
		value: e,
		defaultValue: t,
		onChange: n
	}), w = f ?? (l || u), T = d(null), E = k(void 0, "sx-dialog-title"), O = `${E}-description`;
	return F(T, S && p, { ...c ? { initialFocusRef: c } : {} }), s(() => {
		if (!S || !p) return;
		let e = document.documentElement.style.overflow;
		return document.documentElement.style.overflow = "hidden", () => {
			document.documentElement.style.overflow = e;
		};
	}, [p, S]), s(() => {
		if (!S || !l) return;
		let e = (e) => {
			if (e.key === "Escape") {
				let t = document.querySelectorAll(".sx-dialog");
				if (t.item(t.length - 1) !== T.current) return;
				e.preventDefault(), e.stopPropagation(), e.stopImmediatePropagation(), C(!1);
			}
		};
		return document.addEventListener("keydown", e), () => document.removeEventListener("keydown", e);
	}, [
		l,
		C,
		S
	]), S ? /* @__PURE__ */ m("div", {
		className: "sx-dialog-layer",
		"data-sx-modal": p || void 0,
		onMouseDown: (e) => {
			u && e.target === e.currentTarget && C(!1);
		},
		children: /* @__PURE__ */ h("div", {
			...b,
			ref: z(T, x),
			role: _,
			"aria-modal": p || void 0,
			"aria-labelledby": E,
			"aria-describedby": i ? O : void 0,
			tabIndex: -1,
			className: D("sx-dialog", v),
			"data-sx-size": g,
			children: [
				/* @__PURE__ */ h("header", {
					className: "sx-dialog__header",
					children: [/* @__PURE__ */ h("div", {
						className: "sx-dialog__heading",
						children: [/* @__PURE__ */ m("h2", {
							id: E,
							className: "sx-dialog__title",
							children: r
						}), i ? /* @__PURE__ */ m("p", {
							id: O,
							className: "sx-dialog__description",
							children: i
						}) : null]
					}), w ? /* @__PURE__ */ m(G, {
						label: a,
						variant: "quiet",
						icon: /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--close" }),
						onClick: () => C(!1)
					}) : null]
				}),
				/* @__PURE__ */ m("div", {
					className: "sx-dialog__body",
					children: y
				}),
				o ? /* @__PURE__ */ m("footer", {
					className: "sx-dialog__footer",
					children: o
				}) : null
			]
		})
	}) : null;
});
function Ve({ confirmLabel: e, cancelLabel: t = "Cancel", onConfirm: n, onCancel: r, onOpenChange: i, destructive: a = !1, busy: o = !1, ...s }) {
	let c = d(null), l = () => {
		r?.(), i?.(!1);
	};
	return /* @__PURE__ */ m(Y, {
		...s,
		onOpenChange: i,
		initialFocusRef: c,
		closeOnBackdrop: !o,
		closeOnEscape: !o,
		dialogRole: "alertdialog",
		footer: /* @__PURE__ */ h(_e, { children: [/* @__PURE__ */ m(W, {
			ref: c,
			variant: "secondary",
			disabled: o,
			onClick: l,
			children: t
		}), /* @__PURE__ */ m(W, {
			variant: a ? "danger" : "primary",
			loading: o,
			onClick: () => void n(),
			children: e
		})] })
	});
}
var He = r(function({ trigger: e, content: t, open: n, defaultOpen: r = !1, onOpenChange: i, placement: a = "bottom", align: o = "start", label: s = "Popover", className: c, ...l }, u) {
	let [f, p] = A({
		value: n,
		defaultValue: r,
		onChange: i
	}), g = d(null), _ = d(null), v = k(void 0, "sx-popover");
	M([g, _], () => p(!1), f);
	let y = () => {
		p(!1), queueMicrotask(() => g.current?.querySelector(`[aria-controls="${v}"]`)?.focus());
	};
	return /* @__PURE__ */ h("div", {
		ref: z(g, u),
		className: D("sx-popover", c),
		"data-sx-open": f || void 0,
		...l,
		children: [/* @__PURE__ */ m(B, {
			className: "sx-popover__anchor",
			popup: "dialog",
			expanded: f,
			controls: v,
			onActivate: () => p(!f),
			children: e
		}), f ? /* @__PURE__ */ m("div", {
			id: v,
			ref: _,
			role: "dialog",
			"aria-label": s,
			className: "sx-popover__content",
			"data-sx-placement": a,
			"data-sx-align": o,
			onKeyDown: (e) => {
				e.key === "Escape" && (e.preventDefault(), y());
			},
			children: t
		}) : null]
	});
});
function Ue({ side: e = "right", className: t, ...n }) {
	return /* @__PURE__ */ m(Y, {
		...n,
		className: D("sx-drawer", t),
		"data-sx-side": e,
		size: "lg"
	});
}
function We({ edge: e = "bottom", className: t, ...n }) {
	return /* @__PURE__ */ m(Y, {
		...n,
		className: D("sx-sheet", t),
		"data-sx-edge": e,
		size: "lg"
	});
}
function Ge(e) {
	return /* @__PURE__ */ m(Y, {
		...e,
		modal: !0
	});
}
//#endregion
//#region src/utilities.tsx
var Ke = r(function({ content: t, placement: n = "top", delay: r = 250, disabled: a = !1, className: o, children: c, ...l }, u) {
	let p = k(void 0, "sx-tooltip"), [g, _] = f(!1), v = d(void 0);
	s(() => () => window.clearTimeout(v.current), []), s(() => {
		a && (window.clearTimeout(v.current), _(!1));
	}, [a]);
	let y = () => {
		a || (window.clearTimeout(v.current), v.current = window.setTimeout(() => _(!0), r));
	}, b = () => {
		window.clearTimeout(v.current), _(!1);
	}, x = i(c) ? e(c, { "aria-describedby": O(c.props["aria-describedby"], g ? p : void 0) }) : /* @__PURE__ */ m("span", {
		className: "sx-tooltip__fallback-anchor",
		tabIndex: 0,
		"aria-describedby": g ? p : void 0,
		children: c
	});
	return /* @__PURE__ */ h("span", {
		ref: u,
		className: D("sx-tooltip", o),
		"data-sx-open": g || void 0,
		onPointerEnter: y,
		onPointerLeave: b,
		onFocus: y,
		onBlur: b,
		...l,
		children: [/* @__PURE__ */ m("span", {
			className: "sx-tooltip__anchor",
			children: x
		}), g ? /* @__PURE__ */ m("span", {
			id: p,
			role: "tooltip",
			className: "sx-tooltip__content",
			"data-sx-placement": n,
			children: t
		}) : null]
	});
}), X = r(function({ className: e, ...t }, n) {
	return /* @__PURE__ */ m("kbd", {
		ref: n,
		className: D("sx-key-hint", e),
		...t
	});
}), qe = r(function({ keys: e, separator: t = "+", label: n, className: r, ...i }, a) {
	return /* @__PURE__ */ m("span", {
		ref: a,
		className: D("sx-shortcut", r),
		"aria-label": n ?? e.join(" plus "),
		...i,
		children: e.map((e, n) => /* @__PURE__ */ h("span", {
			className: "sx-shortcut__part",
			children: [n > 0 ? /* @__PURE__ */ m("span", {
				className: "sx-shortcut__separator",
				"aria-hidden": "true",
				children: t
			}) : null, /* @__PURE__ */ m(X, { children: e })]
		}, `${e}-${n}`))
	});
}), Je = {
	check: ["M5 12.5l4.2 4.2L19 6.9"],
	close: ["M6 6l12 12", "M18 6L6 18"],
	"chevron-down": ["M6.5 9l5.5 5.5L17.5 9"],
	"chevron-right": ["M9 6.5l5.5 5.5L9 17.5"],
	"arrow-left": ["M19 12H5", "M11 6l-6 6 6 6"],
	"arrow-right": ["M5 12h14", "M13 6l6 6-6 6"],
	search: ["M10.5 18a7.5 7.5 0 1 1 0-15 7.5 7.5 0 0 1 0 15Z", "m16 16 5 5"],
	plus: ["M12 5v14", "M5 12h14"],
	minus: ["M5 12h14"],
	more: [
		"M6 12h.01",
		"M12 12h.01",
		"M18 12h.01"
	],
	copy: ["M9 8h10v11H9z", "M5 16V5h10"],
	eye: ["M2.5 12s3.5-6 9.5-6 9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6Z", "M12 9a3 3 0 1 1 0 6 3 3 0 0 1 0-6Z"],
	"eye-off": [
		"M4 4l16 16",
		"M9.5 6.4A10.9 10.9 0 0 1 12 6c6 0 9.5 6 9.5 6a13 13 0 0 1-2.4 3.1",
		"M6.2 7.3A13.5 13.5 0 0 0 2.5 12s3.5 6 9.5 6c1 0 2-.2 2.8-.5"
	],
	info: [
		"M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Z",
		"M12 10v7",
		"M12 7h.01"
	],
	warning: [
		"M12 3 2.5 20h19L12 3Z",
		"M12 9v5",
		"M12 17h.01"
	],
	error: [
		"M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Z",
		"M8.5 8.5l7 7",
		"M15.5 8.5l-7 7"
	],
	success: ["M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Z", "M7.5 12l3 3 6-7"],
	menu: [
		"M4 7h16",
		"M4 12h16",
		"M4 17h16"
	],
	command: ["M9 8V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6"],
	signal: [
		"M4 17V7",
		"M9.3 17V10",
		"M14.7 17V5",
		"M20 17v-8"
	]
}, Ye = r(function({ name: e, label: t, size: n = "md", tone: r, className: i, ...a }, o) {
	return /* @__PURE__ */ m("svg", {
		ref: o,
		viewBox: "0 0 24 24",
		fill: "none",
		stroke: "currentColor",
		strokeWidth: "1.8",
		strokeLinecap: "round",
		strokeLinejoin: "round",
		className: D("sx-synex-icon", i),
		"data-sx-size": n,
		"data-sx-tone": r,
		role: t ? "img" : void 0,
		"aria-label": t,
		"aria-hidden": !t || void 0,
		...a,
		children: Je[e].map((e, t) => /* @__PURE__ */ m("path", { d: e }, t))
	});
}), Xe = Ye, Ze = r(function({ className: e, ...t }, n) {
	return /* @__PURE__ */ m("span", {
		ref: n,
		className: D("sx-visually-hidden", e),
		...t
	});
});
//#endregion
//#region src/menus.tsx
function Z(e) {
	return e.type === "separator" || e.type === "label" || e.disabled === !0;
}
var Q = r(function({ items: e, label: t = "Menu", onClose: n, initialActiveId: r, autoFocus: i = !0, className: a, onKeyDown: o, ...c }, l) {
	let u = e.findIndex((e) => e.id === r && !Z(e)), p = e.findIndex((e) => !Z(e)), [g, _] = f(u >= 0 ? u : Math.max(0, p)), v = d([]), y = d(!1), [b, x] = f(null);
	s(() => {
		if (!i || y.current) return;
		let t = Z(e[g] ?? {
			type: "separator",
			id: "none"
		}) ? e.findIndex((e) => !Z(e)) : g;
		t >= 0 && (y.current = !0, queueMicrotask(() => v.current[t]?.focus()));
	}, [i, e]), s(() => {
		let t = e.findIndex((e) => !Z(e));
		Z(e[g] ?? {
			type: "separator",
			id: "none"
		}) && _(Math.max(0, t));
	}, [g, e]);
	let S = (e) => {
		_(e), v.current[e]?.focus();
	}, C = (e) => {
		if (!Z(e) && e.type !== "separator") {
			if (e.type === "checkbox") e.onCheckedChange(!e.checked);
			else if (e.type === "radio") e.onValueChange(e.value);
			else if (e.type === "submenu") {
				x(b === e.id ? null : e.id);
				return;
			} else (e.type === "action" || e.type === void 0) && e.onSelect();
			n?.();
		}
	};
	return /* @__PURE__ */ m("div", {
		ref: l,
		role: "menu",
		"aria-label": t,
		className: D("sx-menu", a),
		tabIndex: -1,
		onKeyDown: (t) => {
			if (o?.(t), t.defaultPrevented) return;
			let r = L(t, {
				current: g,
				length: e.length,
				orientation: "vertical",
				isDisabled: (t) => Z(e[t] ?? {
					type: "separator",
					id: "missing"
				})
			});
			r === null ? t.key === "Escape" || t.key === "ArrowLeft" ? n && (t.preventDefault(), t.stopPropagation(), n()) : (t.key === "Enter" || t.key === " ") && e[g] ? (t.preventDefault(), t.stopPropagation(), C(e[g])) : t.key === "ArrowRight" && e[g]?.type === "submenu" && (t.preventDefault(), t.stopPropagation(), x(e[g].id)) : (t.stopPropagation(), S(r));
		},
		...c,
		children: e.map((e, n) => {
			if (e.type === "separator") return /* @__PURE__ */ m("div", {
				role: "separator",
				className: "sx-menu__separator"
			}, e.id);
			if (e.type === "label") return /* @__PURE__ */ m("div", {
				role: "presentation",
				className: "sx-menu__label",
				children: e.label
			}, e.id);
			let r = e.type === "checkbox" ? e.checked : e.type === "radio" ? e.value === e.selectedValue : void 0, i = e.type === "checkbox" ? "menuitemcheckbox" : e.type === "radio" ? "menuitemradio" : "menuitem", a = e.type === "submenu" && b === e.id;
			return /* @__PURE__ */ h("div", {
				className: "sx-menu__entry",
				"data-sx-submenu-open": a || void 0,
				children: [/* @__PURE__ */ h("button", {
					ref: (e) => {
						v.current[n] = e;
					},
					type: "button",
					role: i,
					className: "sx-menu__item",
					tabIndex: g === n ? 0 : -1,
					disabled: e.disabled,
					"aria-checked": r,
					"aria-haspopup": e.type === "submenu" ? "menu" : void 0,
					"aria-expanded": e.type === "submenu" ? a : void 0,
					"data-sx-danger": e.type === "action" && e.danger || void 0,
					onFocus: () => _(n),
					onPointerMove: () => {
						e.disabled || _(n);
					},
					onClick: () => C(e),
					children: [
						e.type === "checkbox" || e.type === "radio" ? /* @__PURE__ */ m("span", {
							className: "sx-menu__check",
							"aria-hidden": "true",
							children: r ? /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--check" }) : null
						}) : "icon" in e && e.icon ? /* @__PURE__ */ m("span", {
							className: "sx-menu__icon",
							"aria-hidden": "true",
							children: e.icon
						}) : /* @__PURE__ */ m("span", { className: "sx-menu__icon" }),
						/* @__PURE__ */ m("span", {
							className: "sx-menu__label",
							children: e.label
						}),
						e.type === "action" && e.hint ? /* @__PURE__ */ m(X, { children: e.hint }) : null,
						e.type === "submenu" ? /* @__PURE__ */ m("span", {
							className: "sx-icon sx-icon--next",
							"aria-hidden": "true"
						}) : null
					]
				}), a && e.type === "submenu" ? /* @__PURE__ */ m(Qe, {
					items: e.items,
					label: `${t} submenu`,
					onClose: () => {
						x(null), queueMicrotask(() => v.current[n]?.focus());
					}
				}) : null]
			}, e.id);
		})
	});
}), Qe = r(function({ placement: e = "right-start", className: t, ...n }, r) {
	return /* @__PURE__ */ m(Q, {
		ref: r,
		className: D("sx-submenu", t),
		"data-sx-placement": e,
		...n
	});
}), $e = r(function({ trigger: e, items: t, label: n, open: r, defaultOpen: i = !1, onOpenChange: a, align: o = "end", className: s, ...c }, l) {
	let [u, f] = A({
		value: r,
		defaultValue: i,
		onChange: a
	}), p = d(null), g = k(void 0, "sx-dropdown-menu");
	M([p], () => f(!1), u);
	let _ = () => {
		f(!1), queueMicrotask(() => p.current?.querySelector(`[aria-controls="${g}"]`)?.focus());
	};
	return /* @__PURE__ */ h("div", {
		ref: (e) => {
			p.current = e, typeof l == "function" ? l(e) : l && (l.current = e);
		},
		className: D("sx-dropdown", s),
		"data-sx-open": u || void 0,
		...c,
		children: [/* @__PURE__ */ m(B, {
			className: "sx-dropdown__trigger",
			popup: "menu",
			expanded: u,
			controls: g,
			onActivate: () => f(!u),
			children: e
		}), u ? /* @__PURE__ */ m(Q, {
			id: g,
			className: "sx-dropdown__menu",
			"data-sx-align": o,
			items: t,
			label: n,
			onClose: _
		}) : null]
	});
}), et = r(function({ items: e, label: t = "Context menu", className: n, children: r, onKeyDown: i, tabIndex: a, ...o }, s) {
	let [c, l] = f(null), u = d(null), p = d(null);
	M([u, p], () => l(null), c !== null);
	let g = (e, t) => l({
		x: Math.max(8, Math.min(e, window.innerWidth - 240)),
		y: Math.max(8, Math.min(t, window.innerHeight - 320))
	}), _ = () => {
		l(null), queueMicrotask(() => u.current?.focus());
	};
	return /* @__PURE__ */ h("div", {
		ref: (e) => {
			u.current = e, typeof s == "function" ? s(e) : s && (s.current = e);
		},
		className: D("sx-context-menu", n),
		tabIndex: a ?? 0,
		"aria-haspopup": "menu",
		"aria-expanded": c !== null,
		onContextMenu: (e) => {
			e.preventDefault(), g(e.clientX, e.clientY);
		},
		onKeyDown: (e) => {
			if (i?.(e), !e.defaultPrevented) {
				if (e.key === "ContextMenu" || e.shiftKey && e.key === "F10") {
					e.preventDefault();
					let t = e.currentTarget.getBoundingClientRect();
					g(t.left + Math.min(t.width / 2, 120), t.top + Math.min(t.height / 2, 48));
				} else e.key === "Escape" && c !== null && (e.preventDefault(), _());
			}
		},
		...o,
		children: [r, c ? /* @__PURE__ */ m("div", {
			className: "sx-context-menu__layer",
			style: R({
				"--sx-context-x": `${c.x}px`,
				"--sx-context-y": `${c.y}px`
			}),
			children: /* @__PURE__ */ m(Q, {
				ref: p,
				items: e,
				label: t,
				onClose: _
			})
		}) : null]
	});
});
function tt({ triggerLabel: e = "Actions", trigger: t, ...n }) {
	return /* @__PURE__ */ m($e, {
		...n,
		trigger: t ?? /* @__PURE__ */ m(G, {
			label: e,
			variant: "quiet",
			icon: /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--more" })
		})
	});
}
//#endregion
//#region src/feedback.tsx
var nt = r(function({ label: e = "Loading", size: t = "md", className: n, ...r }, i) {
	let a = e.trim().length > 0;
	return /* @__PURE__ */ m("span", {
		ref: i,
		role: a ? "status" : void 0,
		className: D("sx-spinner", n),
		"data-sx-size": t,
		"aria-label": a ? e : void 0,
		"aria-hidden": !a || void 0,
		...r,
		children: /* @__PURE__ */ m("span", {
			className: "sx-spinner__track",
			"aria-hidden": "true"
		})
	});
}), rt = r(function({ shape: e = "rect", lines: t = 1, className: n, ...r }, i) {
	return /* @__PURE__ */ m("div", {
		ref: i,
		className: D("sx-skeleton", n),
		"data-sx-shape": e,
		"aria-hidden": "true",
		...r,
		children: Array.from({ length: Math.max(1, t) }, (e, n) => /* @__PURE__ */ m("span", {
			className: "sx-skeleton__line",
			"data-sx-last": n === t - 1 || void 0
		}, n))
	});
}), it = r(function({ value: e = 0, maximum: t = 100, label: n, showValue: r = !1, indeterminate: i = !1, tone: a = "accent", formatValue: o = (e, t) => `${Math.round(e / t * 100)}%`, className: s, ...c }, l) {
	let u = t > 0 ? t : 100, d = V(e, 0, u), f = d / u * 100;
	return /* @__PURE__ */ h("div", {
		ref: l,
		className: D("sx-progress", s),
		"data-sx-indeterminate": i || void 0,
		"data-sx-tone": a,
		...c,
		children: [/* @__PURE__ */ h("div", {
			className: "sx-progress__header",
			children: [/* @__PURE__ */ m("span", { children: n }), r ? /* @__PURE__ */ m("span", {
				className: "sx-progress__value",
				children: o(d, u)
			}) : null]
		}), /* @__PURE__ */ m("div", {
			className: "sx-progress__track",
			role: "progressbar",
			"aria-label": n,
			"aria-valuemin": 0,
			"aria-valuemax": u,
			"aria-valuenow": i ? void 0 : d,
			children: /* @__PURE__ */ m("span", {
				className: "sx-progress__fill",
				style: R({ "--sx-progress-ratio": String(f / 100) })
			})
		})]
	});
}), at = r(function({ value: e = 0, maximum: t = 100, label: n, size: r = 48, strokeWidth: i = 4, tone: a = "accent", children: o, className: s, ...c }, l) {
	let u = t > 0 ? t : 100, d = V(e, 0, u), f = Math.max(1, (r - i) / 2), p = 2 * Math.PI * f, g = p * (1 - d / u);
	return /* @__PURE__ */ h("div", {
		ref: l,
		role: "progressbar",
		"aria-label": n,
		"aria-valuemin": 0,
		"aria-valuemax": u,
		"aria-valuenow": d,
		className: D("sx-progress-ring", s),
		"data-sx-tone": a,
		style: {
			width: r,
			height: r
		},
		...c,
		children: [/* @__PURE__ */ h("svg", {
			viewBox: `0 0 ${r} ${r}`,
			"aria-hidden": "true",
			children: [/* @__PURE__ */ m("circle", {
				className: "sx-progress-ring__track",
				cx: r / 2,
				cy: r / 2,
				r: f,
				fill: "none",
				strokeWidth: i
			}), /* @__PURE__ */ m("circle", {
				className: "sx-progress-ring__value",
				cx: r / 2,
				cy: r / 2,
				r: f,
				fill: "none",
				strokeWidth: i,
				strokeDasharray: p,
				strokeDashoffset: g
			})]
		}), o ? /* @__PURE__ */ m("span", {
			className: "sx-progress-ring__content",
			children: o
		}) : null]
	});
}), ot = r(function({ visible: e, label: t = "Loading", description: n, blocking: r = !0, className: i, ...a }, o) {
	return e ? /* @__PURE__ */ h("div", {
		ref: o,
		className: D("sx-loading-overlay", i),
		role: "status",
		"aria-live": "polite",
		"data-sx-blocking": r || void 0,
		...a,
		children: [
			/* @__PURE__ */ m(nt, { label: "" }),
			/* @__PURE__ */ m("span", {
				className: "sx-loading-overlay__label",
				children: t
			}),
			n ? /* @__PURE__ */ m("span", {
				className: "sx-loading-overlay__description",
				children: n
			}) : null
		]
	}) : null;
}), st = r(function({ title: e, description: t, icon: n, primaryAction: r, secondaryAction: i, className: a, ...o }, s) {
	return /* @__PURE__ */ h("div", {
		ref: s,
		className: D("sx-empty-state", a),
		...o,
		children: [
			n ? /* @__PURE__ */ m("div", {
				className: "sx-empty-state__icon",
				"aria-hidden": "true",
				children: n
			}) : null,
			/* @__PURE__ */ m("h3", {
				className: "sx-empty-state__title",
				children: e
			}),
			t ? /* @__PURE__ */ m("p", {
				className: "sx-empty-state__description",
				children: t
			}) : null,
			r || i ? /* @__PURE__ */ h("div", {
				className: "sx-empty-state__actions",
				children: [i ? /* @__PURE__ */ m(W, {
					...i,
					variant: i.variant ?? "secondary",
					children: i.label
				}) : null, r ? /* @__PURE__ */ m(W, {
					...r,
					children: r.label
				}) : null]
			}) : null
		]
	});
}), ct = r(function({ title: e, description: t, tone: n = "neutral", action: r, onDismiss: i, dismissLabel: a = "Dismiss notification", className: o, ...s }, c) {
	return /* @__PURE__ */ h("div", {
		ref: c,
		role: n === "danger" ? "alert" : "status",
		className: D("sx-toast", o),
		"data-sx-tone": n,
		...s,
		children: [
			/* @__PURE__ */ m("span", {
				className: "sx-toast__signal",
				"aria-hidden": "true"
			}),
			/* @__PURE__ */ h("div", {
				className: "sx-toast__copy",
				children: [/* @__PURE__ */ m("strong", {
					className: "sx-toast__title",
					children: e
				}), t ? /* @__PURE__ */ m("span", {
					className: "sx-toast__description",
					children: t
				}) : null]
			}),
			r ? /* @__PURE__ */ m(W, {
				...r,
				variant: r.variant ?? "quiet",
				children: r.label
			}) : null,
			i ? /* @__PURE__ */ m("button", {
				type: "button",
				className: "sx-toast__dismiss",
				"aria-label": a,
				onClick: i,
				children: /* @__PURE__ */ m("span", {
					className: "sx-icon sx-icon--close",
					"aria-hidden": "true"
				})
			}) : null
		]
	});
});
//#endregion
//#region src/data.tsx
function lt({ columns: e, rows: t, rowKey: n, caption: r, empty: i = "No records", selectedKeys: a, onRowActivate: o, sort: s, onSortChange: c, className: l, ...u }) {
	return /* @__PURE__ */ m("div", {
		className: "sx-table-frame",
		children: /* @__PURE__ */ h("table", {
			className: D("sx-table", l),
			...u,
			children: [
				r ? /* @__PURE__ */ m("caption", { children: r }) : null,
				/* @__PURE__ */ m("thead", { children: /* @__PURE__ */ m("tr", { children: e.map((e) => /* @__PURE__ */ m("th", {
					scope: "col",
					"data-sx-align": e.align,
					style: e.width === void 0 ? void 0 : { width: e.width },
					"aria-sort": s?.columnId === e.id ? s.direction : void 0,
					children: e.sortable && c ? /* @__PURE__ */ h("button", {
						type: "button",
						className: "sx-table__sort",
						onClick: () => c({
							columnId: e.id,
							direction: s?.columnId === e.id && s.direction === "ascending" ? "descending" : "ascending"
						}),
						children: [e.header, /* @__PURE__ */ m("span", {
							className: "sx-table__sort-indicator",
							"aria-hidden": "true"
						})]
					}) : e.header
				}, e.id)) }) }),
				/* @__PURE__ */ m("tbody", { children: t.length === 0 ? /* @__PURE__ */ m("tr", { children: /* @__PURE__ */ m("td", {
					colSpan: e.length,
					className: "sx-table__empty",
					children: i
				}) }) : t.map((t, r) => {
					let i = n(t, r);
					return /* @__PURE__ */ m("tr", {
						"data-sx-selected": a?.has(i) || void 0,
						tabIndex: o ? 0 : void 0,
						onClick: () => o?.(t, r),
						onKeyDown: (e) => {
							o && (e.key === "Enter" || e.key === " ") && (e.preventDefault(), o(t, r));
						},
						children: e.map((e) => /* @__PURE__ */ m("td", {
							"data-sx-align": e.align,
							children: e.cell(t, r)
						}, e.id))
					}, i);
				}) })
			]
		})
	});
}
var ut = r(function({ items: e, onItemActivate: t, empty: n = "No items", className: r, ...i }, a) {
	return /* @__PURE__ */ m("ul", {
		ref: a,
		className: D("sx-data-list", r),
		...i,
		children: e.length === 0 ? /* @__PURE__ */ m("li", {
			className: "sx-data-list__empty",
			children: n
		}) : e.map((e) => /* @__PURE__ */ m(vt, {
			...e,
			onActivate: t ? () => t(e) : void 0
		}, e.id))
	});
}), dt = r(function({ items: e, onCopyValue: t, className: n, ...r }, i) {
	return /* @__PURE__ */ m("dl", {
		ref: i,
		className: D("sx-key-value-list", n),
		...r,
		children: e.map((e) => /* @__PURE__ */ h("div", {
			className: "sx-key-value-list__item",
			children: [/* @__PURE__ */ m("dt", { children: e.label }), /* @__PURE__ */ h("dd", { children: [e.value, e.copyable && t ? /* @__PURE__ */ m("button", {
				type: "button",
				className: "sx-key-value-list__copy",
				"aria-label": `Copy ${typeof e.label == "string" ? e.label : "value"}`,
				onClick: () => t(e),
				children: /* @__PURE__ */ m("span", {
					className: "sx-icon sx-icon--copy",
					"aria-hidden": "true"
				})
			}) : null] })]
		}, e.key))
	});
}), ft = r(function({ tone: e = "neutral", variant: t = "soft", size: n = "md", className: r, ...i }, a) {
	return /* @__PURE__ */ m("span", {
		ref: a,
		className: D("sx-badge", r),
		"data-sx-tone": e,
		"data-sx-variant": t,
		"data-sx-size": n,
		...i
	});
}), pt = {
	online: "positive",
	offline: "neutral",
	idle: "warning",
	busy: "danger",
	success: "positive",
	warning: "warning",
	error: "danger",
	unknown: "neutral"
}, mt = r(function({ status: e, pulse: t = !1, children: n, className: r, ...i }, a) {
	return /* @__PURE__ */ h(ft, {
		ref: a,
		className: D("sx-status-badge", r),
		tone: pt[e],
		"data-sx-status": e,
		"data-sx-pulse": t || void 0,
		...i,
		children: [/* @__PURE__ */ m("span", {
			className: "sx-status-badge__dot",
			"aria-hidden": "true"
		}), n ?? e]
	});
}), ht = r(function({ label: e, value: t, detail: n, trend: r, tone: i = "neutral", className: a, ...o }, s) {
	return /* @__PURE__ */ h("div", {
		ref: s,
		className: D("sx-stat", a),
		"data-sx-tone": i,
		...o,
		children: [
			/* @__PURE__ */ m("span", {
				className: "sx-stat__label",
				children: e
			}),
			/* @__PURE__ */ m("strong", {
				className: "sx-stat__value",
				children: t
			}),
			n ? /* @__PURE__ */ m("span", {
				className: "sx-stat__detail",
				"data-sx-trend": r,
				children: n
			}) : null
		]
	});
}), gt = r(function({ value: e, unit: t, progress: n, className: r, ...i }, a) {
	return /* @__PURE__ */ m(ht, {
		ref: a,
		className: D("sx-metric", r),
		value: /* @__PURE__ */ h(p, { children: [e, t ? /* @__PURE__ */ m("span", {
			className: "sx-metric__unit",
			children: t
		}) : null] }),
		"data-sx-progress": n,
		...i
	});
}), _t = r(function({ name: e, src: t, alt: n, size: r = "md", status: i, className: a, ...o }, s) {
	let c = e.split(/\s+/).filter(Boolean).slice(0, 2).map((e) => e[0]?.toLocaleUpperCase()).join("");
	return /* @__PURE__ */ h("span", {
		ref: s,
		className: D("sx-avatar", a),
		"data-sx-size": r,
		"aria-label": e,
		children: [t ? /* @__PURE__ */ m("img", {
			src: t,
			alt: n ?? "",
			...o
		}) : /* @__PURE__ */ m("span", {
			className: "sx-avatar__fallback",
			"aria-hidden": "true",
			children: c
		}), i ? /* @__PURE__ */ m("span", {
			className: "sx-avatar__status",
			"data-sx-status": i,
			"aria-label": i
		}) : null]
	});
}), vt = r(function({ primary: e, secondary: t, leading: n, trailing: r, disabled: i = !1, selected: a = !1, onActivate: o, className: s, ...c }, l) {
	return /* @__PURE__ */ m("li", {
		ref: l,
		className: D("sx-list-item", s),
		"data-sx-disabled": i || void 0,
		"data-sx-selected": a || void 0,
		...c,
		children: /* @__PURE__ */ h("div", {
			role: o ? "button" : void 0,
			tabIndex: o && !i ? 0 : void 0,
			className: "sx-list-item__content",
			onClick: () => {
				i || o?.();
			},
			onKeyDown: (e) => {
				!i && o && (e.key === "Enter" || e.key === " ") && (e.preventDefault(), o());
			},
			children: [
				n ? /* @__PURE__ */ m("span", {
					className: "sx-list-item__leading",
					children: n
				}) : null,
				/* @__PURE__ */ h("span", {
					className: "sx-list-item__copy",
					children: [/* @__PURE__ */ m("span", {
						className: "sx-list-item__primary",
						children: e
					}), t ? /* @__PURE__ */ m("span", {
						className: "sx-list-item__secondary",
						children: t
					}) : null]
				}),
				r ? /* @__PURE__ */ m("span", {
					className: "sx-list-item__trailing",
					children: r
				}) : null
			]
		})
	});
});
//#endregion
//#region src/advanced/virtual.tsx
function yt({ items: e, itemKey: t, renderItem: n, itemSize: r, height: i, overscan: a = 4, ariaLabel: o, initialScrollOffset: s = 0, onVisibleRangeChange: c, className: l, style: d, onScroll: p, onKeyDown: h, tabIndex: g, ..._ }) {
	let [v, y] = f(s), { ref: b, height: x } = U(), S = x || (typeof i == "number" ? i : 0), C = V(Math.floor(v / r) - a, 0, Math.max(0, e.length - 1)), w = Math.ceil(S / r) + a * 2, T = V(C + w, 0, e.length), E = u(() => e.slice(C, T), [
		T,
		e,
		C
	]), O = (t) => {
		let n = V(t, 0, Math.max(0, e.length * r - S));
		b.current && (b.current.scrollTop = n), y(n);
		let i = V(Math.floor(n / r) - a, 0, Math.max(0, e.length - 1));
		c?.({
			start: i,
			end: V(i + w, 0, e.length)
		});
	}, k = (t) => {
		let n = t.currentTarget.scrollTop, i = V(Math.floor(n / r) - a, 0, Math.max(0, e.length - 1)), o = V(i + w, 0, e.length);
		y(n), c?.({
			start: i,
			end: o
		}), p?.(t);
	};
	return /* @__PURE__ */ m("div", {
		ref: b,
		role: "list",
		"aria-label": o,
		tabIndex: g ?? 0,
		className: D("sx-virtual-list", l),
		style: {
			height: i,
			...d
		},
		onScroll: k,
		onKeyDown: (e) => {
			h?.(e), !e.defaultPrevented && (e.key === "PageDown" || e.key === "PageUp" ? (e.preventDefault(), O(v + (e.key === "PageDown" ? S : -S))) : (e.key === "Home" || e.key === "End") && (e.preventDefault(), O(e.key === "Home" ? 0 : Infinity)));
		},
		..._,
		children: /* @__PURE__ */ m("div", {
			className: "sx-virtual-list__track",
			style: R({ "--sx-virtual-total": `${e.length * r}px` }),
			children: E.map((e, i) => {
				let a = C + i, o = {
					position: "absolute",
					insetInline: 0,
					height: r,
					transform: `translateY(${a * r}px)`
				};
				return /* @__PURE__ */ m("div", {
					role: "listitem",
					className: "sx-virtual-list__item",
					style: o,
					children: n(e, {
						index: a,
						style: o
					})
				}, t(e, a));
			})
		})
	});
}
function bt({ items: e, itemKey: t, renderItem: n, minimumColumnWidth: r, rowHeight: i, height: a, columnGap: o = 12, rowGap: s = 12, overscanRows: c = 2, ariaLabel: l, onItemActivate: u, className: d, style: p, onScroll: h, onKeyDown: g, ..._ }) {
	let [v, y] = f(0), [b, x] = f(0), { ref: S, width: C, height: w } = U(), T = Math.max(1, Math.floor((C + o) / (r + o))), E = C > 0 ? (C - o * (T - 1)) / T : r, O = i + s, k = Math.ceil(e.length / T), A = Math.max(0, k * O - s), j = w || (typeof a == "number" ? a : 0), M = V(Math.floor(v / O) - c, 0, Math.max(0, k - 1)), N = V(M + Math.ceil(j / O) + c * 2, 0, k), P = (t) => {
		if (e.length === 0) return;
		let n = V(t, 0, e.length - 1);
		x(n);
		let r = Math.floor(n / T) * O, a = v;
		if (r < v ? a = r : r + i > v + j && (a = r + i - j), a !== v) {
			let e = V(a, 0, Math.max(0, k * O - s - j));
			S.current && (S.current.scrollTop = e), y(e);
		}
		queueMicrotask(() => S.current?.querySelector(`[data-sx-virtual-index="${n}"]`)?.focus());
	};
	return /* @__PURE__ */ m("div", {
		ref: S,
		role: "grid",
		"aria-label": l,
		"aria-rowcount": k,
		"aria-colcount": T,
		className: D("sx-virtual-grid", d),
		style: {
			height: a,
			...p
		},
		onScroll: (e) => {
			y(e.currentTarget.scrollTop), h?.(e);
		},
		onKeyDown: (e) => {
			g?.(e);
		},
		..._,
		children: /* @__PURE__ */ m("div", {
			role: "rowgroup",
			className: "sx-virtual-grid__track",
			style: R({ "--sx-virtual-total": `${A}px` }),
			children: Array.from({ length: Math.max(0, N - M) }, (r, a) => {
				let s = M + a, c = s * T, l = Math.min(e.length, c + T);
				if (c >= l) return null;
				let d = {
					position: "absolute",
					insetInline: 0,
					height: i,
					transform: `translateY(${s * O}px)`
				};
				return /* @__PURE__ */ m("div", {
					role: "row",
					"aria-rowindex": s + 1,
					className: "sx-virtual-grid__row",
					style: d,
					children: e.slice(c, l).map((r, a) => {
						let l = c + a, d = {
							position: "absolute",
							width: E,
							height: i,
							transform: `translateX(${a * (E + o)}px)`
						}, f = {
							...d,
							transform: `translate(${a * (E + o)}px, ${s * O}px)`
						};
						return /* @__PURE__ */ m("div", {
							role: "gridcell",
							"aria-colindex": a + 1,
							tabIndex: l === b ? 0 : -1,
							"data-sx-roving-item": !0,
							"data-sx-virtual-index": l,
							className: "sx-virtual-grid__item",
							style: d,
							onFocus: () => x(l),
							onClick: () => u?.(r, l),
							onKeyDown: (t) => {
								if (t.key === "ArrowDown") t.preventDefault(), P(l + T);
								else if (t.key === "ArrowUp") t.preventDefault(), P(l - T);
								else if (t.key === "ArrowRight") t.preventDefault(), P(l + 1);
								else if (t.key === "ArrowLeft") t.preventDefault(), P(l - 1);
								else if (t.key === "PageDown" || t.key === "PageUp") {
									t.preventDefault();
									let e = Math.max(1, Math.floor(j / O));
									P(l + (t.key === "PageDown" ? e * T : -e * T));
								} else t.key === "Home" || t.key === "End" ? (t.preventDefault(), P(t.key === "Home" ? 0 : e.length - 1)) : (t.key === "Enter" || t.key === " ") && u && (t.preventDefault(), u(r, l));
							},
							children: n(r, {
								index: l,
								row: s,
								column: a,
								style: f
							})
						}, t(r, l));
					})
				}, `row-${s}`);
			})
		})
	});
}
//#endregion
//#region src/advanced/command.tsx
function xt({ commands: e, open: t, defaultOpen: n = !1, onOpenChange: r, title: i = "Command palette", placeholder: a = "Type a command", empty: o = "No commands found", query: s, defaultQuery: c = "", onQueryChange: l, onCommandError: p, className: g, ..._ }) {
	let [v, y] = A({
		value: t,
		defaultValue: n,
		onChange: r
	}), [b, x] = A({
		value: s,
		defaultValue: c,
		onChange: l
	}), [S, C] = f(0), w = d([]), T = u(() => {
		let t = b.trim().toLocaleLowerCase();
		return t ? e.filter((e) => [
			H(e.label),
			H(e.description),
			e.group?.toLocaleLowerCase() ?? "",
			...(e.keywords ?? []).map((e) => e.toLocaleLowerCase())
		].some((e) => e.includes(t))) : e;
	}, [e, b]), E = (e) => {
		e.disabled || Promise.resolve().then(e.onSelect).then(() => y(!1)).catch((t) => p?.(e, t));
	}, O = (e) => {
		let t = L(e, {
			current: S,
			length: T.length,
			orientation: "vertical",
			isDisabled: (e) => T[e]?.disabled === !0
		});
		if (t !== null) C(t), w.current[t]?.scrollIntoView({ block: "nearest" });
		else if (e.key === "Enter") {
			let t = T[S];
			t && (e.preventDefault(), E(t));
		}
	}, k;
	return /* @__PURE__ */ h(Y, {
		open: v,
		onOpenChange: y,
		title: i,
		size: "lg",
		className: D("sx-command-palette", g),
		..._,
		children: [/* @__PURE__ */ m(J, {
			autoFocus: !0,
			value: b,
			placeholder: a,
			"aria-label": a,
			onChange: (e) => {
				x(e.currentTarget.value), C(0);
			},
			onClear: () => x(""),
			onKeyDown: O
		}), /* @__PURE__ */ m("div", {
			className: "sx-command-palette__results",
			role: "listbox",
			"aria-label": "Commands",
			onKeyDown: O,
			children: T.length === 0 ? /* @__PURE__ */ m("div", {
				className: "sx-command-palette__empty",
				children: o
			}) : T.map((e, t) => {
				let n = e.group && e.group !== k;
				return k = e.group, /* @__PURE__ */ h("div", {
					className: "sx-command-palette__entry",
					children: [n ? /* @__PURE__ */ m("div", {
						className: "sx-command-palette__group",
						children: e.group
					}) : null, /* @__PURE__ */ h("button", {
						ref: (e) => {
							w.current[t] = e;
						},
						type: "button",
						role: "option",
						tabIndex: -1,
						className: "sx-command-palette__command",
						"aria-selected": S === t,
						disabled: e.disabled,
						onPointerMove: () => C(t),
						onClick: () => E(e),
						children: [
							e.icon ? /* @__PURE__ */ m("span", {
								className: "sx-command-palette__icon",
								"aria-hidden": "true",
								children: e.icon
							}) : null,
							/* @__PURE__ */ h("span", {
								className: "sx-command-palette__copy",
								children: [/* @__PURE__ */ m("span", {
									className: "sx-command-palette__label",
									children: e.label
								}), e.description ? /* @__PURE__ */ m("span", {
									className: "sx-command-palette__description",
									children: e.description
								}) : null]
							}),
							e.shortcut ? /* @__PURE__ */ m("span", {
								className: "sx-command-palette__shortcut",
								children: e.shortcut.map((e) => /* @__PURE__ */ m(X, { children: e }, e))
							}) : null
						]
					})]
				}, e.id);
			})
		})]
	});
}
function St({ items: e, onSelect: t, label: n = "Search list", placeholder: r = "Search", empty: i = "No results", renderItem: a, className: o, ...s }) {
	let c = k(void 0, "sx-search-list"), [l, u] = f(""), [d, g] = f(0), _ = e.filter((e) => [
		H(e.label),
		H(e.description),
		...e.keywords ?? []
	].join(" ").toLocaleLowerCase().includes(l.toLocaleLowerCase())), v = (e) => {
		e && !e.disabled && t(e);
	};
	return /* @__PURE__ */ h("div", {
		className: D("sx-search-list", o),
		...s,
		children: [/* @__PURE__ */ m(J, {
			value: l,
			role: "combobox",
			"aria-label": n,
			"aria-controls": `${c}-results`,
			"aria-expanded": "true",
			"aria-activedescendant": _[d] ? `${c}-option-${d}` : void 0,
			placeholder: r,
			onChange: (e) => {
				u(e.currentTarget.value), g(0);
			},
			onClear: () => u(""),
			onKeyDown: (e) => {
				let t = L(e, {
					current: d,
					length: _.length,
					orientation: "vertical",
					isDisabled: (e) => _[e]?.disabled === !0
				});
				t === null ? e.key === "Enter" && v(_[d]) : g(t);
			}
		}), /* @__PURE__ */ m("div", {
			id: `${c}-results`,
			role: "listbox",
			"aria-label": n,
			className: "sx-search-list__results",
			children: _.length === 0 ? /* @__PURE__ */ m("div", {
				className: "sx-search-list__empty",
				children: i
			}) : _.map((e, t) => /* @__PURE__ */ m("button", {
				id: `${c}-option-${t}`,
				type: "button",
				role: "option",
				"aria-selected": d === t,
				className: "sx-search-list__item",
				disabled: e.disabled,
				tabIndex: -1,
				onPointerMove: () => g(t),
				onClick: () => v(e),
				children: a ? a(e, d === t) : /* @__PURE__ */ h(p, { children: [/* @__PURE__ */ m("span", {
					className: "sx-search-list__label",
					children: e.label
				}), e.description ? /* @__PURE__ */ m("span", {
					className: "sx-search-list__description",
					children: e.description
				}) : null] })
			}, e.id))
		})]
	});
}
//#endregion
//#region src/advanced/tree.tsx
function Ct(e, t, n = 1, r) {
	let i = [];
	for (let a of e) i.push({
		node: a,
		depth: n,
		...r ? { parentId: r } : {}
	}), a.children?.length && t.has(a.id) && i.push(...Ct(a.children, t, n + 1, a.id));
	return i;
}
function wt({ nodes: e, selectedId: t, defaultSelectedId: n = "", onSelectedIdChange: r, expandedIds: i, defaultExpandedIds: a = /* @__PURE__ */ new Set(), onExpandedIdsChange: o, label: s, className: c, ...l }) {
	let [p, g] = A({
		value: t,
		defaultValue: n,
		onChange: r
	}), [_, v] = A({
		value: i,
		defaultValue: a,
		onChange: o
	}), y = u(() => Ct(e, _), [_, e]), [b, x] = f(0), S = d([]), C = (e) => v((t) => {
		let n = new Set(t);
		return n.has(e) ? n.delete(e) : n.add(e), n;
	}), w = (e, t = e >= b ? 1 : -1) => {
		if (y.length === 0) return;
		let n = Math.min(y.length - 1, Math.max(0, e));
		for (; y[n]?.node.disabled && n + t >= 0 && n + t < y.length;) n += t;
		if (y[n]?.node.disabled) {
			let e = y.findIndex((e) => !e.node.disabled);
			if (e < 0) return;
			n = e;
		}
		x(n), S.current[n]?.focus();
	};
	return /* @__PURE__ */ m("div", {
		role: "tree",
		"aria-label": s,
		className: D("sx-tree", c),
		...l,
		children: y.map(({ node: e, depth: t, parentId: n }, r) => {
			let i = !!e.children?.length, a = i && _.has(e.id);
			return /* @__PURE__ */ m("div", {
				role: "treeitem",
				"aria-level": t,
				"aria-selected": p === e.id,
				"aria-expanded": i ? a : void 0,
				"aria-disabled": e.disabled || void 0,
				className: "sx-tree__item",
				"data-sx-depth": t,
				style: R({ "--sx-tree-indent": `${(t - 1) * 16}px` }),
				children: /* @__PURE__ */ h("button", {
					ref: (e) => {
						S.current[r] = e;
					},
					type: "button",
					className: "sx-tree__row",
					disabled: e.disabled,
					tabIndex: b === r ? 0 : -1,
					onFocus: () => x(r),
					onClick: () => {
						g(e.id), i && C(e.id);
					},
					onKeyDown: (t) => {
						if (t.key === "ArrowDown") t.preventDefault(), w(r + 1);
						else if (t.key === "ArrowUp") t.preventDefault(), w(r - 1);
						else if (t.key === "ArrowRight") t.preventDefault(), i && !a ? C(e.id) : a && w(r + 1);
						else if (t.key === "ArrowLeft") {
							if (t.preventDefault(), a) C(e.id);
							else if (n) {
								let e = y.findIndex((e) => e.node.id === n);
								e >= 0 && w(e);
							}
						} else t.key === "Home" ? (t.preventDefault(), w(0)) : t.key === "End" && (t.preventDefault(), w(y.length - 1));
					},
					children: [
						/* @__PURE__ */ m("span", {
							className: "sx-tree__indent",
							"aria-hidden": "true"
						}),
						/* @__PURE__ */ m("span", {
							className: "sx-tree__disclosure",
							"aria-hidden": "true",
							children: i ? /* @__PURE__ */ m("span", { className: "sx-icon sx-icon--chevron" }) : null
						}),
						e.icon ? /* @__PURE__ */ m("span", {
							className: "sx-tree__icon",
							"aria-hidden": "true",
							children: e.icon
						}) : null,
						/* @__PURE__ */ m("span", {
							className: "sx-tree__label",
							children: e.label
						})
					]
				})
			}, e.id);
		})
	});
}
//#endregion
//#region src/advanced/data-grid.tsx
var Tt = r(function({ columns: e, label: t, rowCount: n, columnTemplate: r, className: i, children: a, ...o }, s) {
	return /* @__PURE__ */ m("div", {
		ref: s,
		role: "grid",
		"aria-label": t,
		"aria-rowcount": n,
		"aria-colcount": e,
		className: D("sx-data-grid", i),
		style: R({ "--sx-data-grid-columns": r ?? `repeat(${e}, minmax(0, 1fr))` }),
		...o,
		children: a
	});
}), Et = r(function({ className: e, ...t }, n) {
	return /* @__PURE__ */ m("div", {
		ref: n,
		role: "rowgroup",
		className: D("sx-data-grid__header", e),
		...t
	});
}), Dt = r(function({ className: e, ...t }, n) {
	return /* @__PURE__ */ m("div", {
		ref: n,
		role: "rowgroup",
		className: D("sx-data-grid__body", e),
		...t
	});
}), $ = r(function({ rowIndex: e, selected: t = !1, className: n, ...r }, i) {
	return /* @__PURE__ */ m("div", {
		ref: i,
		role: "row",
		"aria-rowindex": e === void 0 ? void 0 : e + 1,
		"aria-selected": t || void 0,
		className: D("sx-data-grid__row", n),
		"data-sx-selected": t || void 0,
		...r
	});
}), Ot = r(function({ columnIndex: e, header: t = !1, align: n = "start", active: r = !1, className: i, children: a, ...o }, s) {
	let c = typeof a == "string" || typeof a == "number" ? /* @__PURE__ */ m("span", {
		className: "sx-data-grid__content",
		children: a
	}) : a;
	return /* @__PURE__ */ m("div", {
		ref: s,
		role: t ? "columnheader" : "gridcell",
		"aria-colindex": e === void 0 ? void 0 : e + 1,
		className: D("sx-data-grid__cell", i),
		"data-sx-align": n,
		"data-sx-active": r || void 0,
		...o,
		children: c
	});
});
function kt({ columns: e, rows: t, rowKey: n, label: r, selectedKeys: i, onRowActivate: a, sort: o, onSortChange: s, empty: c = "No records", className: l, ...u }) {
	let [p, g] = f({
		row: 0,
		column: 0
	}), _ = d([]), v = d(null), y = (n, r) => {
		let i = {
			row: Math.max(0, Math.min(t.length - 1, n)),
			column: Math.max(0, Math.min(e.length - 1, r))
		};
		g(i), _.current[i.row]?.[i.column]?.focus();
	}, b = (n, r, i) => {
		if (n.key === "ArrowDown") n.preventDefault(), y(r + 1, i);
		else if (n.key === "ArrowUp") n.preventDefault(), y(r - 1, i);
		else if (n.key === "ArrowRight") n.preventDefault(), y(r, i + 1);
		else if (n.key === "ArrowLeft") n.preventDefault(), y(r, i - 1);
		else if (n.key === "Home") n.preventDefault(), y(r, 0);
		else if (n.key === "End") n.preventDefault(), y(r, e.length - 1);
		else if (n.key === "PageDown" || n.key === "PageUp") {
			n.preventDefault();
			let e = _.current[0]?.[0]?.parentElement?.getBoundingClientRect().height || 40, t = Math.max(1, Math.floor((v.current?.getBoundingClientRect().height || e) / e));
			y(r + (n.key === "PageDown" ? t : -t), i);
		} else (n.key === "Enter" || n.key === " ") && t[r] && (n.preventDefault(), a?.(t[r], r));
	}, x = e.map((e) => e.width ?? "minmax(0, 1fr)").join(" ");
	return /* @__PURE__ */ h(Tt, {
		ref: v,
		columns: e.length,
		rowCount: Math.max(1, t.length) + 1,
		label: r,
		columnTemplate: x,
		className: l,
		...u,
		children: [/* @__PURE__ */ m(Et, { children: /* @__PURE__ */ m($, {
			rowIndex: 0,
			children: e.map((e, t) => /* @__PURE__ */ m(Ot, {
				header: !0,
				columnIndex: t,
				align: e.align,
				"aria-sort": o?.columnId === e.id ? o.direction : void 0,
				children: e.sortable && s ? /* @__PURE__ */ h("button", {
					type: "button",
					className: "sx-data-grid__sort",
					onClick: () => s({
						columnId: e.id,
						direction: o?.columnId === e.id && o.direction === "ascending" ? "descending" : "ascending"
					}),
					children: [e.header, /* @__PURE__ */ m("span", {
						className: "sx-data-grid__sort-icon",
						"aria-hidden": "true"
					})]
				}) : e.header
			}, e.id))
		}) }), /* @__PURE__ */ m(Dt, { children: t.length === 0 ? /* @__PURE__ */ m($, {
			rowIndex: 1,
			children: /* @__PURE__ */ m(Ot, {
				columnIndex: 0,
				"aria-colspan": Math.max(1, e.length),
				tabIndex: 0,
				className: "sx-data-grid__empty",
				children: c
			})
		}) : t.map((t, r) => {
			let o = n(t, r);
			return /* @__PURE__ */ m($, {
				rowIndex: r + 1,
				selected: i?.has(o),
				children: e.map((e, n) => /* @__PURE__ */ m(Ot, {
					ref: (e) => {
						let t = _.current[r] ?? [];
						t[n] = e, _.current[r] = t;
					},
					columnIndex: n,
					align: e.align,
					active: p.row === r && p.column === n,
					tabIndex: p.row === r && p.column === n ? 0 : -1,
					onFocus: () => g({
						row: r,
						column: n
					}),
					onKeyDown: (e) => b(e, r, n),
					onDoubleClick: () => a?.(t, r),
					children: e.cell(t, r)
				}, e.id))
			}, o);
		}) })]
	});
}
//#endregion
//#region src/advanced/drag.tsx
var At = "application/x-synex-ui-drag";
function jt(e) {
	if (!e || typeof e != "object") return !1;
	let t = e;
	return typeof t.type == "string" && t.type.length > 0 && t.type.length <= 64 && typeof t.id == "string" && t.id.length > 0 && t.id.length <= 256;
}
function Mt(e, t = {}) {
	let n = t.disabled ?? !1, [r, i] = f(!1), a = (e) => {
		i(e), t.onDragStateChange?.(e);
	};
	return {
		draggable: !n,
		"data-sx-dragging": r || void 0,
		onDragStart(r) {
			if (n) {
				r.preventDefault();
				return;
			}
			r.dataTransfer.effectAllowed = t.effectAllowed ?? "move", r.dataTransfer.setData(At, JSON.stringify(e)), a(!0);
		},
		onDragEnd() {
			a(!1);
		}
	};
}
function Nt(e) {
	let [t, n] = f(!1), r = (t) => {
		n(t), e.onHoverChange?.(t);
	}, i = (t) => {
		try {
			let n = JSON.parse(t.dataTransfer.getData(At));
			return jt(n) && e.accepts.includes(n.type) ? n : null;
		} catch {
			return null;
		}
	};
	return {
		"data-sx-drop-active": t || void 0,
		onDragOver(n) {
			e.disabled || n.dataTransfer.types.includes(At) && (n.preventDefault(), n.dataTransfer.dropEffect = e.dropEffect ?? "move", t || r(!0));
		},
		onDragLeave(e) {
			e.currentTarget.contains(e.relatedTarget) || r(!1);
		},
		onDrop(t) {
			t.preventDefault(), r(!1);
			let n = i(t);
			n && e.onDrop(n);
		}
	};
}
var Pt = r(function({ label: e = "Drag to reorder", className: t, ...n }, r) {
	return /* @__PURE__ */ m("button", {
		ref: r,
		type: "button",
		className: D("sx-drag-handle", t),
		"aria-label": e,
		...n,
		children: /* @__PURE__ */ m("span", {
			className: "sx-drag-handle__grip",
			"aria-hidden": "true"
		})
	});
}), Ft = r(function({ className: e, ...t }, n) {
	return /* @__PURE__ */ m("div", {
		ref: n,
		className: D("sx-drag-preview", e),
		"aria-hidden": "true",
		...t
	});
});
function It({ item: e, index: t, findIndex: n, move: r }) {
	let i = Mt({
		type: "reorder-item",
		id: e.id
	}, { disabled: e.disabled }), a = Nt({
		accepts: ["reorder-item"],
		onDrop: (e) => r(n(e.id), t)
	});
	return /* @__PURE__ */ h("li", {
		className: "sx-reorder-list__item",
		...i,
		...a,
		children: [/* @__PURE__ */ m(Pt, {
			disabled: e.disabled,
			onKeyDown: (e) => {
				e.altKey && e.key === "ArrowUp" ? (e.preventDefault(), r(t, t - 1)) : e.altKey && e.key === "ArrowDown" && (e.preventDefault(), r(t, t + 1));
			}
		}), /* @__PURE__ */ m("div", {
			className: "sx-reorder-list__content",
			children: e.content
		})]
	});
}
function Lt({ items: e, onReorder: t, label: n, announcement: r = (e, t, n) => `${e.id} moved to position ${n + 1}`, className: i, ...a }) {
	let [o, s] = f(""), c = (n, i) => {
		if (n === i || i < 0 || i >= e.length || e[n]?.disabled) return;
		let a = [...e], [o] = a.splice(n, 1);
		o && (a.splice(i, 0, o), t(a), s(r(o, n, i)));
	};
	return /* @__PURE__ */ h(p, { children: [/* @__PURE__ */ m("ul", {
		className: D("sx-reorder-list", i),
		"aria-label": n,
		...a,
		children: e.map((t, n) => /* @__PURE__ */ m(It, {
			item: t,
			index: n,
			findIndex: (t) => e.findIndex((e) => e.id === t),
			move: c
		}, t.id))
	}), /* @__PURE__ */ m("div", {
		className: "sx-visually-hidden",
		"aria-live": "polite",
		children: o
	})] });
}
//#endregion
//#region src/advanced/chart.ts
var Rt = {
	categorical: [
		"var(--sx-chart-categorical-1)",
		"var(--sx-chart-categorical-2)",
		"var(--sx-chart-categorical-3)",
		"var(--sx-chart-categorical-4)",
		"var(--sx-chart-categorical-5)",
		"var(--sx-chart-categorical-6)"
	],
	positive: "var(--sx-chart-positive)",
	negative: "var(--sx-chart-negative)",
	warning: "var(--sx-chart-warning)",
	grid: "var(--sx-chart-grid)",
	axis: "var(--sx-chart-axis)",
	label: "var(--sx-chart-label)",
	tooltipBackground: "var(--sx-chart-tooltip-bg)",
	tooltipBorder: "var(--sx-chart-tooltip-border)"
};
function zt(e) {
	let t = Rt.categorical, n = (e % t.length + t.length) % t.length;
	return {
		color: t[n] ?? t[0],
		mutedColor: `var(--sx-chart-categorical-${n + 1}-muted)`,
		lineWidth: 2,
		pointRadius: 3
	};
}
//#endregion
export { tt as ActionMenu, _e as ActionRow, Ve as AlertDialog, he as AspectBox, _t as Avatar, ft as Badge, Ie as Breadcrumb, W as Button, Te as Checkbox, je as Combobox, xt as CommandPalette, de as Container, et as ContextMenu, kt as DataGrid, Dt as DataGridBody, Ot as DataGridCell, Et as DataGridHeader, Tt as DataGridRoot, $ as DataGridRow, ut as DataList, Y as Dialog, fe as Divider, Pt as DragHandle, Ft as DragPreview, Ue as Drawer, $e as Dropdown, st as EmptyState, ye as Field, be as FieldGroup, ue as Grid, Ye as Icon, G as IconButton, le as Inline, q as Input, X as KeyHint, dt as KeyValueList, vt as ListItem, ot as LoadingOverlay, Q as Menu, gt as Metric, Ge as Modal, Ne as MultiSelect, Ce as NumberInput, Le as Pagination, we as PasswordInput, He as Popover, it as ProgressBar, at as ProgressRing, Ee as Radio, Lt as ReorderList, pe as ScrollArea, J as SearchInput, St as SearchList, Me as SearchSelect, Pe as SegmentedControl, Ae as Select, We as Sheet, qe as Shortcut, Be as SideNav, rt as Skeleton, Oe as Slider, me as Spacer, nt as Spinner, ge as SplitButton, ce as Stack, ht as Stat, mt as StatusBadge, Re as Stepper, Qe as Submenu, se as Surface, De as Switch, Xe as SynexIcon, lt as Table, Fe as Tabs, Se as TextArea, ct as Toast, Ke as Tooltip, wt as Tree, te as Typography, xe as ValidationMessage, bt as VirtualGrid, yt as VirtualList, Ze as VisuallyHidden, zt as chartSeriesStyle, Rt as chartTokens, x as formatCurrency, C as formatDate, b as formatNumber, S as formatPercent, w as formatTime, ne as motionDurationMilliseconds, re as motionDurations, ae as motionIntentSpeeds, ie as motionTokens, oe as motionTransition, Mt as useDragSource, Nt as useDropTarget, K as useFieldControlProps };
