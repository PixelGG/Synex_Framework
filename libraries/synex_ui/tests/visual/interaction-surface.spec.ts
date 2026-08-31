import { expect, test, type Page, type TestInfo } from '@playwright/test';
import type {
  GameEnvelope,
  RuntimeInteraction,
  ScreenMetrics,
  UiPreferences,
} from '../../runtime/src/protocol';

const runtimeUrl = 'http://127.0.0.1:4179';
const interactionOwner = 'synex_interact';
const interactionOwnerEpoch = 12;
const responsiveProjects = new Set([
  '1080p',
  '1440p',
  '4k',
  '21x9-2560',
  '21x9',
  '32x9',
]);

const defaultPreferences: UiPreferences = {
  schemaVersion: 1,
  quality: 'BALANCED',
  scale: 100,
  density: 'comfortable',
  reducedMotion: true,
  reducedTransparency: false,
  highContrast: false,
  interactionAssist: false,
};

const cueInput = {
  primary: { keyboard: 'E', gamepad: 'A', mouse: 'LMB' },
  more: { keyboard: 'TAB', gamepad: 'Y' },
};

const bloomInput = {
  primary: { keyboard: 'ENTER', gamepad: 'A', mouse: 'LMB' },
  cancel: { keyboard: 'ESC', gamepad: 'B', mouse: 'RMB' },
};

const progressInput = {
  cancel: { keyboard: 'ESC', gamepad: 'B', mouse: 'RMB' },
};

function screenFor(page: Page): ScreenMetrics {
  const viewport = page.viewportSize();
  if (!viewport) throw new Error('interaction visual test requires a configured viewport');
  return {
    width: viewport.width,
    height: viewport.height,
    aspectRatio: viewport.width / viewport.height,
    safeLeft: 24,
    safeRight: 24,
    safeTop: 16,
    safeBottom: 16,
  };
}

function cue(overrides: Partial<RuntimeInteraction> = {}): RuntimeInteraction {
  return {
    interactionId: 'visual.intent.cue',
    revision: 1,
    mode: 'cue',
    label: 'Primary interaction',
    targetLabel: 'Managed object',
    projection: { visible: true, behindCamera: false, x: 0.18, y: 0.64 },
    intents: [{ intentId: 'inspect', label: 'Inspect', description: 'Read the current interaction context.' }],
    selectedIntentId: 'inspect',
    moreCount: 2,
    pointer: false,
    input: cueInput,
    cancellable: false,
    ownerResource: interactionOwner,
    ownerEpoch: interactionOwnerEpoch,
    ...overrides,
  };
}

function bloom(overrides: Partial<RuntimeInteraction> = {}): RuntimeInteraction {
  return {
    interactionId: 'visual.action.bloom',
    revision: 1,
    mode: 'bloom',
    label: 'Available intents',
    targetLabel: 'Semantic anchor',
    projection: { visible: true, behindCamera: false, x: 0.5, y: 0.72 },
    intents: [
      { intentId: 'primary', label: 'Use', description: 'Begin the selected interaction.' },
      { intentId: 'secondary', label: 'Inspect', description: 'Review contextual details.' },
      {
        intentId: 'reserved',
        label: 'Reserved',
        description: 'Unavailable while another actor holds the slot.',
        disabled: true,
      },
    ],
    selectedIntentId: 'primary',
    pointer: false,
    input: bloomInput,
    cancellable: true,
    ownerResource: interactionOwner,
    ownerEpoch: interactionOwnerEpoch,
    ...overrides,
  };
}

function progress(overrides: Partial<RuntimeInteraction> = {}): RuntimeInteraction {
  return {
    interactionId: 'visual.hold.progress',
    revision: 1,
    mode: 'progress',
    label: 'Hold to complete',
    targetLabel: 'Authority confirmed',
    projection: { visible: true, behindCamera: false, x: 0.82, y: 0.64 },
    intents: [],
    pointer: false,
    input: progressInput,
    progress: { mode: 'timed', elapsedMs: 2_500, durationMs: 5_000 },
    cancellable: true,
    ownerResource: interactionOwner,
    ownerEpoch: interactionOwnerEpoch,
    ...overrides,
  };
}

function runtimeSync(
  interaction: RuntimeInteraction,
  screen: ScreenMetrics,
  preferences: UiPreferences = defaultPreferences,
): GameEnvelope {
  return {
    protocolVersion: 1,
    messageId: `visual_sync_${interaction.interactionId}`,
    type: 'runtime:sync',
    ownerResource: 'synex_ui',
    ownerEpoch: 1,
    revision: 1,
    payload: {
      surfaces: [],
      signals: [],
      signalGeneration: 1,
      interaction,
      interactionGeneration: 1,
      preferences,
      screen,
      inputDevice: 'keyboard',
      health: 'READY',
    },
  };
}

function interactionUpsert(interaction: RuntimeInteraction, generation: number): GameEnvelope {
  const { ownerResource, ownerEpoch, ...descriptor } = interaction;
  return {
    protocolVersion: 1,
    messageId: `visual_upsert_${interaction.interactionId}_${interaction.revision}`,
    type: 'interaction:upsert',
    ownerResource,
    ownerEpoch,
    revision: interaction.revision,
    payload: { ...descriptor, generation },
  };
}

function interactionRemove(interaction: RuntimeInteraction, generation: number): GameEnvelope {
  return {
    protocolVersion: 1,
    messageId: `visual_remove_${interaction.interactionId}_${generation}`,
    type: 'interaction:remove',
    ownerResource: interaction.ownerResource,
    ownerEpoch: interaction.ownerEpoch,
    revision: interaction.revision + 1,
    payload: { interactionId: interaction.interactionId, generation },
  };
}

async function dispatchGameMessage(page: Page, envelope: GameEnvelope): Promise<void> {
  await page.evaluate((message) => {
    window.dispatchEvent(new MessageEvent('message', {
      data: message,
      origin: window.location.origin,
    }));
  }, envelope);
}

async function openRuntime(page: Page): Promise<void> {
  await page.route('https://synex_ui/**', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ ok: true, data: { ready: true } }),
    });
  });
  await page.goto(runtimeUrl, { waitUntil: 'domcontentloaded' });
  await expect(page.locator('#root')).toHaveAttribute('aria-hidden', 'true');
  await page.evaluate(() => {
    const backdrop = document.createElement('div');
    backdrop.dataset.testid = 'interaction-contrast-backdrop';
    Object.assign(backdrop.style, {
      position: 'fixed',
      inset: '0',
      zIndex: '0',
      pointerEvents: 'none',
      background: 'linear-gradient(90deg, #080d11 0 33.333%, #26333a 33.333% 66.666%, #879094 66.666% 100%)',
    });
    document.body.prepend(backdrop);
  });
}

async function mountInteraction(
  page: Page,
  interaction: RuntimeInteraction,
  preferences: UiPreferences = defaultPreferences,
): Promise<void> {
  const envelope = runtimeSync(interaction, screenFor(page), preferences);
  const surface = page.locator('.sx-interaction');
  await expect.poll(async () => {
    await dispatchGameMessage(page, envelope);
    return surface.count();
  }).toBe(1);
  await expect(surface).toHaveAttribute('data-sx-interaction-id', interaction.interactionId);
}

function skipOutside1080p(testInfo: TestInfo): void {
  test.skip(testInfo.project.name !== '1080p', 'Detailed interaction state goldens run once at 1080p.');
}

test.describe('Synex Interaction Surface visual regression', () => {
  test('captures the passive intent cue at 1080p', async ({ page }, testInfo) => {
    skipOutside1080p(testInfo);
    await openRuntime(page);
    await mountInteraction(page, cue());
    const surface = page.locator('.sx-interaction');
    await expect(surface).toHaveAttribute('data-sx-mode', 'cue');
    await expect(surface).toHaveAttribute('data-sx-assist', 'false');
    await expect(surface).toContainText('Inspect');
    await expect(surface).toContainText('+2');
    await expect(surface).toHaveScreenshot('interaction-intent-cue.png');
  });

  test('captures an authoritative intent change at 1080p', async ({ page }, testInfo) => {
    skipOutside1080p(testInfo);
    await openRuntime(page);
    const initial = cue();
    await mountInteraction(page, initial);
    await expect(page.locator('.sx-interaction')).toContainText('Inspect');

    const changed = cue({
      revision: 2,
      targetLabel: 'Context updated',
      intents: [{ intentId: 'open', label: 'Open', description: 'Use the newly relevant intent.' }],
      selectedIntentId: 'open',
    });
    await dispatchGameMessage(page, interactionUpsert(changed, 2));
    const surface = page.locator('.sx-interaction');
    await expect(surface).toContainText('Open');
    await expect(surface).toContainText('Context updated');
    await expect(surface).not.toContainText('Inspect');
    await expect(surface).toHaveScreenshot('interaction-intent-change.png');
  });

  test('captures the Action Bloom and its disabled secondary state at 1080p', async ({ page }, testInfo) => {
    skipOutside1080p(testInfo);
    await openRuntime(page);
    await mountInteraction(page, bloom());
    const surface = page.locator('.sx-interaction');
    await expect(surface).toHaveAttribute('data-sx-mode', 'bloom');
    await expect(surface.getByRole('listitem')).toHaveCount(3);
    await expect(surface.getByRole('listitem').filter({ hasText: 'Reserved' })).toHaveAttribute('aria-disabled', 'true');
    await expect(surface.getByRole('listitem').filter({ hasText: 'Use' })).toHaveAttribute('aria-current', 'true');
    await expect(surface).toHaveScreenshot('interaction-action-bloom-disabled.png');
  });

  test('captures timed hold progress with its cancel affordance at 1080p', async ({ page }, testInfo) => {
    skipOutside1080p(testInfo);
    await openRuntime(page);
    await mountInteraction(page, progress());
    const surface = page.locator('.sx-interaction');
    await expect(surface).toHaveAttribute('data-sx-mode', 'progress');
    await expect(surface.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '50');
    await expect(surface).toContainText('50%');
    await expect(surface).toContainText('ESC');
    await expect(surface).toContainText('Cancel');
    await expect(surface).toHaveScreenshot('interaction-hold-progress-cancellable.png');
  });

  test('captures the enlarged Interaction Assist cue at 1080p', async ({ page }, testInfo) => {
    skipOutside1080p(testInfo);
    await openRuntime(page);
    await mountInteraction(page, cue({ interactionId: 'visual.intent.assist' }), {
      ...defaultPreferences,
      interactionAssist: true,
    });
    const surface = page.locator('.sx-interaction');
    await expect(surface).toHaveAttribute('data-sx-assist', 'true');
    await expect(surface).toHaveScreenshot('interaction-assist-cue.png');
  });

  test('captures cancellation as a fully closed transparent runtime at 1080p', async ({ page }, testInfo) => {
    skipOutside1080p(testInfo);
    await openRuntime(page);
    const activeProgress = progress({ interactionId: 'visual.cancel.progress' });
    await mountInteraction(page, activeProgress);
    await dispatchGameMessage(page, interactionRemove(activeProgress, 2));
    await expect(page.locator('.sx-interaction')).toHaveCount(0);
    await expect(page.locator('#root')).toHaveAttribute('aria-hidden', 'true');
    await expect(page.locator('body')).toHaveAttribute('data-sx-visible', 'false');
    await expect(page.locator('body')).toHaveAttribute('data-sx-interactive', 'false');
    const closedState = await page.evaluate(() => ({
      htmlBackground: getComputedStyle(document.documentElement).backgroundColor,
      bodyBackground: getComputedStyle(document.body).backgroundColor,
      rootBackground: getComputedStyle(document.getElementById('root')!).backgroundColor,
      rootChildren: document.getElementById('root')!.childElementCount,
      rootPointerEvents: getComputedStyle(document.getElementById('root')!).pointerEvents,
    }));
    expect(closedState).toEqual({
      htmlBackground: 'rgba(0, 0, 0, 0)',
      bodyBackground: 'rgba(0, 0, 0, 0)',
      rootBackground: 'rgba(0, 0, 0, 0)',
      rootChildren: 0,
      rootPointerEvents: 'none',
    });
    await expect(page).toHaveScreenshot('interaction-cancelled-closed.png', { fullPage: false });
  });

  test('keeps an assisted Action Bloom inside every configured viewport', async ({ page }, testInfo) => {
    test.skip(!responsiveProjects.has(testInfo.project.name), 'Interaction wide-screen matrix excludes mobile and 720p.');
    await openRuntime(page);
    const screen = screenFor(page);
    await mountInteraction(page, bloom({
      interactionId: 'visual.action.edge',
      projection: { visible: true, behindCamera: false, x: 0.995, y: 0.995 },
    }), {
      ...defaultPreferences,
      interactionAssist: true,
    });
    const surface = page.locator('.sx-interaction');
    await expect(surface).toHaveAttribute('data-sx-assist', 'true');
    const geometry = await surface.evaluate((element) => {
      const bounds = element.getBoundingClientRect();
      return {
        left: bounds.left,
        right: bounds.right,
        top: bounds.top,
        bottom: bounds.bottom,
        pointerEvents: getComputedStyle(element).pointerEvents,
      };
    });
    expect(geometry.left).toBeGreaterThanOrEqual(screen.safeLeft + 19);
    expect(geometry.right).toBeLessThanOrEqual(screen.width - screen.safeRight - 19);
    expect(geometry.top).toBeGreaterThanOrEqual(screen.safeTop + 19);
    expect(geometry.bottom).toBeLessThanOrEqual(screen.height - screen.safeBottom - 19);
    expect(geometry.pointerEvents).toBe('none');
    await expect(page).toHaveScreenshot('interaction-surface-responsive.png', { fullPage: false });
  });
});
