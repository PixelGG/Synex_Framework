import { useEffect, useMemo, useRef, useState } from "react";
import {
  Select,
  Switch,
} from "@synex/ui";
import markUrl from "../../../../.github/assets/branding/synex-mark.svg?url";
import { SpecimenSection } from "./specimens";

export type LabSection =
  | "overview"
  | "foundation"
  | "actions"
  | "forms"
  | "selection"
  | "navigation"
  | "overlays"
  | "menus"
  | "feedback"
  | "data"
  | "utilities"
  | "advanced"
  | "runtime";

export type QualityProfile = "LOW" | "BALANCED" | "HIGH" | "ULTRA";
export type DensityProfile = "compact" | "comfortable" | "spacious";

export interface LabPreferences {
  quality: QualityProfile;
  density: DensityProfile;
  scale: number;
  reducedMotion: boolean;
  reducedTransparency: boolean;
  highContrast: boolean;
}

const sections: ReadonlyArray<{ id: LabSection; label: string; code: string }> = [
  { id: "overview", label: "System", code: "00" },
  { id: "foundation", label: "Foundation", code: "01" },
  { id: "actions", label: "Actions", code: "02" },
  { id: "forms", label: "Forms", code: "03" },
  { id: "selection", label: "Selection", code: "04" },
  { id: "navigation", label: "Navigation", code: "05" },
  { id: "overlays", label: "Overlays", code: "06" },
  { id: "menus", label: "Menus", code: "07" },
  { id: "feedback", label: "Feedback", code: "08" },
  { id: "data", label: "Data", code: "09" },
  { id: "utilities", label: "Utilities", code: "10" },
  { id: "advanced", label: "Advanced", code: "11" },
  { id: "runtime", label: "Runtime", code: "12" },
];

const isSection = (value: string | null): value is LabSection => sections.some((section) => section.id === value);

function readInitialPreferences(): LabPreferences {
  const params = new URLSearchParams(window.location.search);
  const quality = params.get("quality")?.toUpperCase();
  const density = params.get("density");
  const scale = Number(params.get("scale") ?? 100);
  return {
    quality: quality === "LOW" || quality === "HIGH" || quality === "ULTRA" ? quality : "BALANCED",
    density: density === "compact" || density === "spacious" ? density : "comfortable",
    scale: [85, 100, 115, 125].includes(scale) ? scale : 100,
    reducedMotion: params.get("reducedMotion") === "true",
    reducedTransparency: params.get("reducedTransparency") === "true",
    highContrast: params.get("highContrast") === "true",
  };
}

export function DesignLab() {
  const initialParams = useMemo(() => new URLSearchParams(window.location.search), []);
  const [active, setActive] = useState<LabSection>(() => {
    const requested = initialParams.get("section");
    return isSection(requested) ? requested : "overview";
  });
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [preferences, setPreferences] = useState<LabPreferences>(readInitialPreferences);
  const settingsToggleRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    const root = document.documentElement;
    root.dataset.sxQuality = preferences.quality.toLowerCase();
    root.dataset.sxDensity = preferences.density;
    root.dataset.sxReducedMotion = preferences.reducedMotion ? "true" : "false";
    root.dataset.sxReducedTransparency = preferences.reducedTransparency ? "true" : "false";
    root.dataset.sxHighContrast = preferences.highContrast ? "true" : "false";
    root.style.setProperty("--synex-ui-scale", String(preferences.scale / 100));
  }, [preferences]);

  useEffect(() => {
    if (!settingsOpen) return;
    const dismissSettings = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      setSettingsOpen(false);
      window.requestAnimationFrame(() => settingsToggleRef.current?.focus());
    };
    document.addEventListener("keydown", dismissSettings);
    return () => document.removeEventListener("keydown", dismissSettings);
  }, [settingsOpen]);

  const patchPreferences = (patch: Partial<LabPreferences>) => setPreferences((current) => ({ ...current, ...patch }));
  const selected = sections.find((section) => section.id === active) ?? sections[0]!;

  return (
    <div className="sx-root lab" data-testid="design-lab">
      <header className="lab-header">
        <div className="lab-brand">
          <img src={markUrl} alt="" className="lab-brand__mark" />
          <div className="lab-brand__copy">
            <strong className="lab-brand__name">Synex UI</strong>
            <span className="lab-brand__descriptor">Component proof</span>
          </div>
        </div>
        <div className="lab-header__record" aria-label="Proof record">
          <span>Package 0.1.0</span>
          <span>Browser proof</span>
          <button
            ref={settingsToggleRef}
            type="button"
            className="lab-settings-toggle"
            aria-expanded={settingsOpen}
            aria-controls="lab-view-settings"
            onClick={() => setSettingsOpen((value) => !value)}
          >
            {settingsOpen ? "Close settings" : "View settings"}
          </button>
        </div>
      </header>

      <nav id="lab-component-index" className="lab-index" aria-label="Design Lab sections">
        <div className="lab-index__track">
          {sections.map((section) => (
            <button
              key={section.id}
              type="button"
              className="lab-index__item"
              aria-current={active === section.id ? "page" : undefined}
              onClick={() => {
                setActive(section.id);
                window.scrollTo({ top: 0, behavior: preferences.reducedMotion ? "auto" : "smooth" });
              }}
            >
              <span className="lab-index__code">{section.code}</span>
              <span>{section.label}</span>
            </button>
          ))}
        </div>
        <span className="lab-index__hint" aria-hidden="true">More sections</span>
      </nav>

      <section
        id="lab-view-settings"
        className="lab-controls"
        aria-label="Design Lab view settings"
        data-open={settingsOpen || undefined}
      >
        <div className="lab-controls__identity">
          <strong>{selected.label}</strong>
          <span>Preview conditions</span>
        </div>
        <div className="lab-controls__field">
          <label htmlFor="quality-profile">Material quality</label>
          <Select
            id="quality-profile"
            aria-label="Material quality"
            value={preferences.quality}
            options={[
              { value: "LOW", label: "Low" },
              { value: "BALANCED", label: "Balanced" },
              { value: "HIGH", label: "High" },
              { value: "ULTRA", label: "Ultra" },
            ]}
            onValueChange={(quality) => patchPreferences({ quality })}
          />
        </div>
        <div className="lab-controls__field">
          <label htmlFor="density-profile">Density</label>
          <Select
            id="density-profile"
            aria-label="Density"
            value={preferences.density}
            options={[
              { value: "compact", label: "Compact" },
              { value: "comfortable", label: "Comfortable" },
              { value: "spacious", label: "Spacious" },
            ]}
            onValueChange={(density) => patchPreferences({ density })}
          />
        </div>
        <div className="lab-controls__scale">
          <label htmlFor="ui-scale">Scale</label>
          <Select
            id="ui-scale"
            aria-label="Interface scale"
            value={String(preferences.scale)}
            options={[
              { value: "85", label: "85%" },
              { value: "100", label: "100%" },
              { value: "115", label: "115%" },
              { value: "125", label: "125%" },
            ]}
            onValueChange={(scale) => patchPreferences({ scale: Number(scale) })}
          />
        </div>
        <div className="lab-controls__toggles">
          <Switch aria-label="Reduced motion" label="Reduced motion" checked={preferences.reducedMotion} onCheckedChange={(reducedMotion) => patchPreferences({ reducedMotion })} />
          <Switch aria-label="Opaque materials" label="Opaque materials" checked={preferences.reducedTransparency} onCheckedChange={(reducedTransparency) => patchPreferences({ reducedTransparency })} />
          <Switch aria-label="High contrast" label="High contrast" checked={preferences.highContrast} onCheckedChange={(highContrast) => patchPreferences({ highContrast })} />
        </div>
      </section>

      <main className="lab-stage" id="main-content">
        <SpecimenSection section={active} preferences={preferences} />
      </main>

      <footer className="lab-footer">
        <span>Browser proof complete</span>
        <span>Pointer, keyboard and gamepad contracts included</span>
        <span>FiveM CEF acceptance pending</span>
      </footer>
    </div>
  );
}
