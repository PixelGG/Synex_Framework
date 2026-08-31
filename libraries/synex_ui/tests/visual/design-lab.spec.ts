import { expect, test, type Page } from '@playwright/test';

const sections = [
  'overview',
  'foundation',
  'actions',
  'forms',
  'selection',
  'navigation',
  'overlays',
  'menus',
  'feedback',
  'data',
  'utilities',
  'advanced',
  'runtime',
] as const;

const profileVariants = [
  { name: 'low', query: 'section=foundation&quality=LOW', attribute: 'data-sx-quality', value: 'low' },
  { name: 'high', query: 'section=foundation&quality=HIGH', attribute: 'data-sx-quality', value: 'high' },
  { name: 'ultra', query: 'section=foundation&quality=ULTRA', attribute: 'data-sx-quality', value: 'ultra' },
  { name: 'scale-85', query: 'section=overview&scale=85', property: '--synex-ui-scale', value: '0.85' },
  { name: 'scale-115', query: 'section=overview&scale=115', property: '--synex-ui-scale', value: '1.15' },
  { name: 'scale-125', query: 'section=overview&scale=125', property: '--synex-ui-scale', value: '1.25' },
  { name: 'density-compact', query: 'section=forms&density=compact', attribute: 'data-sx-density', value: 'compact' },
  { name: 'density-spacious', query: 'section=forms&density=spacious', attribute: 'data-sx-density', value: 'spacious' },
  { name: 'reduced-transparency', query: 'section=foundation&reducedTransparency=true', attribute: 'data-sx-reduced-transparency', value: 'true' },
  { name: 'reduced-motion', query: 'section=feedback&reducedMotion=true', attribute: 'data-sx-reduced-motion', value: 'true' },
  { name: 'high-contrast', query: 'section=data&highContrast=true', attribute: 'data-sx-high-contrast', value: 'true' },
] as const;

async function openDesignLab(page: Page, query = ''): Promise<void> {
  await page.goto(query ? `/?${query}` : '/', { waitUntil: 'domcontentloaded' });
  await expect(page.getByTestId('design-lab')).toBeVisible();

  await page.evaluate(async () => {
    await document.fonts.ready;
    const pendingImages = Array.from(document.images, (image) => {
      if (image.complete) return Promise.resolve();
      return image.decode().catch(() => undefined);
    });
    await Promise.all(pendingImages);
  });

  await expect(page.locator('.lab-header')).toContainText('Synex UI');
}

test.describe('Synex Design Lab visual regression', () => {
  test('overview remains composed at the configured viewport', async ({ page }, testInfo) => {
    await openDesignLab(page);

    const horizontalBounds = await page.evaluate(() => ({
      clientWidth: document.documentElement.clientWidth,
      scrollWidth: document.documentElement.scrollWidth,
    }));
    expect(horizontalBounds.scrollWidth).toBeLessThanOrEqual(horizontalBounds.clientWidth + 1);

    if (testInfo.project.name === 'mobile') {
      const settingsButton = page.getByRole('button', { name: 'View settings' });
      await expect(settingsButton).toBeVisible();
      await expect(settingsButton).toHaveAttribute('aria-expanded', 'false');
      await expect(settingsButton).toHaveAttribute('aria-controls', 'lab-view-settings');
      await settingsButton.click();
      await expect(page.locator('.lab-controls')).toHaveAttribute('data-open', 'true');
      const closeButton = page.getByRole('button', { name: 'Close settings' });
      await expect(closeButton).toHaveAttribute('aria-expanded', 'true');
      await page.keyboard.press('Escape');
      await expect(page.locator('.lab-controls')).not.toHaveAttribute('data-open', 'true');
      await expect(settingsButton).toHaveAttribute('aria-expanded', 'false');
      await expect(settingsButton).toBeFocused();
      const sectionHint = page.locator('.lab-index__hint');
      await expect(sectionHint).toBeVisible();
      const hintBounds = await sectionHint.boundingBox();
      expect(hintBounds).not.toBeNull();
      expect(hintBounds!.width).toBeGreaterThanOrEqual(80);
      expect(hintBounds!.x).toBeGreaterThanOrEqual(0);
      expect(hintBounds!.x + hintBounds!.width).toBeLessThanOrEqual(horizontalBounds.clientWidth + 1);
      await expect(page.locator('.lab-footer')).toHaveCSS('position', 'static');
      await openDesignLab(page);
    }

    if (testInfo.project.name === '720p') {
      const settingsButton = page.getByRole('button', { name: 'View settings' });
      await settingsButton.click();
      await expect(page.getByRole('switch', { name: 'Reduced motion' })).toBeVisible();
      await expect(page.getByRole('switch', { name: 'Opaque materials' })).toBeVisible();
      await expect(page.getByRole('switch', { name: 'High contrast' })).toBeVisible();
      await page.getByRole('button', { name: 'Close settings' }).click();
    }

    await expect(page).toHaveScreenshot('overview-viewport.png', {
      fullPage: false,
    });
  });

  test('Signal Surface remains passive and composed at the configured viewport', async ({ page }) => {
    await openDesignLab(page, 'section=feedback');
    const preview = page.getByTestId('signal-rail-preview');
    const surfaces = preview.locator('.sx-signal-surface');
    await expect(preview).toBeVisible();
    await expect(surfaces).toHaveCount(4);
    await expect(preview.locator('.sx-signal-surface[role="group"]')).toHaveCount(4);
    await expect(preview.locator('[role="alert"]')).toHaveCount(1);
    await expect(preview.locator('[role="status"]')).toHaveCount(1);
    await expect(preview.locator('[data-sx-signal-announcer="true"]')).toHaveCount(1);
    await expect(preview.locator('button')).toHaveCount(0);

    const geometry = await preview.evaluate((element) => {
      const rail = element.querySelector<HTMLElement>('.sx-signal-rail');
      const surface = element.querySelector<HTMLElement>('.sx-signal-surface');
      const previewRect = element.getBoundingClientRect();
      const railRect = rail?.getBoundingClientRect();
      return {
        previewLeft: previewRect.left,
        previewRight: previewRect.right,
        railLeft: railRect?.left ?? -1,
        railRight: railRect?.right ?? Number.POSITIVE_INFINITY,
        pointerEvents: surface ? getComputedStyle(surface).pointerEvents : '',
      };
    });
    expect(geometry.pointerEvents).toBe('none');
    expect(geometry.railLeft).toBeGreaterThanOrEqual(geometry.previewLeft - 1);
    expect(geometry.railRight).toBeLessThanOrEqual(geometry.previewRight + 1);

    await expect(preview).toHaveScreenshot('signal-surface-configured.png');
  });

  test('notification simulator exposes every planned development scenario', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== '1080p', 'Interactive simulator coverage runs once at 1080p.');

    await openDesignLab(page, 'section=feedback&reducedMotion=true');
    const simulator = page.locator('.lab-signal-simulator');
    const preview = page.getByTestId('signal-rail-preview');
    const readout = page.getByTestId('signal-simulator-state');
    const readoutValues = readout.locator('dd');
    const surfaces = preview.locator('.sx-signal-surface');
    await expect(surfaces).toHaveCount(4);

    await simulator.getByRole('button', { name: 'Spawn toast' }).click();
    await expect(readout).toContainText('Spawn toast');
    await expect(surfaces).toHaveCount(1);
    await expect(preview).toContainText('Vehicle access updated');

    await simulator.getByRole('button', { name: 'Spawn progress' }).click();
    await expect(readout).toContainText('Spawn progress');
    await expect(preview.locator('[data-sx-state="RUNNING"]')).toHaveCount(1);
    await expect(preview).toContainText('15%');

    await simulator.getByRole('button', { name: 'Advance progress' }).click();
    await expect(readout).toContainText('Advance progress');
    await expect(preview).toContainText('35%');

    await simulator.getByRole('button', { name: 'Fail progress' }).click();
    await expect(readout).toContainText('Fail progress');
    await expect(preview.locator('[data-sx-state="FAILED"]')).toHaveCount(1);

    await simulator.getByRole('button', { name: 'Group burst' }).click();
    await expect(readoutValues.nth(0)).toHaveText('Group burst');
    await expect(readoutValues.nth(1)).toHaveText('20');
    await expect(readoutValues.nth(2)).toHaveText('1');
    await expect(readoutValues.nth(3)).toHaveText('1');
    await expect(surfaces).toHaveCount(1);
    await expect(preview).toContainText('×20');

    await simulator.getByRole('button', { name: 'Dedupe burst' }).click();
    await expect(readoutValues.nth(0)).toHaveText('Dedupe burst');
    await expect(readoutValues.nth(1)).toHaveText('10');
    await expect(readoutValues.nth(2)).toHaveText('1');
    await expect(surfaces).toHaveCount(1);
    await expect(preview).toContainText('Latest duplicate revision 10');
    await expect(preview).toContainText('×10');

    await simulator.getByRole('button', { name: 'Critical' }).click();
    await expect(readout).toContainText('Critical');
    await expect(preview.locator('[role="alert"]')).toHaveCount(1);

    await simulator.getByRole('button', { name: 'Spam test' }).click();
    await expect(readoutValues.nth(0)).toHaveText('Spam test');
    await expect(readoutValues.nth(1)).toHaveText('1,000');
    await expect(readoutValues.nth(2)).toHaveText('8');
    await expect(readoutValues.nth(3)).toHaveText('4');
    await expect(surfaces).toHaveCount(4);

    await simulator.getByRole('button', { name: 'Action test' }).click();
    await expect(readout).toContainText('Action test');
    await expect(preview.locator('.sx-signal-action')).toHaveCount(2);
    await expect(preview.locator('button')).toHaveCount(0);

    await simulator.getByRole('button', { name: 'Clear' }).click();
    await expect(readoutValues.nth(0)).toHaveText('Clear');
    await expect(readoutValues.nth(1)).toHaveText('0');
    await expect(readoutValues.nth(2)).toHaveText('0');
    await expect(readoutValues.nth(3)).toHaveText('0');
    await expect(surfaces).toHaveCount(0);
  });

  test('interaction surfaces stay contained and visually stable', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== '1080p', 'Interaction geometry and baseline are captured at 1080p.');

    await openDesignLab(page, 'section=runtime&reducedMotion=true');
    const preview = page.getByTestId('interaction-surface-preview').locator('.lab-interaction-preview');
    await expect(preview).toBeVisible();
    await expect(preview.locator('.sx-interaction[data-sx-mode="cue"]')).toHaveCount(1);
    await expect(preview.locator('.sx-interaction[data-sx-mode="bloom"]')).toHaveCount(1);
    await expect(preview.locator('.sx-interaction[data-sx-mode="progress"]')).toHaveCount(1);

    const geometry = await page.evaluate(() => {
      const bounds = document.documentElement.getBoundingClientRect();
      return Array.from(document.querySelectorAll<HTMLElement>('.lab-interaction-preview .sx-interaction')).map((surface) => {
        const rect = surface.getBoundingClientRect();
        return {
          left: rect.left,
          right: rect.right - bounds.width,
          top: rect.top,
          bottom: rect.bottom - bounds.height,
          pointerEvents: getComputedStyle(surface).pointerEvents,
        };
      });
    });
    for (const surface of geometry) {
      expect(surface.left).toBeGreaterThanOrEqual(-1);
      expect(surface.right).toBeLessThanOrEqual(1);
      expect(surface.top).toBeGreaterThanOrEqual(-1);
      expect(surface.bottom).toBeLessThanOrEqual(1);
      expect(surface.pointerEvents).toBe('none');
    }

    await expect(page).toHaveScreenshot('interaction-surface-contracts.png', { fullPage: false });
  });

  test('maximum notification copy remains bounded and visually stable', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== '1080p', 'Boundary geometry and baseline are captured at 1080p.');

    await openDesignLab(page, 'section=feedback&reducedMotion=true');
    const boundary = page.getByTestId('signal-copy-boundary');
    const title = boundary.locator('.sx-signal-surface__heading strong');
    const message = boundary.locator('.sx-signal-surface__message');
    await expect(boundary).toBeVisible();
    expect(await title.textContent()).toHaveLength(120);
    expect(await message.textContent()).toHaveLength(512);

    const geometry = await boundary.evaluate((element) => {
      const surface = element.querySelector<HTMLElement>('.sx-signal-surface')!;
      const heading = element.querySelector<HTMLElement>('.sx-signal-surface__heading strong')!;
      const body = element.querySelector<HTMLElement>('.sx-signal-surface__message')!;
      const headingStyle = getComputedStyle(heading);
      const bodyStyle = getComputedStyle(body);
      return {
        surfaceClientWidth: surface.clientWidth,
        surfaceScrollWidth: surface.scrollWidth,
        headingClientWidth: heading.clientWidth,
        headingScrollWidth: heading.scrollWidth,
        headingOverflow: headingStyle.overflow,
        headingTextOverflow: headingStyle.textOverflow,
        headingWhiteSpace: headingStyle.whiteSpace,
        bodyClientHeight: body.clientHeight,
        bodyScrollHeight: body.scrollHeight,
        bodyOverflow: bodyStyle.overflow,
        bodyOverflowWrap: bodyStyle.overflowWrap,
        bodyLineClamp: bodyStyle.getPropertyValue('-webkit-line-clamp'),
      };
    });
    expect(geometry.surfaceScrollWidth).toBeLessThanOrEqual(geometry.surfaceClientWidth + 1);
    expect(geometry.headingScrollWidth).toBeGreaterThan(geometry.headingClientWidth);
    expect(geometry.headingOverflow).toBe('hidden');
    expect(geometry.headingTextOverflow).toBe('ellipsis');
    expect(geometry.headingWhiteSpace).toBe('nowrap');
    expect(geometry.bodyScrollHeight).toBeGreaterThan(geometry.bodyClientHeight);
    expect(geometry.bodyOverflow).toBe('hidden');
    expect(geometry.bodyOverflowWrap).toBe('anywhere');
    expect(geometry.bodyLineClamp).toBe('2');
    await expect(boundary).toHaveScreenshot('signal-copy-boundary.png');
  });

  for (const section of sections) {
    test(`renders the complete ${section} section at 1080p`, async ({ page }, testInfo) => {
      test.skip(testInfo.project.name !== '1080p', 'Detailed section baselines are captured at 1080p.');

      await openDesignLab(page, `section=${section}`);
      await expect(page.locator('.lab-family-header')).toBeVisible();
      await expect(page.locator('.lab-family-header h1')).toBeVisible();

      if (section === 'foundation') {
        for (const specimen of ['tokens', 'colors', 'materials', 'glass-intensity', 'screen-sizes']) {
          await expect(page.getByTestId(specimen)).toBeVisible();
        }
      }

      if (section === 'feedback') {
        const toneMatrix = page.getByTestId('signal-tone-matrix');
        for (const tone of ['neutral', 'info', 'success', 'warning', 'danger']) {
          await expect(toneMatrix.locator(`[data-sx-tone="${tone}"]`)).toHaveCount(1);
        }
        for (const state of ['RUNNING', 'SUCCESS', 'FAILED']) {
          await expect(toneMatrix.locator(`[data-sx-state="${state}"]`)).toHaveCount(1);
        }
        const profileMatrix = page.getByTestId('signal-profile-matrix');
        for (const quality of ['low', 'balanced', 'high', 'ultra']) {
          await expect(profileMatrix.locator(`[data-sx-quality="${quality}"]`)).toHaveCount(
            quality === 'balanced' ? 3 : 1,
          );
        }
        await expect(profileMatrix.locator('[data-sx-reduced-motion="true"]')).toHaveCount(1);
        await expect(profileMatrix.locator('[data-sx-reduced-transparency="true"]')).toHaveCount(1);
      }

      await expect(page.locator('.lab-stage')).toHaveScreenshot(`section-${section}.png`);
    });
  }

  test('keeps long direct data-grid text ellipsized inside the aligned cell', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== '1080p', 'Data-grid geometry is verified at 1080p.');

    await openDesignLab(page, 'section=data');
    const content = page.locator('.sx-data-grid__body .sx-data-grid__content').first();
    await expect(content).toBeVisible();
    const geometry = await content.evaluate((element) => {
      element.textContent = 'synex-data-grid-long-value-'.repeat(16);
      const style = getComputedStyle(element);
      return {
        clientWidth: element.clientWidth,
        scrollWidth: element.scrollWidth,
        overflow: style.overflow,
        textOverflow: style.textOverflow,
        whiteSpace: style.whiteSpace,
      };
    });
    expect(geometry.scrollWidth).toBeGreaterThan(geometry.clientWidth);
    expect(geometry.overflow).toBe('hidden');
    expect(geometry.textOverflow).toBe('ellipsis');
    expect(geometry.whiteSpace).toBe('nowrap');
  });

  for (const profile of profileVariants) {
    test(`renders the ${profile.name} profile at 1080p`, async ({ page }, testInfo) => {
      test.skip(testInfo.project.name !== '1080p', 'Profile baselines are captured at 1080p.');

      await openDesignLab(page, profile.query);
      if ('attribute' in profile) {
        await expect(page.locator('html')).toHaveAttribute(profile.attribute, profile.value);
      } else {
        await expect.poll(() => page.evaluate(
          (property) => document.documentElement.style.getPropertyValue(property),
          profile.property,
        )).toBe(profile.value);
      }

      await expect(page).toHaveScreenshot(`profile-${profile.name}.png`, {
        fullPage: false,
      });
    });
  }
});
